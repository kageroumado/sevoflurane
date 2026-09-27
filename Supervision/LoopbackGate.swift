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
/// - `POST /__eval` carries ``BridgePorts/evalHeader``. A cross-origin page
///   can set a custom header only after a CORS preflight, which these servers
///   never answer.
nonisolated struct LoopbackGate: Sendable {
    let port: UInt16
    /// The origins this port's legitimate browser callers send.
    let origins: Set<String>

    enum Verdict: Equatable {
        case admitted
        /// Refused, with the reason for the log.
        case refused(String)
    }

    /// The Steam UI page, as WebKit names its origin. Adopted `about:blank`
    /// popups inherit it from their opener.
    static let pageOrigin = "http://127.0.0.1:\(BridgePorts.steamUI)"

    /// Steam's UI bundle, the page's own requests and nothing else.
    static let steamUI = LoopbackGate(port: BridgePorts.steamUI, origins: [pageOrigin])
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
    static let control = LoopbackGate(port: BridgePorts.control, origins: [])
    /// The app's half of the daemon link: the daemon and `sevo`.
    static let appLink = LoopbackGate(port: BridgePorts.appLink, origins: [])

    /// Judges one request. `headers` are keyed by lowercased name.
    func verdict(method: String, path: String, headers: [String: String]) -> Verdict {
        guard let host = headers["host"] else { return .refused("no Host") }
        guard admitsHost(host) else { return .refused("Host \(host)") }
        if let origin = headers["origin"], !origins.contains(origin) {
            return .refused("Origin \(origin)")
        }
        if method == "POST", path == "/__eval",
           headers[BridgePorts.evalHeader.lowercased()] == nil {
            return .refused("/__eval without \(BridgePorts.evalHeader)")
        }
        return .admitted
    }

    func admits(method: String, path: String, headers: [String: String]) -> Bool {
        verdict(method: method, path: path, headers: headers) == .admitted
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
