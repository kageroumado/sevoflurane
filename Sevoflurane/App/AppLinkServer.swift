import Foundation

/// The app's half of the daemon link: the work only this process can do.
///
/// The daemon owns the bottle and answers `sevo` on the control port; anything
/// that needs the page, Steam's popups or a window inventory is passed through
/// to here, and the daemon's own commands — reload, dismiss, open the library —
/// arrive the same way. Loopback only, same exposure class as the bridge's
/// `/__eval`.
@MainActor
final class AppLinkServer {
    private let supervisor: ClientSupervisor
    private let host: SteamWebHost
    private let bridge: SteamBridge
    private var server: HTTPServer?

    init(supervisor: ClientSupervisor, host: SteamWebHost, bridge: SteamBridge) {
        self.supervisor = supervisor
        self.host = host
        self.bridge = bridge
    }

    /// Takes the link port, exclusively: a second copy of the app answering
    /// the daemon's commands would render Steam twice and reload each other's
    /// pages. The caller stops the launch when this answers false.
    func start() async -> Bool {
        do {
            let server = try HTTPServer(
                port: BridgePorts.appLink, exclusive: true,
            ) { [weak self] request in
                await self?.handle(request) ?? .error(500, "app link gone")
            }
            try await server.startWaitingForThePort()
            self.server = server
            EventLog.shared.log(.app, "daemon link up on :\(BridgePorts.appLink)")
            return true
        } catch {
            EventLog.shared.log(
                .app,
                "daemon link failed to start: \(error.localizedDescription)",
            )
            return false
        }
    }

