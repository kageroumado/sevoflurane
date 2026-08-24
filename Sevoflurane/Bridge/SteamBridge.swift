import Foundation

/// Everything the bridge listens on, and the one port it dials out to. The
/// page cannot open the CDP WebSocket itself (Chromium rejects
/// browser-originated connections by Origin header), so this process is the
/// neutral middleman between the app's page and the bottled client.
nonisolated enum BridgePorts {
    /// The bottled client's `-devtools-port` (outbound).
    static let cdp = 8081
    /// Capsule art for the menu-bar extra.
    static let art: UInt16 = 8760
    /// The page's command socket (dialed by the shim).
    static let pageWS: UInt16 = 8761
    /// Steam's UI bundle with the shim injected, plus `POST /__eval`.
    static let steamUI: UInt16 = 8762
    /// The transport relay (dialed by SharedJSContext itself).
    static let relayWS: UInt16 = 8763
}

nonisolated enum BottleSteam {
    static let root = WinePath.bottle
        .appendingPathComponent("drive_c/Program Files (x86)/Steam")
    static let steamui = root.appendingPathComponent("steamui")
    static let libraryCache = root.appendingPathComponent("appcache/librarycache")
}

/// The Swift port of `Spike/bridge.py`: serves Steam's own UI bundle with the
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
        var tasks: [Task<Void, Never>] = []

        init(ws: WSConnection, tunnel: AsyncStream<String>.Continuation) {
            self.ws = ws
            self.tunnel = tunnel
        }
    }

    private var uiServer: HTTPServer?
    private var artServer: HTTPServer?
    private var pageServer: WebSocketServer?
    private var relayServer: WebSocketServer?

    private var cdp: CDPClient?
    private var cdpTask: Task<CDPClient, any Error>?
    private var pages: [ObjectIdentifier: PageSession] = [:]
    /// The transport socket owned by SharedJSContext.
    private var relay: WSConnection?
    /// Tunnel id → the page that opened it.
    private var tunnelOwner: [String: ObjectIdentifier] = [:]
    /// Callback id → the page that registered it.
    private var callbackOwner: [String: ObjectIdentifier] = [:]
    private var evalPending: [String: CheckedContinuation<(ok: Bool, v: String), Never>] = [:]
    private var evalSeq = 0
    private let shim: String

    init() {
        if let url = Bundle.main.url(forResource: "steamclient_shim", withExtension: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            shim = text
        } else {
            shim = ""
        }
    }

    // MARK: - Lifecycle

    func start() {
        if shim.isEmpty {
            log(.bridge, "steamclient_shim.js missing from the app bundle — UI cannot boot")
        }
        do {
            let ui = try HTTPServer(port: BridgePorts.steamUI) { [weak self] request in
                await self?.handleUIRequest(request) ?? .error(500, "bridge gone")
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
        }
    }

    private nonisolated func log(_ category: EventLog.Category, _ message: String) {
        Task { @MainActor in EventLog.shared.log(category, message) }
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

    private func ensureCDP() async throws -> CDPClient {
        if let cdp, await !cdp.isClosed { return cdp }
        if let cdpTask { return try await cdpTask.value }
        let task = Task { [weak self] () throws -> CDPClient in
            let client = CDPClient(onPush: { payload in
                await self?.broadcast(payload)
            })
            try await client.connect(port: BridgePorts.cdp)
            _ = try await client.evaluate(BridgeJS.binaryCodec)
            let tunnel = try await client.evaluate(
                BridgeJS.tunnel.replacingOccurrences(
                    of: "%RELAY_PORT%", with: String(BridgePorts.relayWS),
                ),
            )
            let registered = try await client.evaluate(BridgeJS.registerDownloads)
            self?.log(.bridge, "cdp connected — \(tunnel ?? "?"), \(registered ?? "?")")
            return client
        }
        cdpTask = task
        defer { cdpTask = nil }
        do {
            let client = try await task.value
            cdp = client
            return client
        } catch {
            log(.bridge, "cdp connect failed: \(error)")
            throw error
        }
    }

    /// Routes one `__sevo` binding push. Callbacks name a function inside one
    /// page; delivering them to every page runs the wrong page's handler on
    /// this page's data. Everything else fans out.
    private func broadcast(_ payload: String) {
        guard let message = Self.jsonObject(payload) else { return }
        if message["type"] as? String == "sc_callback" {
            guard let cb = message["cb"] as? String,
                  let owner = callbackOwner[cb],
                  let session = pages[owner] else { return }
            session.ws.send(text: payload)
            return
        }
        for session in pages.values {
            session.ws.send(text: payload)
        }
    }

    // MARK: - Page sessions

    private func attachPage(_ ws: WSConnection, queue: DispatchQueue) {
        let (tunnelStream, tunnelContinuation) = AsyncStream.makeStream(of: String.self)
        let session = PageSession(ws: ws, tunnel: tunnelContinuation)
        let id = ObjectIdentifier(ws)
        pages[id] = session
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
            await self?.pushInitialLibrary(to: ws)
            for await message in stream {
                switch message {
                case let .text(raw):
                    await self?.handlePageMessage(raw, session: session, id: id)
                case .data:
                    break
                case .closed:
                    await self?.detachPage(id)
                }
            }
        })
    }

    private func pushInitialLibrary(to ws: WSConnection) async {
        do {
            let cdp = try await ensureCDP()
            if let apps = try await cdp.evaluate(BridgeJS.library) {
                ws.send(text: #"{"type":"library","apps":\#(apps)}"#)
            }
        } catch {
            // The shim reconnects a second after close; by then the
            // supervisor may have the client back.
            ws.close()
        }
    }

    private func handlePageMessage(_ raw: String, session: PageSession, id: ObjectIdentifier) {
        guard let request = Self.jsonObject(raw) else { return }
        let cmd = request["cmd"] as? String ?? ""
        if cmd.hasPrefix("ws_") {
            session.tunnel.yield(raw)
            return
        }
        if cmd == "eval_result" {
            if let eid = request["id"] as? String,
               let continuation = evalPending.removeValue(forKey: eid) {
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
            case "library":
                if let apps = try await cdp.evaluate(BridgeJS.library) {
                    ws.send(text: #"{"type":"library","apps":\#(apps)}"#)
                }
            case "sc":
                try await forwardSteamClient(request, ws: ws, id: id, cdp: cdp)
            case "sc_unregister":
                if let rid = request["id"] as? Int {
                    _ = try await cdp.evaluate(
                        "(window.__sevoRet||{})[\(rid)]?.unregister?.(); 'ok'",
                    )
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
        }
    }

    /// Replays one shim call against the real SharedJSContext.
    ///
    /// Function arguments arrive as `{"__sevoCb": id}` markers; they are
    /// rebuilt on the far side as real functions that push through the
    /// `__sevo` binding, so Steam's own callbacks stream back to the page
    /// that registered them. The return value is retained in `__sevoRet` so
    /// `unregister()` can find it.
    private func forwardSteamClient(
        _ request: [String: Any],
        ws: WSConnection,
        id: ObjectIdentifier,
        cdp: CDPClient,
    ) async throws {
        guard let rid = request["id"] as? Int,
              let path = request["path"] as? String,
              path.hasPrefix("SteamClient.") else { return }
        var argsJS: [String] = []
        for argument in request["args"] as? [Any] ?? [] {
            if let marker = argument as? [String: Any],
               let cb = marker["__sevoCb"] as? String {
                callbackOwner[cb] = id
                let cbJSON = Self.jsonText(cb) ?? "\"?\""
                argsJS.append("function(){window.__sevo(JSON.stringify({type:'sc_callback',"
                    + "cb:\(cbJSON),args:window.__sevoEnc(Array.prototype.slice.call(arguments))}))}")
            } else {
                argsJS.append("window.__sevoDec(\(Self.jsonText(argument) ?? "null"))")
            }
        }
        let expr = """
        (async () => {
          window.__sevoRet = window.__sevoRet || {};
          try {
            const r = await \(path)(\(argsJS.joined(separator: ",")));
            window.__sevoRet[\(rid)] = r;
            return JSON.stringify({ok: true, v: (r && r.unregister) ? null : window.__sevoEnc(r)});
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
        let raw = try await cdp.evaluate(expr)
        let outcome = raw.flatMap(Self.jsonObject) ?? ["ok": false, "e": "no result"]
        var reply = #"{"type":"sc_result","id":\#(rid)"#
        if outcome["ok"] as? Bool == true {
            reply += #","value":\#(Self.jsonText(Self.jsonText(outcome["v"]) ?? "null") ?? "\"null\"")}"#
        } else {
            reply += #","error":\#(Self.jsonText(Self.jsonText(outcome["e"]) ?? "null") ?? "\"null\"")}"#
        }
        ws.send(text: reply)
    }

    private func detachPage(_ id: ObjectIdentifier) {
        guard let session = pages.removeValue(forKey: id) else { return }
        session.tunnel.finish()
        for task in session.tasks {
            task.cancel()
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

    /// Forwards one tunnel command from a page to the relay.
    private func relaySend(_ raw: String, from id: ObjectIdentifier) async {
        for _ in 0 ..< 100 { // the relay opens moments after CDP
            if relay != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let relay, let request = Self.jsonObject(raw) else {
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
    func pageEval(_ expr: String) async -> (ok: Bool, v: String) {
        guard let session = pages.values.first else {
            return (false, "\"no page connected\"")
        }
        evalSeq += 1
        let eid = "e\(evalSeq)"
        let message = ["type": "eval", "id": eid, "expr": expr]
        guard let encoded = Self.jsonText(message) else {
            return (false, "\"unencodable expression\"")
        }
        return await withCheckedContinuation { continuation in
            evalPending[eid] = continuation
            session.ws.send(text: encoded)
            Task {
                try? await Task.sleep(for: .seconds(20))
                self.expireEval(eid)
            }
        }
    }

    private func expireEval(_ eid: String) {
        evalPending.removeValue(forKey: eid)?
            .resume(returning: (false, "\"eval timed out\""))
    }

    // MARK: - HTTP: Steam UI + /__eval

    private func handleUIRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "POST" {
            guard request.path == "/__eval" else { return .error(404, "Not Found") }
            let expr = String(data: request.body, encoding: .utf8) ?? ""
            let result = await pageEval(expr)
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
        return Self.serveFile(under: BottleSteam.steamui, path: request.path)
    }

    /// The real SharedJSContext's query string (IN_CLIENT, USE_POPUPS,
    /// CLIENT_SESSION, …), fetched live because CLIENT_SESSION and the
    /// transport ports change on every client restart.
    ///
    /// SILENT_STARTUP is dropped: the bottle client is launched with -silent
    /// so it stays out of the way, and that flag creates the desktop window
    /// Hidden — the window this page exists to show.
    private func liveSearch() async throws -> String {
        let cdp = try await ensureCDP()
        let search = try await cdp.evaluate("location.search") ?? ""
        let kept = search.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
            .components(separatedBy: "&")
            .filter { !$0.isEmpty && !$0.hasPrefix("SILENT_STARTUP=") }
        return "?" + kept.joined(separator: "&")
    }

    private func injectedIndex() async -> HTTPResponse {
        let indexURL = BottleSteam.steamui.appendingPathComponent("index.html")
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
        let injected = "<head>\(BridgeJS.spy)"
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
        let file = BottleSteam.libraryCache
            .appendingPathComponent("\(appid)/library_600x900.jpg")
        if let data = try? Data(contentsOf: file) {
            return .ok(
                data,
                type: "image/jpeg",
                headers: [("Cache-Control", "max-age=86400")],
            )
        }
        // Newer clients cache under content-hash filenames with no local
        // name→asset index; the public CDN is the reliable fallback.
        return .redirect(to: "https://shared.steamstatic.com/store_item_assets/"
            + "steam/apps/\(appid)/library_600x900.jpg")
    }

    // MARK: - Helpers

    private nonisolated static func serveFile(under root: URL, path: String) -> HTTPResponse {
        guard let decoded = path.removingPercentEncoding else {
            return .error(400, "Bad Request")
        }
        let target = root.appendingPathComponent(decoded).standardizedFileURL
        guard target.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            return .error(403, "Forbidden")
        }
        guard let data = try? Data(contentsOf: target) else {
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
