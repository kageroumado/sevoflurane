import Foundation
import os

/// The page↔client bridge: serves Steam's own UI bundle with the
/// `SteamClient` shim injected, replays shim calls into the real
/// `SharedJSContext` over CDP, relays the protobuf transport around CDP, and
/// answers `/__eval`. One instance, owned by the app, running for its
/// lifetime.
actor SteamBridge {
    nonisolated enum WSMessage: Sendable {
        case text(String)
        case data(Data)
        case closed
    }

    private final class PageSession {
        let ws: WSConnection
        let tunnel: AsyncStream<String>.Continuation
        /// Distinguishes this page's call ids from another page's: every
        /// shim counts from one.
        let serial: Int
        var tasks: [Task<Void, Never>] = []

        init(ws: WSConnection, tunnel: AsyncStream<String>.Continuation, serial: Int) {
            self.ws = ws
            self.tunnel = tunnel
            self.serial = serial
        }
    }

    private var uiServer: HTTPServer?
    private var artServer: HTTPServer?
    private var pageServer: WebSocketServer?
    private var relayServer: WebSocketServer?

    /// One `Register*` call's handle: the page that made it and the callback
    /// ids minted for it, so both are released when the handle is used or
    /// the page goes away. Pending from the moment the call is forwarded;
    /// active once the client's reply says the handle is retained in
    /// `__sevoRet`. Absent means unregistered.
    private struct Registration {
        enum State {
            case pending
            case active
        }

        let owner: ObjectIdentifier
        let callbacks: [String]
        var state: State
    }

    var cdp: CDPClient?
    /// The connection attempt in flight, owned here: every ``ensureCDP()``
    /// caller waits on the same one, and a waiter's cancellation ends only
    /// its own wait.
    private var cdpTask: Task<Void, Never>?
    private var connectWaiters: [Int: CheckedContinuation<CDPClient, any Error>] = [:]
    private var connectWaiterSeq = 0
    private var pages: [ObjectIdentifier: PageSession] = [:]
    /// The transport socket owned by SharedJSContext.
    private var relay: WSConnection?
    /// Tunnel commands that arrived before the relay opened; resumed by
    /// ``attachRelay(_:queue:)`` or expired by their own timeout task.
    private var relayWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var relayWaiterSeq = 0
    /// Tunnel id → the page that opened it.
    private var tunnelOwner: [String: ObjectIdentifier] = [:]
    /// Callback id → the page that registered it.
    private var callbackOwner: [String: ObjectIdentifier] = [:]
    /// Registration handle (page serial and call id, the key in the client's
    /// `__sevoRet`) → its ``Registration``.
    private var registrations: [String: Registration] = [:]
    private var pageSerial = 0
    private var evalPending: [String: CheckedContinuation<(ok: Bool, v: String), Never>] = [:]
    private var evalTimeouts: [String: Task<Void, Never>] = [:]
    /// The page each pending eval was sent to, so a page that goes away
    /// answers its evals at once.
    private var evalPage: [String: ObjectIdentifier] = [:]
    private var evalSeq = 0
    /// The most recently attached page. A reload leaves the old session
    /// registered until its socket closes, and dictionary order could hand
    /// `/__eval` — and with it the supervisor's health verdict — to the
    /// stale one.
    private var newestPage: ObjectIdentifier?
    /// Loopback paths already reported unanswered, so one broken image does
    /// not fill the log with the same line.
    var loopbackMisses: Set<String> = []
    /// Whether the log already says the client is refusing calls as it closes.
    private var saidClientIsClosing = false
    let shim: String

    /// Fired on `SteamClient.Apps.RunGame` — the one choke point every game
    /// launch passes through (menu bar, library Play, `steam://run`). The app
    /// uses it to arm ``GameLaunchWatch``.
    private var onGameLaunch: (@Sendable () -> Void)?

    func setGameLaunchHandler(_ handler: @escaping @Sendable () -> Void) {
        onGameLaunch = handler
    }

    /// Told when the client's transport goes away — the earliest sign of a
    /// dying client, seconds before the launcher exits.
    private var onClientConnectionLost: (@Sendable () -> Void)?

    func setClientConnectionLostHandler(_ handler: @escaping @Sendable () -> Void) {
        onClientConnectionLost = handler
    }

    init() {
        if let url = Bundle.main.url(forResource: "steamclient_shim", withExtension: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            // The page port and the proxy's allowlist are templated like the
            // relay port below, so the shim, BridgePorts, and
            // WebSessionCookies cannot drift apart.
            let hosts = Self.jsonText(WebSessionCookies.domains) ?? "[]"
            shim = text
                .replacingOccurrences(of: "%PAGE_PORT%", with: String(BridgePorts.pageWS))
                .replacingOccurrences(of: "%STEAM_HOSTS%", with: hosts)
        } else {
            shim = ""
        }
    }

    // MARK: - Lifecycle

    /// Answers whether the listeners came up — a bind failure almost
    /// always means another copy of the app owns the ports, and the caller
    /// must say so instead of running half-alive.
    @discardableResult
    func start() async -> Bool {
        if shim.isEmpty {
            log(.bridge, "steamclient_shim.js missing from the app bundle — UI cannot boot")
        }
        do {
            // Exclusive: this is the port that says whether another copy of
            // Sevoflurane owns the app. Two listeners on it means the kernel
            // decides which process serves Steam's bundle, request by request.
            let ui = try HTTPServer(
                port: BridgePorts.steamUI, gate: .steamUI, exclusive: true,
            ) { [weak self] request in
                // Static assets never enter the actor: reading Steam's bundle
                // here would serialize every asset load against CDP dispatch
                // and the health probe. `/__web`, `/__loopback/`, `/`,
                // `/index.html` and `/__eval` need actor state.
                if request.method == "GET", request.path.hasPrefix("/__compat/") {
                    return await Self.handleCompatRequest(request)
                }
                if request.path == "/__web" {
                    return await self?.handleWebRequest(request) ?? .error(500, "bridge gone")
                }
                if request.path.hasPrefix(LoopbackAssets.pathPrefix + "/") {
                    return await self?.handleLoopbackRequest(request) ?? .error(500, "bridge gone")
                }
                if request.method == "GET",
                   request.path != "/", request.path != "/index.html" {
                    return Self.serveFile(under: SteamBottle.steamui, path: request.path)
                }
                return await self?.handleUIRequest(request) ?? .error(500, "bridge gone")
            }
            try await ui.startWaitingForThePort()
            uiServer = ui
            let art = try HTTPServer(port: BridgePorts.art, gate: .art) { request in
                Self.handleArtRequest(request)
            }
            art.start()
            artServer = art
            let page = try WebSocketServer(port: BridgePorts.pageWS, label: "page", gate: .pageWS)
            page.start { [weak self] connection in
                Task { await self?.attachPage(connection, queue: page.queue) }
            }
            pageServer = page
            let relaySocket = try WebSocketServer(
                port: BridgePorts.relayWS,
                label: "relay",
                gate: .relayWS,
                maxMessageSize: 64 * 1024 * 1024,
            )
            relaySocket.start { [weak self] connection in
                Task { await self?.attachRelay(connection, queue: relaySocket.queue) }
            }
            relayServer = relaySocket
            log(
                .bridge,
                "bridge up — ui :\(BridgePorts.steamUI), art :\(BridgePorts.art), "
                    + "page ws :\(BridgePorts.pageWS), relay ws :\(BridgePorts.relayWS)",
            )
        } catch {
            log(.bridge, "bridge failed to start: \(error.localizedDescription)")
            return false
        }
        return true
    }

    nonisolated func log(_ category: EventLog.Category, _ message: String) {
        EventLog.enqueue(category, message)
    }

    /// Wraps a connection's receive callbacks into one ordered stream.
    private nonisolated static func messages(
        of connection: WSConnection, on queue: DispatchQueue,
    ) -> AsyncStream<WSMessage> {
        AsyncStream { continuation in
            connection.start(
                queue: queue,
                onText: { continuation.yield(.text($0)) },
                onData: { continuation.yield(.data($0)) },
                onClose: {
                    continuation.yield(.closed)
                    continuation.finish()
                },
            )
        }
    }

    // MARK: - CDP

    /// The bottled client's cookie jar, for mirroring its authenticated web
    /// session into the app's web views (``WebSessionCookies``). Nil when the
    /// client isn't reachable — the caller renders signed out.
    func clientCookies() async -> [SteamWebCookie]? {
        guard let cdp = try? await ensureCDP() else { return nil }
        do {
            return try await cdp.cookies()
        } catch {
            log(.bridge, "cookie read failed: \(error)")
            return nil
        }
    }

    /// Brings the connection to the client up, and answers once it is — so a
    /// page is never booted into a bridge that cannot yet reach the client.
    @discardableResult
    func waitForClientConnection() async -> Bool {
        await (try? ensureCDP()) != nil
    }

    /// Whether the connection to the client's `SharedJSContext` is open. A
    /// DevTools server too busy to answer `/json` on a client whose socket is
    /// still live is slow, not gone, and must not be restarted for it.
    func isClientConnected() async -> Bool {
        guard let cdp else { return false }
        return await !cdp.isClosed
    }

    /// Hides the visible popups the bottled client has put on screen, in one
    /// evaluate on the connection the bridge already holds.
    ///
    /// `scope` decides which: `.everything` for the stop path and the
    /// supervisor's cycle, `.twins` for a sweep that came for one window and
    /// must leave the client's install dialogs, sign-in window and
    /// game-named popups where they are (``SteamWindowRole/twinRoles``). The
    /// names are matched in the page, so a narrowed sweep is still one round
    /// trip.
    ///
    /// The client's CEF windows exist to keep Steam's JS running — rendering
    /// is this app's job, and the page mirrors every popup natively
    /// (``SteamWebHost/adoptPopup(configuration:features:)``). The client
    /// still shows its own window when it decides UI is needed — the
    /// first-run login window above all, which OSS Wine paints as a black
    /// rectangle. Each visible popup is put away through its own
    /// `SteamClient.Window` binding, the same call the client uses to keep
    /// that window parked when signed in, so the popup's JS stays alive and
    /// only the pixels go.
    ///
    /// The popups are reached the way the page reaches its own: through
    /// `g_PopupManager.m_mapPopups`, a name → record map whose `m_popup` is
    /// the window. Membership in that map is what makes a window a client
    /// popup, and `SharedJSContext` is the page doing the walking, so it is
    /// excluded by identity.
    ///
    /// The window's own URL is not the discriminator it looks like: measured
    /// against the running client, every popup's `location.href` reads back
    /// as its opener's `https://steamloopback.host/index.html?…`, never the
    /// `about:blank` the DevTools target list shows.
    ///
    /// Answers the names it hid, or nil when the bridge holds no connection
    /// — the caller's cue that no sweep happened.
    ///
    /// `sparing` names the popups a launch in flight is waiting on, which
    /// stay where they are whatever the scope (``PopupSparing``).
    func hideVisibleClientPopups(
        _ scope: PopupSweepScope = .everything, sparing: PopupSparing = .none,
    ) async -> [String]? {
        guard let cdp, await !cdp.isClosed else { return nil }
        let hidden = try? await withDeadline(ClientLifecycle.cdpCallCap) {
            try await cdp.evaluate(Self.popupHideScript(scope, sparing: sparing))
        }
        guard let hidden else { return nil }
        return (hidden ?? "").split(separator: "\n").map(String.init)
    }

    /// Asks the client to end `appID` the way its own Stop button does, on the
    /// connection the bridge already holds. Sent for a run whose process is gone
    /// while Steam still lists it: the call clears the entry, and a later launch
    /// is answered again rather than dropped.
    ///
    /// Straight over CDP rather than through the page's forward path, which
    /// records a stop request and would turn the run's record into a stop the
    /// user never asked for.
    ///
    /// Answers whether the client took the call. False when the bridge holds no
    /// connection or the call did not return in time.
    func terminateApp(_ appID: Int) async -> Bool {
        guard let cdp, await !cdp.isClosed else { return false }
        let answer = try? await withDeadline(ClientLifecycle.cdpCallCap) {
            try await cdp.evaluate(
                "SteamClient.Apps.TerminateApp(\(JSLiteral.string(String(appID))), false), \"sent\"",
            )
        }
        return answer != nil
    }

    /// The sweep, with the names it may hide compiled in.
    ///
    /// A twin sweep carries ``SteamWindowRole``'s own table rather than a
    /// second copy of it in JavaScript: `exact` names are whole bases and
    /// `starts` are the families Steam numbers per instance, both matched
    /// against the part of the name before its `_uid<pid>` suffix. The whole
    /// table travels as `knownExact` and `knownStarts` for the sparing, which
    /// keeps a desktop-UI popup the table cannot name.
    nonisolated static func popupHideScript(_ scope: PopupSweepScope, sparing: PopupSparing = .none) -> String {
        let names = scope == .twins ? SteamWindowRole.twinNames : nil
        func list(_ names: [SteamWindowRole.NameMatch]?, _ keep: (SteamWindowRole.NameMatch) -> String?) -> String {
            guard let names else { return "null" }
            return "[\(names.compactMap(keep).map(JSLiteral.string).joined(separator: ","))]"
        }
        func exact(_ match: SteamWindowRole.NameMatch) -> String? {
            if case let .exact(name) = match { name } else { nil }
        }
        func prefix(_ match: SteamWindowRole.NameMatch) -> String? {
            if case let .prefix(start) = match { start } else { nil }
        }
        let known = SteamWindowRole.names.map(\.match)
        let spared = "[\(sparing.exactBases.map(JSLiteral.string).joined(separator: ","))]"
        return """
        (function (exact, starts, spareExact, spareUnclassified, knownExact, knownStarts) {
          var popups = window.g_PopupManager && g_PopupManager.m_mapPopups;
          if (!popups) return "";
          var baseOf = function (name) {
            var uid = name.indexOf("_uid");
            return uid < 0 ? name : name.slice(0, uid);
          };
          var instanceOf = function (name) {
            var uid = name.lastIndexOf("_uid");
            return uid < 0 ? 0 : (parseInt(name.slice(uid + 4), 10) || 0);
          };
          var known = function (base) {
            if (knownExact.indexOf(base) >= 0) return true;
            return knownStarts.some(function (start) { return base.indexOf(start) === 0; });
          };
          var spared = function (name) {
            var base = baseOf(name);
            if (spareExact.indexOf(base) >= 0 || spareExact.indexOf(name) >= 0) return true;
            return spareUnclassified && instanceOf(name) === 0 && !known(base);
          };
          var allowed = function (name) {
            if (spared(name)) return false;
            if (!exact) return true;
            var base = baseOf(name);
            if (exact.indexOf(base) >= 0) return true;
            return starts.some(function (start) { return base.indexOf(start) === 0; });
          };
          var hidden = [];
          popups.forEach(function (record) {
            try {
              var win = record && record.m_popup;
              if (!win || win === window || win.closed) return;
              if (win.document.visibilityState !== "visible") return;
              var name = String(win.name || record.m_strName || "unnamed popup");
              if (!allowed(name)) return;
              var client = win.SteamClient;
              if (!client || !client.Window || !client.Window.HideWindow) return;
              client.Window.HideWindow();
              hidden.push(name);
            } catch (e) {}
          });
          return hidden.join("\\n");
        })(\(list(names, exact)), \(list(names, prefix)), \(spared), \(sparing.unclassifiedDesktopPopups),
           \(list(known, exact)), \(list(known, prefix)))
        """
    }

    /// Asks the client's own SharedJSContext once whether
    /// `GetServicesInitialized()` is true. Steam's UI checks services once at
    /// boot, so a page booted before they are ready never picks them up and
    /// the supervisor holds the page back until this answers true.
    ///
    /// Nil when the client cannot be reached at all — a closed socket answers
    /// immediately rather than burning a timeout, so the caller's own cycle
    /// decides what a client that stopped answering means.
    func clientServicesReady() async -> Bool? {
        guard let cdp = try? await ensureCDP(), await !cdp.isClosed else { return nil }
        let answer = try? await withDeadline(.seconds(10)) {
            try await cdp.evaluate(
                "String(!!(window.App&&App.GetServicesInitialized&&App.GetServicesInitialized()))",
            )
        }
        guard let answer else { return nil }
        return answer.contains("true")
    }

    /// Discovery, the handshake, and the codec and tunnel installs together.
    static let connectBudget: Duration = .seconds(30)

    func ensureCDP() async throws -> CDPClient {
        if let cdp, await !cdp.isClosed { return cdp }
        if cdpTask == nil { startConnection() }
        return try await awaitConnection()
    }

    private func startConnection() {
        cdpTask = Task { [weak self] in
            let connect = PerfProbe.bridge.beginInterval("CDPConnect")
            defer { PerfProbe.bridge.endInterval("CDPConnect", connect) }
            // Re-captured: the outer `weak self` is a mutable box, which a
            // @Sendable closure may not reference; its own capture is a copy.
            let client = CDPClient(onPush: { [weak self] payload in
                await self?.deliverCallback(payload)
            })
            do {
                let tunnel = try await withDeadline(Self.connectBudget) {
                    try await client.connect(port: BridgePorts.cdp)
                    _ = try await client.evaluate(BridgeJS.binaryCodec)
                    return try await client.evaluate(
                        BridgeJS.tunnel.replacingOccurrences(
                            of: "%RELAY_PORT%", with: String(BridgePorts.relayWS),
                        ),
                    )
                }
                self?.log(.bridge, "cdp connected — \(tunnel ?? "?")")
                await self?.settleConnection(.success(client))
            } catch {
                await client.disconnect()
                self?.log(.bridge, "cdp connect failed: \(error)")
                await self?.settleConnection(.failure(error))
            }
        }
    }

    private func settleConnection(_ outcome: Result<CDPClient, any Error>) {
        cdpTask = nil
        if case let .success(client) = outcome { cdp = client }
        let waiters = connectWaiters.values
        connectWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: outcome)
        }
    }

    /// Waits for the attempt in flight. Cancelling the caller resumes only
    /// its own continuation; the attempt runs on for the other waiters. Same
    /// shape as `CDPClient.send`: the insertion runs synchronously on this
    /// actor, so the cancellation task cannot find the key before it exists.
    private func awaitConnection() async throws -> CDPClient {
        connectWaiterSeq += 1
        let key = connectWaiterSeq
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectWaiters[key] = continuation
            }
        } onCancel: {
            Task { await self.abandonConnectionWait(key) }
        }
    }

    private func abandonConnectionWait(_ key: Int) {
        connectWaiters.removeValue(forKey: key)?.resume(throwing: CancellationError())
    }

    /// Routes one `__sevo` binding push: a callback names a function inside
    /// one page, and delivering it anywhere else would run the wrong page's
    /// handler on this page's data. A callback whose page is gone is dropped.
    private func deliverCallback(_ payload: String) {
        guard let message = Self.jsonObject(payload),
              message["type"] as? String == "sc_callback",
              let cb = message["cb"] as? String,
              let owner = callbackOwner[cb],
              let session = pages[owner] else { return }
        session.ws.send(text: payload)
    }

    // MARK: - Page sessions

    /// A connection becomes a page on its first message, the shim's hello.
    /// A handshake the gate refused sends nothing and closes, so it never
    /// takes ``newestPage`` from the live page.
    private func attachPage(_ ws: WSConnection, queue: DispatchQueue) {
        let id = ObjectIdentifier(ws)
        let stream = Self.messages(of: ws, on: queue)
        Task { [weak self] in
            var isRegistered = false
            for await message in stream {
                switch message {
                case let .text(raw) where isRegistered:
                    await self?.handlePageMessage(raw, id: id)
                case let .text(raw):
                    guard Self.isHello(raw) else {
                        ws.close()
                        continue
                    }
                    isRegistered = true
                    await self?.registerPage(ws)
                    await self?.closeUnlessClientReachable(ws)
                case .data:
                    break
                case .closed:
                    if isRegistered { await self?.detachPage(id) }
                }
            }
        }
    }

    private func registerPage(_ ws: WSConnection) {
        let (tunnelStream, tunnelContinuation) = AsyncStream.makeStream(of: String.self)
        pageSerial += 1
        let session = PageSession(ws: ws, tunnel: tunnelContinuation, serial: pageSerial)
        let id = ObjectIdentifier(ws)
        pages[id] = session
        newestPage = id
        log(.bridge, "page connected (\(pages.count) total)")

        session.tasks.append(Task { [weak self] in
            // Tunnel commands carry a byte stream, so they leave in arrival
            // order on one worker rather than as free-floating tasks.
            for await raw in tunnelStream {
                await self?.relaySend(raw, from: id)
            }
        })
    }

    /// The first message a page or the relay sends once its socket opens.
    nonisolated static func isHello(_ raw: String) -> Bool {
        jsonObject(raw)?["type"] as? String == "hello"
    }

    /// A page whose calls have nowhere to go is closed at once: the shim
    /// reconnects a second after close, and by then the supervisor may have
    /// the client back.
    private func closeUnlessClientReachable(_ ws: WSConnection) async {
        guard await (try? ensureCDP()) == nil else { return }
        ws.close()
    }

    /// The session is looked up rather than captured: `PageSession` lives in
    /// the actor's region, and a consumer task may not carry a reference to
    /// it across the isolation boundary.
    private func handlePageMessage(_ raw: String, id: ObjectIdentifier) {
        guard let session = pages[id], let request = Self.jsonObject(raw) else { return }
        let cmd = request["cmd"] as? String ?? ""
        if cmd.hasPrefix("ws_") {
            session.tunnel.yield(raw)
            return
        }
        if cmd == "eval_result" {
            if let eid = request["id"] as? String,
               let continuation = evalPending.removeValue(forKey: eid) {
                evalTimeouts.removeValue(forKey: eid)?.cancel()
                evalPage.removeValue(forKey: eid)
                // The shim's `v` is already JSON text (it stringifies before
                // sending); re-encoding it here would double-escape.
                continuation.resume(returning: (
                    ok: request["ok"] as? Bool ?? false,
                    v: request["v"] as? String ?? "null",
                ))
            }
            return
        }
        // Every other command runs on its own task: a SteamClient call that
        // never settles must not stall the ones behind it.
        Task { await self.dispatch(request, ws: session.ws, id: id) }
    }

    private func dispatch(_ request: [String: Any], ws: WSConnection, id: ObjectIdentifier) async {
        guard let cdp = try? await ensureCDP() else { return }
        let cmd = request["cmd"] as? String ?? ""
        do {
            switch cmd {
            case "sc":
                try await forwardSteamClient(request, ws: ws, id: id, cdp: cdp)
            case "sc_unregister":
                if let rid = request["id"] as? Int, let session = pages[id] {
                    try await unregister([Self.handle(session.serial, rid)], cdp: cdp)
                }
            default:
                return
            }
        } catch {
            // A client on its way out refuses every call the page still
            // makes, a dozen in a second: said once per closing.
            let closing = "\(error)" == "closed"
            if !closing || !saidClientIsClosing {
                log(
                    .bridge,
                    closing
                        ? "the client is closing — the page's calls are refused until it is back"
                        : "dispatch \(cmd) failed: \(error)",
                )
            }
            saidClientIsClosing = closing
            if cmd == "sc", let rid = request["id"] as? Int {
                // The shim's promise must settle: a call that timed out or
                // lost its connection rejects there like a Steam error does.
                ws.send(text: Self.resultReply(rid: rid, outcome: [
                    "ok": false, "e": ["__sevoErr": "Error", "message": "\(error)"],
                ]))
            }
        }
    }

    /// The `sc_result` envelope for one forwarded call's outcome.
    private static func resultReply(rid: Int, outcome: [String: Any]) -> String {
        var reply = #"{"type":"sc_result","id":\#(rid)"#
        if outcome["ok"] as? Bool == true {
            reply += #","value":\#(jsonText(jsonText(outcome["v"]) ?? "null") ?? "\"null\"")}"#
        } else {
            reply += #","error":\#(jsonText(jsonText(outcome["e"]) ?? "null") ?? "\"null\"")}"#
        }
        return reply
    }

    /// How long a forwarded `SteamClient` call may wait for the client's
    /// reply. Generous, because some calls settle only when Steam has
    /// finished a job of its own; the page's promise rejects after this.
    static let forwardBudget: Duration = .seconds(120)

    /// Replays one shim call against the real SharedJSContext.
    ///
    /// Function arguments arrive as `{"__sevoCb": id}` markers; they are
    /// rebuilt on the far side as real functions that push through the
    /// `__sevo` binding, so Steam's own callbacks stream back to the page
    /// that registered them. A registration's handle is retained in
    /// `__sevoRet` so ``unregister(_:cdp:)`` can find it.
    private func forwardSteamClient(
        _ request: [String: Any],
        ws: WSConnection,
        id: ObjectIdentifier,
        cdp: CDPClient,
    ) async throws {
        guard let rid = request["id"] as? Int,
              let path = request["path"] as? String,
              let session = pages[id] else { return }
        guard Self.isSteamClientPath(path) else {
            log(.bridge, "refused a SteamClient call to a malformed path")
            ws.send(text: Self.resultReply(rid: rid, outcome: [
                "ok": false, "e": ["__sevoErr": "Error", "message": "not a SteamClient method path"],
            ]))
            return
        }
        let handle = Self.handle(session.serial, rid)
        let handleJS = Self.jsonText(handle) ?? "\"?\""
        if path == "SteamClient.Apps.RunGame" {
            // The one choke point every launch funnels through — menu bar,
            // the library's Play button, steam://run. Reconcile the renderer
            // tree here, before the call reaches Steam, so a version or
            // renderer change made in Settings takes effect on this launch
            // whatever started it, with no race against the game's DLL load.
            // A bounce (msync, engine) can't be applied inline and stays the
            // launch path's job; only a restage is owed here.
            if BottleGraphics.graphicsChangeSinceBoot().restage {
                if let note = BottleGraphics.stagingNote(BottleGraphics.reconcileManagedTree()) {
                    log(.client, note)
                }
                BottleGraphics.recordBootedSelection()
            }
            onGameLaunch?()
        }
        if path == "SteamClient.Apps.TerminateApp",
           let appID = (request["args"] as? [Any])?.first.flatMap({ ($0 as? NSNumber)?.intValue ?? Int("\($0)") }) {
            // Every stop asked for in the page — the library's Stop button, the
            // menu bar — passes here. The run that ends next a person ended.
            RunLog.noteStopRequest(forApp: appID, by: .player)
        }
        let call = PerfProbe.bridge.beginInterval(
            "SteamClientCall",
            id: PerfProbe.bridge.makeSignpostID(),
            "\(path, privacy: .public)",
        )
        defer { PerfProbe.bridge.endInterval("SteamClientCall", call) }
        let (argsJS, callbacks) = mintArguments(of: request, owner: id)
        let expr = Self.forwardExpression(path: path, handleJS: handleJS, argsJS: argsJS)
        // The handle exists before the await: an unregister or a page close
        // that arrives while the reply is pending finds it, and the reply
        // then sees whether anyone still wants it.
        registrations[handle] = Registration(owner: id, callbacks: callbacks, state: .pending)
        let raw: String?
        do {
            raw = try await withDeadline(Self.forwardBudget) { try await cdp.evaluate(expr) }
        } catch {
            await abandonRegistration(handle, hadCallbacks: !callbacks.isEmpty, cdp: cdp)
            throw error
        }
        let outcome = raw.flatMap(Self.jsonObject) ?? ["ok": false, "e": "no result"]
        if outcome["reg"] as? Bool == true {
            if registrations[handle] != nil, pages[id] != nil {
                registrations[handle]?.state = .active
            } else {
                // Unregistered or orphaned while the reply was pending; the
                // client retained the handle a moment ago, so release it.
                registrations.removeValue(forKey: handle)
                _ = try? await cdp.evaluate(Self.remoteUnregister([handle]))
            }
        } else {
            registrations.removeValue(forKey: handle)
        }
        ws.send(text: Self.resultReply(rid: rid, outcome: outcome))
    }

    /// Whether `path` names a member of `SteamClient` by dotted identifiers
    /// alone. The path is spliced into the evaluated expression as source,
    /// so anything else would be code the page chose to run in the client.
    nonisolated static func isSteamClientPath(_ path: String) -> Bool {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "SteamClient" else { return false }
        return parts.dropFirst().allSatisfy(isIdentifier)
    }

    private nonisolated static func isIdentifier(_ part: Substring) -> Bool {
        guard let first = part.unicodeScalars.first else { return false }
        func isStart(_ scalar: Unicode.Scalar) -> Bool {
            ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || scalar == "_" || scalar == "$"
        }
        return isStart(first) && part.unicodeScalars.dropFirst().allSatisfy { isStart($0) || ("0" ... "9").contains($0) }
    }

    /// The call's arguments as JS source, and the callback ids among them,
    /// each now owned by `owner`.
    private func mintArguments(
        of request: [String: Any], owner: ObjectIdentifier,
    ) -> (argsJS: [String], callbacks: [String]) {
        var argsJS: [String] = []
        var callbacks: [String] = []
        for argument in request["args"] as? [Any] ?? [] {
            if let marker = argument as? [String: Any],
               let cb = marker["__sevoCb"] as? String {
                callbackOwner[cb] = owner
                callbacks.append(cb)
                let cbJSON = Self.jsonText(cb) ?? "\"?\""
                argsJS.append("function(){window.__sevo(JSON.stringify({type:'sc_callback',"
                    + "cb:\(cbJSON),args:window.__sevoEnc(Array.prototype.slice.call(arguments))}))}")
            } else {
                argsJS.append("window.__sevoDec(\(Self.jsonText(argument) ?? "null"))")
            }
        }
        return (argsJS, callbacks)
    }

    /// The expression that makes one call in SharedJSContext and reports
    /// its outcome as JSON text.
    private static func forwardExpression(path: String, handleJS: String, argsJS: [String]) -> String {
        """
        (async () => {
          window.__sevoRet = window.__sevoRet || {};
          try {
            const r = await \(path)(\(argsJS.joined(separator: ",")));
            if (r && r.unregister) {
              // A handle the bridge gave up on before this settled is
              // released here, where the object exists.
              if (window.__sevoDropped && window.__sevoDropped.delete(\(handleJS))) {
                r.unregister();
                return JSON.stringify({ok: true, v: null});
              }
              window.__sevoRet[\(handleJS)] = r;
              return JSON.stringify({ok: true, reg: true, v: null});
            }
            return JSON.stringify({ok: true, v: window.__sevoEnc(r)});
          } catch (e) {
            // Steam rejects with plain objects (e.g. {result: n}) that the UI
            // inspects; stringifying them to "[object Object]" destroys the
            // information the caller branches on.
            const payload = (e instanceof Error)
              ? {__sevoErr: 'Error', message: e.message}
              : window.__sevoEnc(e);
            return JSON.stringify({ok: false, e: payload});
          }
        })()
        """
    }

    /// Drops a forward that failed or timed out. The client's side of a
    /// registration may still settle later, so a call that could have
    /// produced one is marked dropped over there: the reply path releases
    /// the handle itself when it finds the mark.
    private func abandonRegistration(_ handle: String, hadCallbacks: Bool, cdp: CDPClient) async {
        if let registration = registrations.removeValue(forKey: handle) {
            for cb in registration.callbacks {
                callbackOwner.removeValue(forKey: cb)
            }
        }
        guard hadCallbacks, await !cdp.isClosed else { return }
        _ = try? await withDeadline(.seconds(5)) { try await cdp.evaluate(Self.remoteUnregister([handle])) }
    }

    /// Releases the client's side of each handle: the retained object is
    /// unregistered and dropped from `__sevoRet`. A handle the client has
    /// not retained yet is marked dropped, for the registration's own reply
    /// path to release.
    private static func remoteUnregister(_ handles: [String]) -> String {
        "\(jsonText(handles) ?? "[]").forEach(r => { const h = (window.__sevoRet||{})[r]; "
            + "delete window.__sevoRet[r]; if (h) h.unregister?.(); "
            + "else (window.__sevoDropped = window.__sevoDropped || new Set()).add(r); }); 'ok'"
    }

    /// Releases registrations on the far side and here: their handles are
    /// used and dropped from `__sevoRet`, and their callback ids forgotten.
    /// Without this a page that reloaded, or Steam's own popup that closed,
    /// would leave its handlers firing into the client for the rest of the
    /// session.
    private func unregister(_ handles: [String], cdp: CDPClient) async throws {
        var active: [String] = []
        for handle in handles {
            guard let registration = registrations.removeValue(forKey: handle) else { continue }
            for cb in registration.callbacks {
                callbackOwner.removeValue(forKey: cb)
            }
            // A pending handle has nothing on the far side yet; removing
            // the entry is what makes its reply release the handle.
            if registration.state == .active { active.append(handle) }
        }
        guard !active.isEmpty else { return }
        _ = try await cdp.evaluate(Self.remoteUnregister(active))
    }

    private static func handle(_ serial: Int, _ rid: Int) -> String {
        "\(serial)_\(rid)"
    }

    private func detachPage(_ id: ObjectIdentifier) async {
        guard let session = pages.removeValue(forKey: id) else { return }
        if newestPage == id { newestPage = pages.keys.first }
        for (eid, page) in evalPage where page == id {
            finishEval(eid, with: (false, "\"page disconnected\""))
        }
        session.tunnel.finish()
        for task in session.tasks {
            task.cancel()
        }
        let orphaned = registrations.filter { $0.value.owner == id }.map(\.key)
        if let cdp, await !cdp.isClosed {
            try? await unregister(orphaned, cdp: cdp)
        }
        for handle in orphaned {
            registrations.removeValue(forKey: handle)
        }
        for (cb, owner) in callbackOwner where owner == id {
            callbackOwner.removeValue(forKey: cb)
        }
        for (tid, owner) in tunnelOwner where owner == id {
            tunnelOwner.removeValue(forKey: tid)
            relay?.send(text: #"{"cmd":"ws_close","id":\#(Self.jsonText(tid) ?? "\"?\"")}"#)
        }
        log(.bridge, "page disconnected (\(pages.count) left)")
    }

    // MARK: - Transport relay

    /// A connection becomes the relay on its first message, the tunnel
    /// script's hello, the same way a page does (``attachPage(_:queue:)``).
    private func attachRelay(_ ws: WSConnection, queue: DispatchQueue) {
        let stream = Self.messages(of: ws, on: queue)
        Task { [weak self] in
            var isRelay = false
            for await message in stream {
                switch message {
                case let .text(raw) where isRelay:
                    await self?.relayControl(raw)
                case let .text(raw):
                    guard Self.isHello(raw) else {
                        ws.close()
                        continue
                    }
                    isRelay = true
                    await self?.promoteRelay(ws)
                case let .data(data):
                    if isRelay { await self?.relayFrame(data) }
                case .closed:
                    await self?.relayClosed(ws)
                }
            }
        }
    }

    /// Makes `ws` the relay. The one it replaces is closed: its tunnels are
    /// owned by a socket nothing routes to any more.
    private func promoteRelay(_ ws: WSConnection) {
        if let previous = relay, previous !== ws { previous.close() }
        relay = ws
        for waiter in relayWaiters.values {
            waiter.resume()
        }
        relayWaiters.removeAll()
        log(.bridge, "relay: SharedJSContext connected")
    }

    /// Control messages are JSON; the tunnel id names the owning page.
    private func relayControl(_ raw: String) {
        guard let message = Self.jsonObject(raw),
              let tid = message["id"] as? String else { return }
        let event = message["ev"] as? String
        if event != "message" {
            log(.bridge, "tunnel \(tid): \(event ?? "?") \(message["code"] as? Int ?? 0)")
        }
        if let owner = tunnelOwner[tid], let session = pages[owner] {
            session.ws.send(text: raw)
        }
        if event == "close" {
            tunnelOwner.removeValue(forKey: tid)
        }
    }

    /// Frames are the tunnel id length-prefixed onto the payload.
    private func relayFrame(_ data: Data) {
        guard let first = data.first else { return }
        let idLength = Int(first)
        guard data.count > idLength,
              let tid = String(data: data.subdata(in: 1 ..< 1 + idLength), encoding: .utf8),
              let owner = tunnelOwner[tid],
              let session = pages[owner] else { return }
        let payload = data.subdata(in: 1 + idLength ..< data.count)
        session.ws.send(text: #"{"type":"ws_event","id":\#(Self.jsonText(tid) ?? "\"?\""),"#
            + #""ev":"message","b64":"\#(payload.base64EncodedString())"}"#)
    }

    private func relayClosed(_ ws: WSConnection) {
        if relay === ws {
            relay = nil
            log(.bridge, "relay: disconnected")
            onClientConnectionLost?()
        }
    }

    /// Waits for the relay (it opens moments after CDP): resumed exactly when
    /// ``attachRelay(_:queue:)`` runs, or by the timeout for a client that
    /// never opens one.
    private func awaitRelay(timeout: Duration = .seconds(10)) async -> WSConnection? {
        if let relay { return relay }
        relayWaiterSeq += 1
        let id = relayWaiterSeq
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireRelayWaiter(id)
        }
        await withCheckedContinuation { relayWaiters[id] = $0 }
        expiry.cancel()
        return relay
    }

    private func expireRelayWaiter(_ id: Int) {
        relayWaiters.removeValue(forKey: id)?.resume()
    }

    /// Forwards one tunnel command from a page to the relay.
    private func relaySend(_ raw: String, from id: ObjectIdentifier) async {
        guard let relay = await awaitRelay(), let request = Self.jsonObject(raw) else {
            log(.bridge, "tunnel: no relay; dropping command")
            return
        }
        let cmd = request["cmd"] as? String ?? ""
        guard let tid = request["id"] as? String else { return }
        switch cmd {
        case "ws_open":
            // A binary frame carries the id behind a one-byte length.
            guard tid.utf8.count <= Int(UInt8.max) else {
                log(.bridge, "tunnel: refused an id longer than \(UInt8.max) bytes")
                pages[id]?.ws.send(text: #"{"type":"ws_event","id":\#(Self.jsonText(tid) ?? "\"?\""),"#
                    + #""ev":"close","code":1008}"#)
                return
            }
            tunnelOwner[tid] = id
            log(.bridge, "tunnel open \(tid) → \(request["url"] as? String ?? "?")")
            relay.send(text: raw)
        case "ws_close":
            relay.send(text: raw)
        case "ws_send":
            if let text = request["text"] as? String {
                let forwarded = ["cmd": "ws_send_text", "id": tid, "text": text]
                if let encoded = Self.jsonText(forwarded) {
                    relay.send(text: encoded)
                }
            } else if let b64 = request["b64"] as? String,
                      let payload = Data(base64Encoded: b64),
                      let frame = Self.frame(tid: tid, payload: payload) {
                relay.send(data: frame)
            }
        default:
            break
        }
    }

    /// One binary relay frame: the tunnel id behind its one-byte length, then
    /// the payload. Nil for an id too long to prefix.
    nonisolated static func frame(tid: String, payload: Data) -> Data? {
        guard let length = UInt8(exactly: tid.utf8.count) else { return nil }
        var frame = Data([length])
        frame.append(Data(tid.utf8))
        frame.append(payload)
        return frame
    }

    // MARK: - /__eval

    /// Evaluates an expression in the (one) connected page — the app's
    /// context page. This is the programmatic Web Inspector: the only other
    /// channel into the app's DOM is Safari's, by hand.
    func evaluateInPage(_ expr: String) async -> (ok: Bool, v: String) {
        guard let pageID = newestPage.flatMap({ pages[$0] == nil ? nil : $0 }) ?? pages.keys.first,
              let session = pages[pageID] else {
            return (false, "\"no page connected\"")
        }
        evalSeq += 1
        let eid = "e\(evalSeq)"
        let message = ["type": "eval", "id": eid, "expr": expr]
        guard let encoded = Self.jsonText(message) else {
            return (false, "\"unencodable expression\"")
        }
        let eval = PerfProbe.bridge.beginInterval(
            "PageEval", id: PerfProbe.bridge.makeSignpostID(),
        )
        let result: (ok: Bool, v: String) = await withCheckedContinuation { continuation in
            evalPending[eid] = continuation
            evalPage[eid] = pageID
            session.ws.send(text: encoded)
            evalTimeouts[eid] = Task {
                try? await Task.sleep(for: .seconds(20))
                self.expireEval(eid)
            }
        }
        PerfProbe.bridge.endInterval("PageEval", eval, "eval=\(eid),ok=\(result.ok)")
        return result
    }

    private func expireEval(_ eid: String) {
        guard !Task.isCancelled else { return }
        finishEval(eid, with: (false, "\"eval timed out\""))
    }

    /// Answers a pending eval without its page, and forgets it.
    private func finishEval(_ eid: String, with outcome: (ok: Bool, v: String)) {
        evalTimeouts.removeValue(forKey: eid)?.cancel()
        evalPage.removeValue(forKey: eid)
        evalPending.removeValue(forKey: eid)?.resume(returning: outcome)
    }

    // MARK: - Helpers

    private nonisolated static func jsonObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    /// JSON-encodes any JSON-representable value (fragments included).
    nonisolated static func jsonText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return "null" }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed],
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
