import Foundation

/// The daemon half of the `sevo` contract: a loopback HTTP endpoint the CLI —
/// and through it, agents — uses to drive supervision. A verb keeps its path
/// and its JSON wherever it is served, so `sevo` never needs to know which
/// process answers it.
///
/// Verbs that need the page rather than the client are proxied to the app
/// (``AppLink/proxy(_:)``) and answer 409 when no app is running. Programs of
/// this account are trusted; web pages and other accounts are not.
/// ``LoopbackGate/control`` refuses any request that carries a browser's
/// `Origin` or a foreign `Host`, and answers 401 to one without this
/// account's ``ControlToken``, before any verb runs.
@MainActor
final class ControlServer {
    private let supervisor: BottleSupervisor
    private let app: AppLink
    private let onQuit: @MainActor () async -> Void
    private var server: HTTPServer?

    /// The app's own verbs, served by the app and passed through from here.
    private static let proxied: Set<String> = [
        "/windows",
        "/game/window",
        "/benchmark/browser-views",
        "/benchmark/smoke",
        "/steam/show",
        "/steam/close",
        "/chat/open",
        "/menu/cancel",
        "/debug",
        "/debug/on",
        "/debug/off",
    ]

    init(
        supervisor: BottleSupervisor,
        app: AppLink,
        onQuit: @escaping @MainActor () async -> Void,
    ) {
        self.supervisor = supervisor
        self.app = app
        self.onQuit = onQuit
    }

    enum StartOutcome {
        case serving
        /// Another supervisor is running, and this process must not become a
        /// second owner of the bottle.
        case anotherSupervisorHoldsThePort
        case failed
    }

    /// Takes the control port, exclusively.
    func start() async -> StartOutcome {
        do {
            let server = try HTTPServer(
                port: BridgePorts.control, gate: .control, exclusive: true,
            ) { [weak self] request in
                await self?.handle(request) ?? .error(500, "control server gone")
            }
            try await server.startWaitingForThePort()
            self.server = server
            EventLog.shared.log(.supervisor, "control endpoint up on :\(BridgePorts.control)")
            return .serving
        } catch HTTPServer.StartFailure.portIsTaken {
            let holder = await Self.whoHoldsTheControlPort()
            EventLog.shared.log(
                .supervisor,
                "not starting: \(holder) already holds :\(BridgePorts.control) — "
                    + "one supervisor owns the bottle",
            )
            return .anotherSupervisorHoldsThePort
        } catch {
            EventLog.shared.log(
                .supervisor,
                "control endpoint failed to start: \(error.localizedDescription)",
            )
            return .failed
        }
    }