    /// The daemon's own traffic: its commands, its verdict, its log.
    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/command"):
            return await run(Self.value(of: "verb", in: request.query))
        case ("POST", "/command/launch"):
            guard let appID = Int(Self.value(of: "appid", in: request.query)) else {
                return .error(400, "pass ?appid=<steam app id>")
            }
            host.launchGame(appID: appID)
            return Self.json(#"{"ok":true}"#)
        case ("POST", "/state"):
            guard let snapshot = try? JSONDecoder()
                .decode(SupervisorSnapshot.self, from: request.body) else {
                return .error(400, "expected a SupervisorSnapshot body")
            }
            supervisor.apply(snapshot)
            return Self.json(#"{"ok":true}"#)
        case ("POST", "/popups/sweep"):
            let scope = PopupSweepScope(rawValue: Self.value(of: "scope", in: request.query))
            return await Self.json(ClientLifecycle.hideVisibleClientPopups(scope ?? .everything))
        case ("POST", "/services/ready"):
            let ready = await bridge.clientServicesReady()
            return Self.json(#"{"ready":\#(ready.map(String.init) ?? "null")}"#)
        case ("POST", "/log"):
            guard let line = try? JSONDecoder()
                .decode(RemoteLogLine.self, from: request.body),
                let category = EventLog.Category(rawValue: line.category) else {
                return .error(400, "expected a RemoteLogLine body")
            }
            EventLog.shared.ingest(category, line.message, at: line.date)
            return Self.json(#"{"ok":true}"#)
        case ("POST", "/daemon/repair"):
            // Only the app can rebuild the daemon's registration
            // (`SMAppService` acts for the bundle that registered it), so
            // `sevo daemon repair` asks this port rather than the control port,
            // which is exactly what is down when the helper will not launch.
            return await repairDaemon(force: Self.value(of: "force", in: request.query) == "1")
        default:
            return await pageVerb(request)
        }
    }

    /// The app's own verbs, proxied here from the control port so `sevo` asks
    /// one port for everything.
    private func pageVerb(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/windows"):
            return windows()
        case ("GET", "/game/window"):
            let payload = GameWindow.current() ?? ["present": false]
            let data = (try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys],
            )) ?? Data("{}".utf8)
            return Self.json(String(decoding: data, as: UTF8.self))
        case ("GET", "/benchmark/browser-views"):
            return Self.json(host.storeBrowserViewStatuses())
        case ("POST", "/steam/show"):
            host.showSteam()
            return Self.json(#"{"ok":true,"note":"showing Steam; poll /windows"}"#)
        case ("POST", "/chat/open"):
            // The call a clicked notification makes, reachable from outside
            // so `Tools/chat-scenarios.sh` can drive the asked path without
            // a friend and a real banner to click.
            let accountID = Self.value(of: "accountid", in: request.query)
            guard let id = UInt32(accountID) else {
                return .error(400, "pass ?accountid=<32-bit account id>")
            }
            host.openChat(accountID: String(id))
            return Self.json(#"{"ok":true,"note":"opening the chat; poll /windows"}"#)
        case ("POST", "/steam/close"):
            host.closeSteam()
            return Self.json(#"{"ok":true,"note":"Steam window torn down"}"#)
        case ("POST", "/menu/cancel"):
            return cancelMenuTracking()
        case ("GET", "/menu/session"):
            // Which menu-bar impl is in use and whether a tracking session
            // is live, with the two flags the watchdog's levers turn on —
            // readable from outside while the main thread is stuck in it.
            guard let data = try? JSONSerialization.data(
                withJSONObject: MenuTrackingWatchdog.diagnostics(), options: [.sortedKeys],
            ) else { return .error(500, "diagnostics failed") }
            return Self.json(String(decoding: data, as: UTF8.self))
        case ("GET", "/debug"), ("POST", "/debug/on"), ("POST", "/debug/off"):
            return DebugModeSwitch.shared.handleControl(request)
        case ("POST", "/benchmark/smoke"):
            guard ProcessInfo.processInfo.environment["SEVO_ENABLE_BENCHMARKS"] == "1" else {
                return .error(403, "set SEVO_ENABLE_BENCHMARKS=1 before launching Sevoflurane")
            }
            do {
                let report = try await host.runSmokeBenchmark(
                    options: SteamWebHost.BenchmarkOptions(query: request.query),
                )
                return Self.json(report)
            } catch {
                return .error(409, error.localizedDescription)
            }
        default:
            return .error(404, "Not Found")
        }
    }

    /// One command from the daemon's state machine.
    private func run(_ verb: String) async -> HTTPResponse {
        guard let command = PageCommand(rawValue: verb) else {
            return .error(400, "unknown command \(verb)")
        }
        switch command {
        case .connectToClient:
            // The answer travels back as a fact, not as this reply: the
            // connection can take the bridge's whole 30 s budget and the
            // daemon has a boot cycle to run in the meantime.
            Task(name: "Connect the bridge to the client") {
                await self.bridge.waitForClientConnection()
            }
        case .reload: host.reload()
        case .rebuild: host.rebuildContextPage()
        case .dismissWindows: host.dismissWindows()
        case .dismissWindowsForQuit: host.dismissWindows(reason: .appQuitting)
        case .clientStopBegan: host.beginClientStop()
        case .clientStopEnded: host.endClientStop()
        case .showLibrary: host.showSteam()
        }
        return Self.json(#"{"ok":true}"#)
    }

    /// Rebuilds the daemon's registration and reports the outcome, so a user
    /// stuck on a helper that will not launch can recover from the terminal. A
    /// daemon that is already answering is left running unless `force` is set.
    private func repairDaemon(force: Bool) async -> HTTPResponse {
        let (result, note): (String, String) = switch await supervisor.repairDaemon(force: force) {
        case .reachable:
            ("repaired", "the background helper was rebuilt and is answering")
        case .alreadyHealthy:
            ("alreadyHealthy", "the background helper is already healthy — nothing to repair")
        case let .needsApproval(message):
            ("needsApproval", message)
        case let .failed(reason):
            ("failed", reason)
        }
        return Self.json(
            #"{"result":\#(JSLiteral.string(result)),"note":\#(JSLiteral.string(note))}"#,
        )
    }

    /// Ends every menu-bar tracking session, answering which root menus were
    /// open. A stuck session leaves the app looking frozen while this listener
    /// still answers, so it is both the tester's way out and the experiment
    /// that says whether a session can be broken from outside.
    private func cancelMenuTracking() -> HTTPResponse {
        let payload: [String: Any] = ["ok": true, "open": host.menuMirror?.cancelTracking() ?? []]
        let data = (try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys],
        )) ?? Data("{}".utf8)
        return Self.json(String(decoding: data, as: UTF8.self))
    }

    /// Every window the app owns — the diagnostic for "what is this window
    /// Sevoflurane put on my screen".
    private func windows() -> HTTPResponse {
        guard let data = try? JSONSerialization.data(
            withJSONObject: host.windowInventory(), options: [.sortedKeys],
        ) else { return .error(500, "inventory failed") }
        return .ok(data, type: "application/json")
    }

    /// One query parameter's value, or the empty string.
    private nonisolated static func value(of name: String, in query: String) -> String {
        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2, parts[0] == name { return parts[1] }
        }
        return ""
    }

    private nonisolated static func json(_ body: String) -> HTTPResponse {
        .ok(Data(body.utf8), type: "application/json")
    }

    private nonisolated static func json(_ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return .error(500, "could not encode response")
        }
        return .ok(data, type: "application/json")
    }
}
