import Foundation

/// The app half of the `sevo` contract (`Docs/cli-mcp-spec.md`): a loopback
/// HTTP endpoint the CLI — and through it, agents — uses to drive the running
/// app. Mutating verbs route through the supervisor so the restart ladder has
/// one owner; with the app not running, `sevo` drives ``ClientLifecycle``
/// directly instead. Same exposure class as the bridge's `/__eval`: loopback
/// only, and the machine's local processes are already trusted with more.
@MainActor
final class ControlServer {
    private let supervisor: ClientSupervisor
    private let host: SteamWebHost
    private var server: HTTPServer?

    init(supervisor: ClientSupervisor, host: SteamWebHost) {
        self.supervisor = supervisor
        self.host = host
    }

    func start() {
        do {
            let server = try HTTPServer(port: BridgePorts.control) { [weak self] request in
                await self?.handle(request) ?? .error(500, "control server gone")
            }
            server.start()
            self.server = server
            EventLog.shared.log(.supervisor, "control endpoint up on :\(BridgePorts.control)")
        } catch {
            EventLog.shared.log(
                .supervisor,
                "control endpoint failed to start: \(error.localizedDescription)",
            )
        }
    }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            return status()
        case ("GET", "/log/tail"):
            return Self.logTail(query: request.query)
        case ("GET", "/windows"):
            return windows()
        case ("POST", "/client/restart"):
            supervisor.restartNow()
            return Self.json(#"{"ok":true,"note":"restart begun; poll /status"}"#)
        case ("POST", "/client/start"):
            supervisor.startForControl()
            return Self.json(#"{"ok":true,"note":"start begun; poll /status"}"#)
        case ("POST", "/client/stop"):
            guard !supervisor.isBusyRestarting else {
                return .error(409, "restart in progress")
            }
            await supervisor.stopForControl()
            return Self.json(#"{"ok":true,"note":"client stopped; auto-restart paused"}"#)
        case ("POST", "/supervisor/pause"), ("POST", "/supervisor/resume"):
            let wantPaused = request.path.hasSuffix("pause")
            if (supervisor.health == .paused) != wantPaused {
                supervisor.togglePaused()
            }
            return Self.json(#"{"ok":true}"#)
        default:
            return .error(404, "Not Found")
        }
    }

    private func status() -> HTTPResponse {
        let state = switch supervisor.health {
        case .starting: "starting"
        case .healthy: "healthy"
        case .degraded: "degraded"
        case .restarting: "restarting"
        case .gaveUp: "gaveUp"
        case .paused: "paused"
        }
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let body = #"{"app":"running","version":\#(JSLiteral.string(version)),"#
            + #""health":\#(JSLiteral.string(state)),"#
            + #""detail":\#(JSLiteral.string(supervisor.statusText)),"#
            + #""needsAttention":\#(supervisor.needsAttention)}"#
        return Self.json(body)
    }

    /// Every window the app owns — the diagnostic for "what is this window
    /// Sevoflurane put on my screen".
    private func windows() -> HTTPResponse {
        guard let data = try? JSONSerialization.data(
            withJSONObject: host.windowInventory(), options: [.sortedKeys],
        ) else { return .error(500, "inventory failed") }
        return .ok(data, type: "application/json")
    }

    private nonisolated static func logTail(query: String) -> HTTPResponse {
        var count = 50
        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2, parts[0] == "n", let n = Int(parts[1]) {
                count = max(1, min(n, 5000))
            }
        }
        guard let text = try? String(contentsOf: EventLog.fileURL, encoding: .utf8) else {
            return .error(404, "no log file")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let tail = lines.suffix(count).joined(separator: "\n")
        return .ok(Data((tail + "\n").utf8), type: "text/plain; charset=utf-8")
    }

    private nonisolated static func json(_ body: String) -> HTTPResponse {
        .ok(Data(body.utf8), type: "application/json")
    }
}