    /// Asks the port itself what is on the other end, so the refusal names it.
    private static func whoHoldsTheControlPort() async -> String {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.control)/status") else { return "something" }
        var request = URLRequest(url: url)
        ControlToken.authorize(&request)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "something" }
        guard status["daemon"] as? String == "running" else {
            return "a process that is not a Sevoflurane daemon"
        }
        return "a Sevoflurane \(status["version"] as? String ?? "?") daemon"
    }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if Self.proxied.contains(request.path) {
            return await app.proxy(request)
        }
        switch (request.method, request.path) {
        case ("GET", "/status"):
            return await status()
        case ("GET", "/log/tail"):
            return await Self.logTail(query: request.query)
        case ("POST", "/engine/use"):
            return useEngine(query: request.query)
        case ("POST", "/supervisor/pause"), ("POST", "/supervisor/resume"):
            let wantPaused = request.path.hasSuffix("pause")
            // The flag itself, not the verdict: a supervisor nobody has asked
            // for a client also reads as paused.
            supervisor.setPaused(
                wantPaused, note: wantPaused ? "auto-restart paused" : "auto-restart resumed",
            )
            return Self.json(#"{"ok":true}"#)
        case ("POST", "/app/facts"):
            guard let facts = try? JSONDecoder().decode(PageFacts.self, from: request.body) else {
                return .error(400, "expected a PageFacts body")
            }
            // `hello` tells the app whether this daemon had it already: an
            // app that believed itself attached and is greeted as new has
            // posted to a daemon that was rebuilt or relaunched under it.
            let isNew = app.attach(facts)
            if isNew {
                supervisor.appDidAttach()
            }
            supervisor.wantClient(because: "Sevoflurane is running")
            return Self.json(#"{"ok":true,"hello":\#(isNew)}"#)
        case ("POST", "/app/detach"):
            app.detach(reason: "the app said goodbye")
            return Self.json(#"{"ok":true}"#)
        default:
            return await clientVerb(request)
        }
    }

    /// Everything that moves the client or the bottle. One owner, one door:
    /// ``ClientVerb/admit(method:path:wantClient:)`` names the verb before the
    /// supervisor hears of the request, so a request it refuses changes
    /// nothing.
    private func clientVerb(_ request: HTTPRequest) async -> HTTPResponse {
        switch ClientVerb.admit(method: request.method, path: request.path, wantClient: { reason in
            supervisor.wantClient(because: reason)
        }) {
        case let .verb(verb):
            await perform(verb, request)
        case let .refused(response):
            response
        }
    }

    private func perform(_ verb: ClientVerb, _ request: HTTPRequest) async -> HTTPResponse {
        switch verb {
        case .restart:
            return restart(query: request.query)
        case .showLibraryWhenHealthy:
            supervisor.showLibraryWhenHealthy()
            return Self.json(#"{"ok":true}"#)
        case .wake:
            // The app sees some deaths first — the bridge's transport closes
            // four seconds before the launcher exits — so it says so rather
            // than leaving the cycle to notice at its next tick.
            supervisor.wake(.control("Sevoflurane saw something change"))
            return Self.json(#"{"ok":true}"#)
        case .start:
            supervisor.startForControl()
            return Self.json(#"{"ok":true,"note":"start begun; poll /status"}"#)
        case .stop:
            return await stop()
        case .forceQuit:
            let scope: ClientLifecycle.ForceScope =
                ["all", "everything"].contains(Self.value(of: "scope", in: request.query))
                    ? .everything : .steam
            supervisor.forceQuit(scope)
            return Self.json(#"{"ok":true,"note":"force-quit begun; poll /status"}"#)
        case .quit:
            // The quit contract: the app asks once, on its way out, and the
            // bottle comes down with it. A crash sends nothing, which is why
            // a crash leaves the game running.
            await onQuit()
            return Self.json(#"{"ok":true,"note":"bottle down"}"#)
        case .clearShaderCache:
            supervisor.clearShaderCache()
            return Self.json(#"{"ok":true,"note":"clearing shader cache; restarting — poll /status"}"#)
        case .launchGame:
            return await launchGame(query: request.query)
        case .runInBottle:
            return await runInBottle(request)
        case .launchInBottle:
            return await launchInBottle(request)
        case .launchProgram:
            return await launchProgram(query: request.query)
        case .runProgram:
            return await runProgram(request)
        }
    }

    /// `?windows=1` restarts Windows inside the bottle; otherwise the client,
    /// logged with `?reason=`.
    private func restart(query: String) -> HTTPResponse {
        let reason = Self.value(of: "reason", in: query)
        if Self.value(of: "windows", in: query) == "1" {
            supervisor.restartWindowsNow()
        } else {
            supervisor.restartNow(reason: reason.isEmpty ? "sevo client restart" : reason)
        }
        return Self.json(#"{"ok":true,"note":"restart begun; poll /status"}"#)
    }

    private func stop() async -> HTTPResponse {
        guard !supervisor.isBusyRestarting else {
            return .error(409, "restart in progress")
        }
        await supervisor.stopForControl()
        return Self.json(#"{"ok":true,"note":"client stopped; auto-restart paused"}"#)
    }

    /// Starts a game, restarting the client first when the game is pinned to
    /// a renderer the running session does not have. The restart is why this
    /// is the daemon's verb and not the app's: nothing outside the supervisor
    /// launches or kills bottle processes. `option` answers Steam's
    /// launch-option question ahead of it.
    ///
    /// `delivered` is false when no app took the launch: the bottle is ready
    /// for the game, and the caller starts it in the client itself.
    private func launchGame(query: String) async -> HTTPResponse {
        guard let appID = Int(Self.value(of: "appid", in: query)) else {
            return .error(400, "pass ?appid=<steam app id>")
        }
        let given = Self.value(of: "name", in: query)
        let name = given.isEmpty ? String(appID) : given
        let renderer = Renderer(rawValue: Self.value(of: "renderer", in: query))
        let option = Int(Self.value(of: "option", in: query))
        let delivered = await supervisor.launch(
            appID: appID, name: name, renderer: renderer, option: option,
        )
        return Self.json(#"{"ok":true,"delivered":\#(delivered),"note":"launch requested"}"#)
    }

    /// Starts an adopted Windows program. The id is one of
    /// ``AdoptedPrograms``, not a Steam app id, and the two ranges never meet.
    private func launchProgram(query: String) async -> HTTPResponse {
        guard let id = Int(Self.value(of: "id", in: query)) else {
            return .error(400, "pass ?id=<adopted program id>")
        }
        let renderer = Renderer(rawValue: Self.value(of: "renderer", in: query))
        if let refusal = await supervisor.launchProgram(id: id, renderer: renderer) {
            return .error(refusal.status, refusal.reason)
        }
        return Self.json(#"{"ok":true,"note":"program started"}"#)
    }

    /// Runs one Windows program once, by path, keeping no record of it. The
    /// body is the macOS path and then its arguments, one per line, because a
    /// path holds characters a query string would have to survive.
    ///
    /// The reply waits for the program by default, which is what an installer
    /// is asked for; `?wait=0` answers as soon as it is spawned.
    private func runProgram(_ request: HTTPRequest) async -> HTTPResponse {
        let tokens = Self.programLines(request.body)
        guard let path = tokens.first else {
            return .error(400, "expected the program's path on the first body line")
        }
        let url = URL(fileURLWithPath: path)
        let arguments = Array(tokens.dropFirst())
        guard Self.value(of: "wait", in: request.query) != "0" else {
            await supervisor.startProgram(url, arguments: arguments)
            return Self.json(#"{"ok":true,"note":"program started"}"#)
        }
        let seconds = Int(Self.value(of: "timeout", in: request.query)) ?? 1800
        let result = await supervisor.runProgram(
            url, arguments: arguments, timeout: .seconds(seconds),
        )
        let body = #"{"status":\#(result.status.map(String.init) ?? "null"),"#
            + #""output":\#(JSLiteral.string(result.output))}"#
        return Self.json(body)
    }

    /// One Windows program run to completion inside the bottle — a dependency
    /// installer, a `reg` edit. The program list is the request body, one
    /// argument per line, because a Windows path holds characters a query
    /// string would have to survive.
    private func runInBottle(_ request: HTTPRequest) async -> HTTPResponse {
        let program = Self.programLines(request.body)
        guard !program.isEmpty else { return .error(400, "expected one argument per body line") }
        let seconds = Int(Self.value(of: "timeout", in: request.query)) ?? 600
        let result = await ClientLifecycle.runInBottle(program, timeout: .seconds(seconds))
        let body = #"{"status":\#(result.status.map(String.init) ?? "null"),"#
            + #""output":\#(JSLiteral.string(result.output))}"#
        return Self.json(body)
    }

    /// One windowed Windows program started inside the bottle — winecfg, the
    /// control panel. Returns as soon as it is spawned.
    private func launchInBottle(_ request: HTTPRequest) async -> HTTPResponse {
        let program = Self.programLines(request.body)
        guard !program.isEmpty else { return .error(400, "expected one argument per body line") }
        await ClientLifecycle.launchInBottle(program)
        return Self.json(#"{"ok":true}"#)
    }

    private static func programLines(_ body: Data) -> [String] {
        String(decoding: body, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Switch the active Wine engine (and optionally the bottle), then restart
    /// the client under it — the control face of Settings › Engine's Apply.
    ///
    /// `Engine.choose` has to run in this process, because `Engine.active` is
    /// cached per process: a caller that only wrote the shared preference
    /// would leave the process that relaunches the client on the old engine.
    /// The supervisor makes the choice between its ladder's stop and launch,
    /// so the stop still addresses the old engine's prefix and wineserver. A
    /// switch during a restart is taken as well: the ladder abandons the boot
    /// it is waiting on and runs again under the new engine.
    private func useEngine(query: String) -> HTTPResponse {
        let version = Self.value(of: "version", in: query)
        guard !version.isEmpty else {
            return .error(400, "pass ?version=<engine> (sevo engine list)")
        }
        let engine: Engine
        do {
            engine = try Engine.named(version)
        } catch {
            return .error(400, error.description)
        }
        guard engine.existsOnDisk else {
            return .error(404, "engine \(version) is not installed")
        }
        let bottle = Self.value(of: "bottle", in: query)
        let targetBottle = bottle.isEmpty ? SteamBottle.name : bottle
        guard SetupProbe.bottles(for: engine)
            .first(where: { $0.name == targetBottle })?.hasSteam == true
        else {
            return .error(
                409, "bottle \(targetBottle) has no Steam client for this engine — run setup",
            )
        }
        supervisor.wantClient(because: "an engine switch was asked for")
        EventLog.shared.log(
            .supervisor,
            "engine switch to \(engine.description), bottle \(targetBottle) asked for (control)",
        )
        supervisor.switchEngine(to: engine, bottle: bottle.isEmpty ? nil : bottle)
        return Self.json(#"{"ok":true,"note":"engine switched; restarting — poll /status"}"#)
    }

    private func status() async -> HTTPResponse {
        let version = Daemon.bundledAppVersion
        let debug = await app.debugIsOn()
        let body = #"{"app":\#(JSLiteral.string(app.isAttached ? "running" : "not running")),"#
            + #""daemon":"running","version":\#(JSLiteral.string(version)),"#
            + #""build":\#(JSLiteral.string(Daemon.build ?? "")),"#
            + #""host":\#(Self.hostJSON(supervisor.pressure)),"#
            + #""health":\#(JSLiteral.string(supervisor.health.wireName)),"#
            + #""detail":\#(JSLiteral.string(supervisor.statusText)),"#
            + #""debug":\#(debug),"#
            + #""needsAttention":\#(supervisor.health.needsAttention)}"#
        return Self.json(body)
    }

    /// The Mac's load as JSON while it is more than ordinary, `null` otherwise.
    private static func hostJSON(_ pressure: HostPressure) -> String {
        guard pressure.isElevated, let data = try? JSONEncoder().encode(pressure) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One query parameter's decoded value, or the empty string.
    private nonisolated static func value(of name: String, in query: String) -> String {
        QueryString.value(of: name, in: query)
    }

    /// Reads from the log's end, off the main actor: the log runs to
    /// megabytes before it rotates.
    @concurrent
    private nonisolated static func logTail(query: String) async -> HTTPResponse {
        let count = Int(value(of: "n", in: query)).map { max(1, min($0, 5000)) } ?? 50
        guard let lines = LogTail.lastLines(of: EventLog.fileURL, count: count) else {
            return .error(404, "no log file")
        }
        return .ok(Data((lines.joined(separator: "\n") + "\n").utf8), type: "text/plain; charset=utf-8")
    }

    private nonisolated static func json(_ body: String) -> HTTPResponse {
        .ok(Data(body.utf8), type: "application/json")
    }
}
