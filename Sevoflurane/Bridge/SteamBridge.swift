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

    private var cdp: CDPClient?
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
    private var evalSeq = 0
    /// The most recently attached page. A reload leaves the old session
    /// registered until its socket closes, and dictionary order could hand
    /// `/__eval` — and with it the supervisor's health verdict — to the
    /// stale one.
    private var newestPage: ObjectIdentifier?
    private let shim: String

    /// Fired on `SteamClient.Apps.RunGame` — the one choke point every game
    /// launch passes through (menu bar, library Play, `steam://run`). The app
    /// uses it to arm ``GameLaunchWatch``.
    private var onGameLaunch: (@Sendable () -> Void)?

    func setGameLaunchHandler(_ handler: @escaping @Sendable () -> Void) {
        onGameLaunch = handler
    }

    init() {
        if let url = Bundle.main.url(forResource: "steamclient_shim", withExtension: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            // The page port is templated like the relay port below, so the
            // shim and BridgePorts cannot drift apart.
            shim = text.replacingOccurrences(
                of: "%PAGE_PORT%", with: String(BridgePorts.pageWS),
            )
        } else {
            shim = ""
        }
    }

    // MARK: - Lifecycle

    /// Answers whether the listeners came up — a bind failure almost
    /// always means another copy of the app owns the ports, and the caller
    /// must say so instead of running half-alive.
    @discardableResult
    func start() -> Bool {
        if shim.isEmpty {
            log(.bridge, "steamclient_shim.js missing from the app bundle — UI cannot boot")
        }
        do {
            let ui = try HTTPServer(port: BridgePorts.steamUI) { [weak self] request in
                // Static assets never enter the actor: reading Steam's bundle
                // here would serialize every asset load against CDP dispatch
                // and the health probe. Only /, /index.html, and /__eval need
                // actor state.
                if request.method == "GET", request.path.hasPrefix("/__compat/") {
                    return await Self.handleCompatRequest(request)
                }
                if request.method == "GET",
                   request.path != "/", request.path != "/index.html" {
                    return Self.serveFile(under: SteamBottle.steamui, path: request.path)
                }
                return await self?.handleUIRequest(request) ?? .error(500, "bridge gone")
            }
            ui.start()
            uiServer = ui
            let art = try HTTPServer(port: BridgePorts.art) { request in
                Self.handleArtRequest(request)
            }
            art.start()
            artServer = art
            let page = try WebSocketServer(port: BridgePorts.pageWS, label: "page")
            page.start { [weak self] connection in
                Task { await self?.attachPage(connection, queue: page.queue) }
            }
            pageServer = page
            let relaySocket = try WebSocketServer(
                port: BridgePorts.relayWS,
                label: "relay",
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

    private nonisolated func log(_ category: EventLog.Category, _ message: String) {
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

    /// Polls the client's own SharedJSContext until `GetServicesInitialized()`
    /// returns true. Steam's UI checks services once at boot; a page booted
    /// before they are ready never picks them up, so the supervisor waits here
    /// instead of booting into a 90-second grace that always ends in a reload.
    func waitForClientServices(timeout: Duration = .seconds(120)) async -> Bool {
        guard let cdp = try? await ensureCDP() else { return false }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            // Each evaluate gets the smaller of its own cap and what is left
            // of the whole wait, so a client that stops answering cannot
            // hold this past `timeout`.
            let remaining = ContinuousClock.now.duration(to: deadline)
            let result = try? await withDeadline(min(.seconds(10), remaining)) {
                try await cdp.evaluate(
                    "String(!!(window.App&&App.GetServicesInitialized&&App.GetServicesInitialized()))",
                )
            }
            if result?.contains("true") == true { return true }
            try? await Task.sleep(for: .seconds(3))
        }
        return false
    }

    /// Discovery, the handshake, and the codec and tunnel installs together.
    static let connectBudget: Duration = .seconds(30)

    private func ensureCDP() async throws -> CDPClient {
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

    private func attachPage(_ ws: WSConnection, queue: DispatchQueue) {
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
        let stream = Self.messages(of: ws, on: queue)
        session.tasks.append(Task { [weak self] in
            await self?.closeUnlessClientReachable(ws)
            for await message in stream {
                switch message {
                case let .text(raw):
                    await self?.handlePageMessage(raw, id: id)
                case .data:
                    break
                case .closed:
                    await self?.detachPage(id)
                }
            }
        })
    }

    /// A page whose calls have nowhere to go is closed at once: the shim
    /// reconnects a second after close, and by then the supervisor may have
    /// the client back.
    private func closeUnlessClientReachable(_ ws: WSConnection) async {
        guard (try? await ensureCDP()) == nil else { return }
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
                guard let template = BridgeJS.commands[cmd],
                      let appid = request["appid"] as? Int else { return }
                _ = try await cdp.evaluate(
                    template.replacingOccurrences(of: "%ID%", with: String(appid)),
                )
                if cmd == "install" {
                    try await Task.sleep(for: .milliseconds(500))
                    _ = try await cdp.evaluate(BridgeJS.commands["continue_install"]!)
                }
            }
        } catch {
            log(.bridge, "dispatch \(cmd) failed: \(error)")
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
              path.hasPrefix("SteamClient."),
              let session = pages[id] else { return }
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
                BottleGraphics.reconcileManagedTree()
                BottleGraphics.recordBootedSelection()
            }
            onGameLaunch?()
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

    private func attachRelay(_ ws: WSConnection, queue: DispatchQueue) {
        relay = ws
        for waiter in relayWaiters.values {
            waiter.resume()
        }
        relayWaiters.removeAll()
        log(.bridge, "relay: SharedJSContext connected")
        let stream = Self.messages(of: ws, on: queue)
        Task { [weak self] in
            for await message in stream {
                switch message {
                case let .text(raw):
                    await self?.relayControl(raw)
                case let .data(data):
                    await self?.relayFrame(data)
                case .closed:
                    await self?.relayClosed(ws)
                }
            }
        }
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
                      let payload = Data(base64Encoded: b64) {
                var frame = Data([UInt8(tid.utf8.count)])
                frame.append(Data(tid.utf8))
                frame.append(payload)
                relay.send(data: frame)
            }
        default:
            break
        }
    }

    // MARK: - /__eval

    /// Evaluates an expression in the (one) connected page — the app's
    /// context page. This is the programmatic Web Inspector: the only other
    /// channel into the app's DOM is Safari's, by hand.
    func evaluateInPage(_ expr: String) async -> (ok: Bool, v: String) {
        guard let session = newestPage.flatMap({ pages[$0] }) ?? pages.values.first else {
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
        evalTimeouts.removeValue(forKey: eid)
        evalPending.removeValue(forKey: eid)?
            .resume(returning: (false, "\"eval timed out\""))
    }

    // MARK: - HTTP: Steam UI + /__eval

    private func handleUIRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "POST" {
            guard request.path == "/__eval" else { return .error(404, "Not Found") }
            let expr = String(data: request.body, encoding: .utf8) ?? ""
            let result = await evaluateInPage(expr)
            let body = #"{"ok":\#(result.ok),"v":\#(Self.jsonText(result.v) ?? "null")}"#
            return .ok(Data(body.utf8), type: "application/json")
        }
        guard request.method == "GET" else { return .error(405, "Method Not Allowed") }
        if request.path == "/" || request.path == "/index.html" {
            if !request.query.contains("IN_CLIENT") {
                // The bundle configures itself from location.search: without
                // IN_CLIENT=true its own WebSocket transport Init() bails
                // before SetDefaultTransport, every service call queues
                // forever, and without USE_POPUPS=true no window is ever
                // opened. Mirror the real SharedJSContext's params verbatim.
                do {
                    return try await .redirect(to: "/index.html" + liveSearch())
                } catch {
                    return .error(503, "Steam client unreachable")
                }
            }
            return await injectedIndex()
        }
        return Self.serveFile(under: SteamBottle.steamui, path: request.path)
    }

    /// The real SharedJSContext's query string (IN_CLIENT, USE_POPUPS,
    /// CLIENT_SESSION, …), fetched live because CLIENT_SESSION and the
    /// transport ports change on every client restart.
    ///
    /// SILENT_STARTUP is kept — the bottle client is launched with `-silent`
    /// and the page is told the same, so Steam's UI creates its desktop
    /// window Hidden and leaves it that way. This app is a menu-bar app: the
    /// window belongs on screen when someone asks for it, and `showSteam`
    /// routes and shows it then.
    private func liveSearch() async throws -> String {
        let cdp = try await ensureCDP()
        let search = try await cdp.evaluate("location.search") ?? ""
        let kept = search.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
            .components(separatedBy: "&")
            .filter { !$0.isEmpty }
        return "?" + kept.joined(separator: "&")
    }

    private func injectedIndex() async -> HTTPResponse {
        let indexURL = SteamBottle.steamui.appendingPathComponent("index.html")
        guard let html = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return .error(404, "steamui/index.html not found in the bottle")
        }
        // The shim must mirror the real client's shape: the desktop client
        // lacks whole namespaces the Deck has (System.Audio, …) and the UI
        // feature-detects them. A Proxy that answers every property makes the
        // UI call methods that do not exist.
        var shape = "{}"
        if let cdp = try? await ensureCDP(),
           let snapshot = try? await cdp.evaluate(BridgeJS.shape) {
            shape = snapshot
        }
        let injected = "<head>"
            + "<script>window.__sevoShape=\(shape);</script>"
            + "<script>\(shim)</script>"
        guard let range = html.range(of: "<head>") else {
            return .error(500, "index.html has no <head>")
        }
        let body = html.replacingCharacters(in: range, with: injected)
        // The shim is injected here and edited constantly; a cached copy of
        // this document silently pins an old one.
        return .ok(
            Data(body.utf8),
            type: "text/html; charset=utf-8",
            headers: [("Cache-Control", "no-store")],
        )
    }

    // MARK: - HTTP: Mac compatibility

    /// `GET /__compat/<appid>?name=<display name>&deck=<category>`: the
    /// community databases' verdicts for one game, as the page's strip reads
    /// them (``SteamCompatBadge``). Name and Deck category come from the
    /// page because the client already holds both; the sources are keyed on
    /// the app id and, for the wiki, on the title.
    private nonisolated static func handleCompatRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let id = String(request.path.dropFirst("/__compat/".count)).prefix(while: { $0 != "." })
        guard let appID = Int(id) else { return .error(404, "Not Found") }
        let items = URLComponents(string: "http://127.0.0.1" + request.target)?.queryItems ?? []
        let name = items.first { $0.name == "name" }?.value ?? ""
        let deck = items.first { $0.name == "deck" }?.value.flatMap(Int.init)
        let body = await GameCompatService.shared.recordJSON(appID: appID, name: name, deckCategory: deck)
        return .ok(body, type: "application/json", headers: [("Cache-Control", "no-store")])
    }

    // MARK: - HTTP: art

    private nonisolated static func handleArtRequest(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET", request.path.hasPrefix("/art/") else {
            return .error(404, "Not Found")
        }
        let appid = String(request.path.dropFirst("/art/".count))
            .prefix(while: { $0 != "." })
        guard !appid.isEmpty, appid.allSatisfy(\.isNumber) else {
            return .error(404, "Not Found")
        }
        if let data = cachedCapsule(appid: String(appid)) {
            return .ok(
                data,
                type: "image/jpeg",
                headers: [("Cache-Control", "max-age=86400")],
            )
        }
        return .redirect(to: "https://shared.steamstatic.com/store_item_assets/"
            + "steam/apps/\(appid)/library_600x900.jpg")
    }

    /// The names the vertical capsule is written under: clients write either
    /// `library_600x900.jpg` or `library_capsule.jpg`. Both hold the same 2:3
    /// art and one library mixes them freely.
    private nonisolated static let capsuleNames = [
        "library_600x900.jpg", "library_capsule.jpg",
    ]

    /// The vertical capsule from the client's own library cache.
    ///
    /// Two layouts coexist: the flat `<appid>/<name>` older clients wrote, and
    /// the content-addressed `<appid>/<sha1>/<name>` current ones write. The
    /// asset keeps its name inside the hash directory, so one level of
    /// enumeration finds it without a name→asset index. Both ``capsuleNames``
    /// are tried in each layout. Worth the lookup because the CDN serves no
    /// capsule at all for age-gated titles — an adult game shows a blank tile
    /// if this misses.
    private nonisolated static func cachedCapsule(appid: String) -> Data? {
        let appDirectory = SteamBottle.libraryCache.appendingPathComponent(appid)
        for name in capsuleNames {
            let flat = appDirectory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: flat, options: [.mappedIfSafe]) { return data }
        }
        let contents = try? FileManager.default.contentsOfDirectory(
            at: appDirectory, includingPropertiesForKeys: [.isDirectoryKey],
        )
        for directory in contents ?? [] {
            for name in capsuleNames {
                let nested = directory.appendingPathComponent(name)
                if let data = try? Data(contentsOf: nested, options: [.mappedIfSafe]) {
                    return data
                }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private nonisolated static func serveFile(under root: URL, path: String) -> HTTPResponse {
        let serve = PerfProbe.bridge.beginInterval(
            "ServeAsset",
            id: PerfProbe.bridge.makeSignpostID(),
            "\(path, privacy: .public)",
        )
        defer { PerfProbe.bridge.endInterval("ServeAsset", serve) }
        guard let decoded = path.removingPercentEncoding else {
            return .error(400, "Bad Request")
        }
        let target = root.appendingPathComponent(decoded).standardizedFileURL
        guard target.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            return .error(403, "Forbidden")
        }
        // Mapped, not copied: Steam's UI chunks run to megabytes and the boot
        // waterfall requests dozens of them; the bytes go straight from the
        // page cache to the socket.
        guard let data = try? Data(contentsOf: target, options: [.mappedIfSafe]) else {
            return .error(404, "Not Found")
        }
        return .ok(data, type: ContentType.forExtension(target.pathExtension))
    }

    private nonisolated static func jsonObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    /// JSON-encodes any JSON-representable value (fragments included).
    private nonisolated static func jsonText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return "null" }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed],
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
