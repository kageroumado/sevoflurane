import Foundation

/// Who may talk to one of the app's loopback ports.
///
/// Binding to 127.0.0.1 keeps other machines out, and every web page the
/// user opens is still a local client. A page can post a CORS-simple request
/// to any port without a preflight and open a WebSocket to any port with no
/// CORS at all; after a DNS rebind it can also read the replies. The gate
/// answers both from the request's own headers:
///
/// - `Host` names this port on `127.0.0.1` or `localhost`. A rebound name
///   arrives under the attacker's host name, so the rebind is refused here.
/// - `Origin`, which every browser sends on cross-origin requests and on
///   every WebSocket handshake, is one of the port's own callers. The CLI, the
///   daemon, `URLSession` and `curl` send none, and are admitted.
///
/// Headers are the sender's to choose, so they hold back a browser and
/// nothing else: any process of any account on this Mac can write the request
/// the CLI writes. The ports that act for the user — the daemon's control
/// endpoint, the app's link port and the page's `/__eval` — also require
/// ``ControlToken``, which only this account can read. A web page cannot send
/// it either: it is a custom header, and a cross-origin page can set one only
/// after a CORS preflight, which these servers never answer.
///
/// The page's and the client's sockets, the page's bundle and the art stay
/// behind `Host` and `Origin` alone. Their callers are WebKit and CEF, which
/// send no header of ours, and a secret handed to a page these ports serve
/// would be served to any local reader of the same ports.
nonisolated struct LoopbackGate: Sendable {
    let port: UInt16
    /// The origins this port's legitimate browser callers send.
    let origins: Set<String>
    /// Which of the port's requests must carry ``ControlToken``.
    let tokenScope: TokenScope

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
        /// Refused for a missing or wrong ``ControlToken``, with the reason
        /// for the log.
        case unauthorized(String)
    }

    init(port: UInt16, origins: Set<String>, tokenScope: TokenScope = .none) {
        self.port = port
        self.origins = origins
        self.tokenScope = tokenScope
    }

    /// The Steam UI page, as WebKit names its origin. Adopted `about:blank`
    /// popups inherit it from their opener.
    static let pageOrigin = "http://127.0.0.1:\(BridgePorts.steamUI)"

    /// Steam's UI bundle, the page's own requests and nothing else, and
    /// `/__eval` for a native caller holding the token.
    static let steamUI = LoopbackGate(
        port: BridgePorts.steamUI, origins: [pageOrigin], tokenScope: .path("/__eval"),
    )
    /// The page's command socket, dialed by the shim inside the page.
    static let pageWS = LoopbackGate(port: BridgePorts.pageWS, origins: [pageOrigin])
    /// The transport relay, dialed by the client's `SharedJSContext`, which
    /// CEF serves from the client's own origin.
    /// `LoopbackAssets.clientOrigin`, spelled out: the daemon compiles this
    /// file without the bridge.
    static let relayWS = LoopbackGate(port: BridgePorts.relayWS, origins: ["https://steamloopback.host"])
    /// Capsule art, read by the menu bar through `URLSession`.
    static let art = LoopbackGate(port: BridgePorts.art, origins: [])
    /// The daemon's control endpoint: `sevo`, the app, and the Tools scripts.
    static let control = LoopbackGate(port: BridgePorts.control, origins: [], tokenScope: .everyRequest)
    /// The app's half of the daemon link: the daemon and `sevo`.
    static let appLink = LoopbackGate(port: BridgePorts.appLink, origins: [], tokenScope: .everyRequest)

    /// Judges one request before any handler sees it. `headers` are keyed by
    /// lowercased name. `expectedToken` is read only for a request the port's
    /// ``tokenScope`` covers, and a token that cannot be read admits nobody.
    func verdict(
        method _: String,
        path: String,
        headers: [String: String],
        expectedToken: () throws -> String = ControlToken.current,
    ) -> Verdict {
        guard let host = headers["host"] else { return .refused("no Host") }
        guard admitsHost(host) else { return .refused("Host \(host)") }
        if let origin = headers["origin"], !origins.contains(origin) {
            return .refused("Origin \(origin)")
        }
        guard requiresToken(path) else { return .admitted }
        let expected: String
        do {
            expected = try expectedToken()
        } catch {
            return .unauthorized("no usable token: \(error)")
        }
        guard let presented = headers[ControlToken.header.lowercased()] else {
            return .unauthorized("no \(ControlToken.header)")
        }
        guard ControlToken.matches(presented, expected: expected) else {
            return .unauthorized("wrong \(ControlToken.header)")
        }
        return .admitted
    }

    func admits(
        method: String,
        path: String,
        headers: [String: String],
        expectedToken: () throws -> String = ControlToken.current,
    ) -> Bool {
        verdict(method: method, path: path, headers: headers, expectedToken: expectedToken) == .admitted
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
