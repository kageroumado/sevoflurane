import Foundation

/// Who may talk to one of the app's loopback ports.
///
/// Every web page is a local client: it can post CORS-simple requests and open
/// WebSockets to any port, and read replies after a DNS rebind. So `Host` must
/// name this port on `127.0.0.1` or `localhost` (a rebind arrives under the
/// attacker's name), and an `Origin` must be one of the port's own callers;
/// the CLI, the daemon, `URLSession` and `curl` send none.
///
/// Headers stop only browsers, and a page that gets a document served from
/// the UI port has its origin. So each port also asks for a secret:
/// - the ports that act for the user (control, app link, `/__eval`) take a
///   ``ControlToken`` signature, which only this account can make;
/// - the bundle, the page socket and the art take ``LoopbackSession``'s
///   cookie, which only this app's own web views and `URLSession` hold;
/// - the relay socket takes ``LoopbackSession/relayKey`` in its hello, since
///   CEF sends no cookie of ours.
nonisolated struct LoopbackGate: Sendable {
    let port: UInt16
    /// The origins this port's legitimate browser callers send.
    let origins: Set<String>
    /// Which of the port's requests must carry ``ControlToken``.
    let tokenScope: TokenScope
    /// Whether every request outside ``tokenScope`` must carry
    /// ``LoopbackSession``'s cookie.
    let needsSession: Bool

    enum TokenScope: Equatable {
        case none
        case everyRequest
        /// Requests to this one path, whatever their method.
        case path(String)
    }

    enum Verdict: Equatable {
        case admitted
        /// Refused for its `Host` or `Origin`, with the reason for the log.
        case refused(String)
        /// Refused for a missing or wrong ``ControlToken`` or session
        /// cookie, with the reason for the log.
        case unauthorized(String)
    }

    init(port: UInt16, origins: Set<String>, tokenScope: TokenScope = .none, needsSession: Bool = false) {
        self.port = port
        self.origins = origins
        self.tokenScope = tokenScope
        self.needsSession = needsSession
    }

    /// The Steam UI page, as WebKit names its origin. Adopted `about:blank`
    /// popups inherit it from their opener.
    static let pageOrigin = "http://127.0.0.1:\(BridgePorts.steamUI)"

    /// Steam's UI bundle, the page's own requests and nothing else, and
    /// `/__eval` for a native caller holding the token.
    static let steamUI = LoopbackGate(
        port: BridgePorts.steamUI, origins: [pageOrigin], tokenScope: .path("/__eval"), needsSession: true,
    )
    /// The page's command socket, dialed by the shim inside the page.
    static let pageWS = LoopbackGate(port: BridgePorts.pageWS, origins: [pageOrigin], needsSession: true)
    /// The transport relay, dialed by the client's `SharedJSContext`, which
    /// CEF serves from the client's own origin.
    /// `LoopbackAssets.clientOrigin`, spelled out: the daemon compiles this
    /// file without the bridge.
    static let relayWS = LoopbackGate(port: BridgePorts.relayWS, origins: ["https://steamloopback.host"])
    /// Capsule art, read by the menu bar through `URLSession`.
    static let art = LoopbackGate(port: BridgePorts.art, origins: [], needsSession: true)
    /// The daemon's control endpoint: `sevo`, the app, and the Tools scripts.
    static let control = LoopbackGate(port: BridgePorts.control, origins: [], tokenScope: .everyRequest)
    /// The app's half of the daemon link: the daemon and `sevo`.
    static let appLink = LoopbackGate(port: BridgePorts.appLink, origins: [], tokenScope: .everyRequest)

    /// Judges one request before any handler sees it. `headers` are keyed by
    /// lowercased name; `target` and `body` are what a ``ControlToken``
    /// signature covers. The token is read only for a request the port's
    /// ``tokenScope`` covers, and a token that cannot be read admits nobody.
    func verdict(
        method: String,
        target: String,
        headers: [String: String],
        body: Data = Data(),
        expectedToken: () throws -> String = ControlToken.current,
        session: String = LoopbackSession.key,
    ) -> Verdict {
        guard let host = headers["host"] else { return .refused("no Host") }
        guard admitsHost(host) else { return .refused("Host \(host)") }
        if let origin = headers["origin"], !origins.contains(origin) {
            return .refused("Origin \(origin)")
        }
        let path = String(target.prefix(while: { $0 != "?" }))
        guard requiresToken(path) else {
            guard needsSession else { return .admitted }
            let presented = LoopbackSession.cookie(in: headers["cookie"])
            return ControlToken.matches(presented, expected: session)
                ? .admitted
                : .unauthorized(presented == nil ? "no session cookie" : "wrong session cookie")
        }
        let expected: String
        do {
            expected = try expectedToken()
        } catch {
            return .unauthorized("no usable token: \(error)")
        }
        guard let presented = headers[ControlToken.header.lowercased()] else {
            return .unauthorized("no \(ControlToken.header)")
        }
        guard ControlToken.verifies(presented, token: expected, method: method, target: target, body: body) else {
            return .unauthorized("wrong or stale \(ControlToken.header)")
        }
        return .admitted
    }

    func admits(
        method: String,
        target: String,
        headers: [String: String],
        body: Data = Data(),
        expectedToken: () throws -> String = ControlToken.current,
        session: String = LoopbackSession.key,
    ) -> Bool {
        verdict(
            method: method, target: target, headers: headers, body: body,
            expectedToken: expectedToken, session: session,
        ) == .admitted
    }

    private func requiresToken(_ path: String) -> Bool {
        switch tokenScope {
        case .none: false
        case .everyRequest: true
        case let .path(guarded): path == guarded
        }
    }

    private func admitsHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "127.0.0.1:\(port)" || lowered == "localhost:\(port)"
    }

    /// Logs a refusal once per reason, so a page that retries in a loop costs
    /// one line.
    func noteRefusal(_ reason: String) {
        guard Self.refusals.insert("\(port) \(reason)") else { return }
        EventLog.enqueue(.bridge, "refused a request on :\(port) — \(reason)")
    }

    private static let refusals = RefusalLog()

    private final class RefusalLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<String> = []
        /// A bound on the distinct reasons kept, so a caller that varies its
        /// Origin cannot grow the set without end.
        private let cap = 64

        func insert(_ key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard seen.count < cap else { return false }
            return seen.insert(key).inserted
        }
    }
}

/// The secrets one launch of the app shares with its own pages, kept in
/// memory only.
///
/// The UI port's origin is not a credential: any document served from it has
/// that origin. The cookie is one: the app writes it into its own web views'
/// store and `URLSession`'s, `HttpOnly` and `SameSite=Strict`, so a browser,
/// another account, and a page that navigates one of the app's web views
/// here from another site all arrive without it.
nonisolated enum LoopbackSession {
    static let cookieName = "sevo_session"

    /// The cookie's value.
    static let key = ControlToken.generate()

    /// What the relay script says in its hello. CEF sends no cookie of ours,
    /// so the script carries this from the DevTools injection that starts it.
    static let relayKey = ControlToken.generate()

    /// The session cookie's value in a `Cookie` header.
    static func cookie(in header: String?) -> String? {
        guard let header else { return nil }
        for pair in header.split(separator: ";") {
            let trimmed = pair.drop(while: { $0 == " " })
            guard trimmed.hasPrefix(cookieName + "=") else { continue }
            return String(trimmed.dropFirst(cookieName.count + 1))
        }
        return nil
    }
}
