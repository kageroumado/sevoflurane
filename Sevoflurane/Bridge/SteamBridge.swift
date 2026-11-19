import Foundation
import os

/// The page↔client bridge: serves Steam's UI bundle with the `SteamClient`
/// shim injected, replays shim calls into the real `SharedJSContext` over
/// CDP, relays the protobuf transport around CDP, and answers `/__eval`.
/// One instance for the app's lifetime.
actor SteamBridge {
    nonisolated enum WSMessage: Sendable {
        case text(String)
        case data(Data)
        case closed
    }

    final class PageSession {
        let ws: WSConnection
        let tunnel: AsyncStream<String>.Continuation
        /// Namespaces this page's call ids; every shim counts from one.
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

    /// One `Register*` call's owner and callback ids. Pending once forwarded,
    /// active once the client retains the handle in `__sevoRet`; absent means
    /// unregistered.
    struct Registration {
        enum State {
            case pending
            case active
        }

        let owner: ObjectIdentifier
        let callbacks: [String]
        var state: State
    }

    var cdp: CDPClient?
    /// The connection attempt every ``ensureCDP()`` caller waits on; a
    /// waiter's cancellation ends only its own wait.
    private var cdpTask: Task<Void, Never>?
    private var connectWaiters: [Int: CheckedContinuation<CDPClient, any Error>] = [:]
    private var connectWaiterSeq = 0
    var pages: [ObjectIdentifier: PageSession] = [:]
    var relay: WSConnection?
    /// Tunnel commands waiting for the relay, resumed when it opens or by
    /// their timeout.
    private var relayWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var relayWaiterSeq = 0
    var tunnelOwner: [String: ObjectIdentifier] = [:]
    var callbackOwner: [String: ObjectIdentifier] = [:]
    /// Keyed by `<page serial>_<call id>`, the key in the client's
    /// `__sevoRet`.
    var registrations: [String: Registration] = [:]
    var pageSerial = 0
    var evalPending: [String: CheckedContinuation<(ok: Bool, v: String), Never>] = [:]
    var evalTimeouts: [String: Task<Void, Never>] = [:]
    /// The page each pending eval went to, so its evals fail when it leaves.
    var evalPage: [String: ObjectIdentifier] = [:]
    private var evalSeq = 0
    /// The most recently attached page. A reload leaves the old session
    /// registered until its socket closes, so dictionary order could hand
    /// `/__eval` (and the supervisor's health verdict) to the stale one.
    var newestPage: ObjectIdentifier?
    var loopbackMisses: Set<String> = []
    var saidClientIsClosing = false
    /// The Steam UI bundle version last audited (``ChromiumSurface``).
    var auditedBundleVersion: String?
    let shim: String

    /// Fired on every `SteamClient.Apps.RunGame`, to arm ``GameLaunchWatch``.
    var onGameLaunch: (@Sendable () -> Void)?

    func setGameLaunchHandler(_ handler: @escaping @Sendable () -> Void) {
        onGameLaunch = handler
    }

    /// Awaited with the game id before a `RunGame` reaches the client
    /// (``LaunchPreparation``), so the game's first process reads its
    /// first-launch settings.
    var launchPreparation: (@Sendable (String) async -> Void)?

    func setLaunchPreparation(_ prepare: @escaping @Sendable (String) async -> Void) {
        launchPreparation = prepare
    }

    /// Asked before `SteamClient.Installs.OpenInstallWizard` for one game
    /// whether the install goes ahead (``InstallWarning``).
    var installGate: (@Sendable (Int) async -> Bool)?

    func setInstallGate(_ gate: @escaping @Sendable (Int) async -> Bool) {
        installGate = gate
    }

    /// Told when the relay drops: the earliest sign of a dying client,
    /// seconds before the launcher exits.
    private var onClientConnectionLost: (@Sendable () -> Void)?

    func setClientConnectionLostHandler(_ handler: @escaping @Sendable () -> Void) {
        onClientConnectionLost = handler
    }

    init() {
        if let url = Bundle.main.url(forResource: "steamclient_shim", withExtension: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            // Templated, so the shim cannot drift from BridgePorts and
            // WebSessionCookies.
            let hosts = Self.jsonText(WebSessionCookies.domains) ?? "[]"
            shim = text
                .replacingOccurrences(of: "%PAGE_PORT%", with: String(BridgePorts.pageWS))
                .replacingOccurrences(of: "%STEAM_HOSTS%", with: hosts)
        } else {
            shim = ""
        }
    }

    // MARK: - Lifecycle

    /// Answers whether the listeners came up; a bind failure almost always
    /// means another copy of the app owns the ports.
    @discardableResult
    func start() async -> Bool {
        if shim.isEmpty {
            log(.bridge, "steamclient_shim.js missing from the app bundle — UI cannot boot")
        }
        do {
            // Exclusive: this port decides whether another copy owns the app;
            // with two listeners the kernel would pick one per request.
            let ui = try HTTPServer(
                port: BridgePorts.steamUI, gate: .steamUI, exclusive: true,
            ) { [weak self] request in
                // Static assets stay off the actor, which would serialize them
                // against CDP dispatch and the health probe.
                if request.method == "POST", request.path == "/__compat/batch" {
                    return await Self.handleCompatBatchRequest(request)
                }
                if request.method == "GET", request.path.hasPrefix("/__compat/") {
                    return await Self.handleCompatRequest(request)
                }
                if request.method == "GET", request.path.hasPrefix("/__native/") {
                    return await Self.handleNativeBuildRequest(request)
                }
                if request.path == "/__web" {
                    return await self?.handleWebRequest(request) ?? .error(500, "bridge gone")
                }
                if request.method == "GET", request.path.hasPrefix(Self.customImagesPrefix) {
                    return Self.handleCustomImageRequest(request)
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
            // Sized for Set Custom Artwork's base64 image, several MB for a
            // hero.
            let page = try WebSocketServer(
                port: BridgePorts.pageWS,
                label: "page",
                gate: .pageWS,
                maxMessageSize: 64 * 1024 * 1024,
            )
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

    nonisolated static func messages(
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

    /// The bottled client's cookie jar (``WebSessionCookies``); nil when the
    /// client is unreachable.
    func clientCookies() async -> [SteamWebCookie]? {
        guard let cdp = try? await ensureCDP() else { return nil }
        do {
            return try await cdp.cookies()
        } catch {
            log(.bridge, "cookie read failed: \(error)")
            return nil
        }
    }

    /// Brings the connection to the client up and answers whether it is.
    @discardableResult
    func waitForClientConnection() async -> Bool {
        await (try? ensureCDP()) != nil
    }

    /// Whether the connection to `SharedJSContext` is open. A client too busy
    /// to answer `/json` with this socket live is slow, and must not be
    /// restarted for it.
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
    /// game-named popups where they are (``SteamWindowRole/twinRoles``).
    /// `sparing` names the popups a launch in flight is waiting on, which
    /// stay whatever the scope (``PopupSparing``).
    ///
    /// The client's CEF windows exist to keep Steam's JS running; the page
    /// mirrors every popup natively
    /// (``SteamWebHost/adoptPopup(configuration:features:)``). The client
    /// still shows its own window when it decides UI is needed, the first-run
    /// login window above all, which OSS Wine paints as a black rectangle.
    /// Each visible popup is put away through its own `SteamClient.Window`
    /// binding, the call the client uses to keep that window parked when
    /// signed in, so the popup's JS stays alive.
    ///
    /// Popups are found through `g_PopupManager.m_mapPopups`, a name → record
    /// map whose `m_popup` is the window; `SharedJSContext` itself is excluded
    /// by identity. A popup's URL cannot tell them apart: every popup's
    /// `location.href` reads back as its opener's
    /// `https://steamloopback.host/index.html?…`, never the `about:blank` the
    /// DevTools target list shows.
    ///
    /// Answers the names it hid, or nil when the bridge holds no connection.
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

    /// Asks the client to end a game the way its own Stop button does, for a
    /// run whose process is gone while Steam still lists it: the call clears
    /// the entry, so a later launch is answered instead of dropped.
    ///
    /// `gameID` is Steam's game id: the app id for a Steam game, the 64-bit id
    /// for a shortcut (``SteamShortcuts/gameID(shortcutID:)``).
    ///
    /// Sent straight over CDP: the page's forward path records a stop request,
    /// which would label the run as stopped by the user.
    ///
    /// Answers whether the client took the call within the CDP call cap.
    func terminateApp(gameID: String) async -> Bool {
        guard let cdp, await !cdp.isClosed else { return false }
        let answer = try? await withDeadline(ClientLifecycle.cdpCallCap) {
            try await cdp.evaluate(
                "SteamClient.Apps.TerminateApp(\(JSLiteral.string(gameID)), false), \"sent\"",
            )
        }
        return answer != nil
    }

    /// Runs a script in `SharedJSContext` and answers its settled value; nil
    /// without a connection, on a throw or null, or past `cap`.
    func evaluateInClient(_ script: String, cap: Duration = ClientLifecycle.cdpCallCap) async -> String? {
        guard let cdp, await !cdp.isClosed else { return nil }
        let answer = try? await withDeadline(cap) { try await cdp.evaluate(script) }
        return answer ?? nil
    }

    /// The sweep, with the names it may hide compiled in from
    /// ``SteamWindowRole``'s table: `exact` names are whole bases and `starts`
    /// are the families Steam numbers per instance, both matched against the
    /// part of the name before its `_uid<pid>` suffix. The whole table travels
    /// as `knownExact` and `knownStarts` for the sparing, which keeps a
    /// desktop-UI popup the table cannot name.
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

    /// Asks the client's SharedJSContext whether `GetServicesInitialized()` is
    /// true. Steam's UI checks services once at boot, so the supervisor holds
    /// the page back until this answers true.
    ///
    /// Nil when the client cannot be reached; a closed socket answers at once,
    /// so the caller's own cycle decides what a silent client means.
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

    /// For discovery, the handshake, and the codec and tunnel installs.
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
            // Re-captured: a @Sendable closure may not reference the outer
            // `weak self` box.
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

    /// Waits for the attempt in flight; cancelling resumes only this waiter.
    /// The insertion runs synchronously on this actor, so the cancellation
    /// task cannot look for the key before it exists.
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

    /// Routes one `__sevo` binding push to the page that owns its callback,
    /// dropping it when that page is gone.
    private func deliverCallback(_ payload: String) {
        guard let message = Self.jsonObject(payload),
              message["type"] as? String == "sc_callback",
              let cb = message["cb"] as? String,
              let owner = callbackOwner[cb],
              let session = pages[owner] else { return }
        session.ws.send(text: payload)
    }

    // MARK: - Transport relay

    /// A connection becomes the relay on its first message, the tunnel
    /// script's hello.
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

    /// Makes `ws` the relay and closes the one it replaces.
    private func promoteRelay(_ ws: WSConnection) {
        if let previous = relay, previous !== ws { previous.close() }
        relay = ws
        for waiter in relayWaiters.values {
            waiter.resume()
        }
        relayWaiters.removeAll()
        log(.bridge, "relay: SharedJSContext connected")
    }

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

    /// Waits for the relay, which opens moments after CDP, up to `timeout`.
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

    func relaySend(_ raw: String, from id: ObjectIdentifier) async {
        guard let relay = await awaitRelay(), let request = Self.jsonObject(raw) else {
            log(.bridge, "tunnel: no relay; dropping command")
            return
        }
        let cmd = request["cmd"] as? String ?? ""
        guard let tid = request["id"] as? String else { return }
        switch cmd {
        case "ws_open":
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

    /// One binary relay frame: a one-byte id length, the tunnel id, then the
    /// payload. Nil for an id over 255 bytes.
    nonisolated static func frame(tid: String, payload: Data) -> Data? {
        guard let length = UInt8(exactly: tid.utf8.count) else { return nil }
        var frame = Data([length])
        frame.append(Data(tid.utf8))
        frame.append(payload)
        return frame
    }

    // MARK: - /__eval

    /// Evaluates an expression in the app's context page: the programmatic
    /// Web Inspector.
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

    func finishEval(_ eid: String, with outcome: (ok: Bool, v: String)) {
        evalTimeouts.removeValue(forKey: eid)?.cancel()
        evalPage.removeValue(forKey: eid)
        evalPending.removeValue(forKey: eid)?.resume(returning: outcome)
    }

    // MARK: - Helpers

    nonisolated static func jsonObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    /// JSON text for any JSON-representable value, fragments included.
    nonisolated static func jsonText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return "null" }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed],
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
