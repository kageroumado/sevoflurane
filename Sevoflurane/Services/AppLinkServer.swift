import Foundation

/// The app's half of the daemon link: the work only this process can do.
///
/// The daemon answers `sevo` on the control port and passes through anything
/// that needs the page, Steam's popups or a window inventory; its own commands
/// arrive the same way. Loopback only, behind ``LoopbackGate/appLink``:
/// programs of this account holding its ``ControlToken`` are admitted.
@MainActor
final class AppLinkServer {
    private let supervisor: ClientSupervisor
    private let host: SteamWebHost
    private let bridge: SteamBridge
    /// The open runs' frame counters, which `sevo perf mark` writes into.
    private let presentStats: PresentStats
    private var server: HTTPServer?
    /// Posts the notification with Undo after the helper applied a first
    /// launch's fixes to this app id.
    var onFixesApplied: ((Int) -> Void)?

    init(supervisor: ClientSupervisor, host: SteamWebHost, bridge: SteamBridge, presentStats: PresentStats) {
        self.supervisor = supervisor
        self.host = host
        self.bridge = bridge
        self.presentStats = presentStats
    }

    /// Takes the link port exclusively: a second copy answering the daemon
    /// would render Steam twice. The caller stops the launch on false.
    func start() async -> Bool {
        do {
            let server = try HTTPServer(
                port: BridgePorts.appLink, gate: .appLink, exclusive: true,
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

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/command"):
            return await run(Self.value(of: "verb", in: request.query))
        case ("POST", "/command/launch"):
            guard let appID = Int(Self.value(of: "appid", in: request.query)) else {
                return .error(400, "pass ?appid=<steam app id>")
            }
            // `option` answers Steam's launch-option question ahead of it.
            if let option = Int(Self.value(of: "option", in: request.query)) {
                host.launchOptionAnswers[appID] = option
                host.launchGame(appID: appID, forgettingChoice: true)
            } else {
                host.launchGame(appID: appID)
            }
            return Self.json(#"{"ok":true}"#)
        case ("POST", "/fixes/applied"):
            guard let appID = Int(Self.value(of: "appid", in: request.query)) else {
                return .error(400, "pass ?appid=<app id>")
            }
            onFixesApplied?(appID)
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
            // Only the bundle that registered can rebuild the registration
            // (`SMAppService`), so `sevo daemon repair` asks this port; the
            // control port is what is down when the helper will not launch.
            return await repairDaemon(force: Self.value(of: "force", in: request.query) == "1")
        case ("POST", "/perf/mark"):
            // `sevo perf mark`, straight to this port: the traces are written here.
            let label = Self.value(of: "label", in: request.query).removingPercentEncoding ?? ""
            let marked = presentStats.mark(label.isEmpty ? "mark" : label)
            return Self.json(#"{"marked":\#(marked)}"#)
        case ("POST", "/streamer/apply"):
            // `sevo streamer`, straight to this port: the reload is the app's alone.
            return applyStreamerMode(request)
        default:
            return await pageVerb(request)
        }
    }

    /// The app's own verbs, proxied from the control port so `sevo` asks one
    /// port for everything.
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
            // Reachable from outside so `Tools/chat-scenarios.sh` can drive a
            // notification click without a friend or a banner.
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
            // The menu-bar impl, whether a tracking session is live, and the
            // watchdog's two flags, readable while the main thread is stuck.
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

    /// `sevo streamer`: the switch arrives with the request, so the reload sees
    /// it even before the shared suite catches up here.
    private func applyStreamerMode(_ request: HTTPRequest) -> HTTPResponse {
        switch Self.value(of: "on", in: request.query) {
        case "1": StreamerMode.isOn = true
        case "0": StreamerMode.isOn = false
        default: break
        }
        host.applyStreamerMode()
        return Self.json(#"{"on":\#(StreamerMode.isOn)}"#)
    }

    private func run(_ verb: String) async -> HTTPResponse {
        guard let command = PageCommand(rawValue: verb) else {
            return .error(400, "unknown command \(verb)")
        }
        switch command {
        case .connectToClient:
            // The answer travels back as a fact: the connection can take the
            // bridge's whole 30 s budget, and the daemon has a boot cycle to
            // run meanwhile.
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

    /// Rebuilds the daemon's registration and reports the outcome; an answering
    /// daemon is left running unless `force` is set.
    private func repairDaemon(force: Bool) async -> HTTPResponse {
        let (result, note): (String, String) = switch await supervisor.repairDaemon(force: force) {
        case .reachable:
            ("repaired", "the background helper was rebuilt and is answering")
        case .alreadyHealthy:
            ("alreadyHealthy", "the background helper is already healthy — nothing to repair")
        case .restartedClient:
            ("restartedClient", "the background helper had given up on Steam — restarting it")
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
    /// open: the way out of a stuck session that leaves the app looking frozen.
    private func cancelMenuTracking() -> HTTPResponse {
        let payload: [String: Any] = ["ok": true, "open": host.menuMirror?.cancelTracking() ?? []]
        let data = (try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys],
        )) ?? Data("{}".utf8)
        return Self.json(String(decoding: data, as: UTF8.self))
    }

    /// Every window the app owns.
    private func windows() -> HTTPResponse {
        guard let data = try? JSONSerialization.data(
            withJSONObject: host.windowInventory(), options: [.sortedKeys],
        ) else { return .error(500, "inventory failed") }
        return .ok(data, type: "application/json")
    }

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
