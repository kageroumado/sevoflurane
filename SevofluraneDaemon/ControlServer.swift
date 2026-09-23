import Foundation

/// The daemon half of the `sevo` contract: a loopback HTTP endpoint the CLI —
/// and through it, agents — uses to drive supervision. A verb keeps its path
/// and its JSON wherever it is served, so `sevo` never needs to know which
/// process answers it.
///
/// Verbs that need the page rather than the client are proxied to the app
/// (``AppLink/proxy(_:)``) and answer 409 when no app is running. Local
/// programs are trusted; web pages are not, and ``LoopbackGate/control``
/// refuses any request that carries a browser's `Origin` or a foreign `Host`.
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

    /// Verbs that mean "there should be a client": a daemon that has not been
    /// asked launches nothing.
    private static let asksForAClient: Set<String> = [
        "/client/start",
        "/client/restart",
        "/client/forcequit",
        "/game/launch",
        "/library/show-when-healthy",
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

    /// Takes the control port, exclusively. Answers false when something else
    /// already holds it — which means another supervisor is running, and this
    /// process must not become a second owner of the bottle.
    func start() async -> Bool {
        do {
            let server = try HTTPServer(
                port: BridgePorts.control, gate: .control, exclusive: true,
            ) { [weak self] request in
                await self?.handle(request) ?? .error(500, "control server gone")
            }
            try await server.startWaitingForThePort()
            self.server = server
            EventLog.shared.log(.supervisor, "control endpoint up on :\(BridgePorts.control)")
            return true
        } catch HTTPServer.StartFailure.portIsTaken {
            let holder = await Self.whoHoldsTheControlPort()
            EventLog.shared.log(
                .supervisor,
                "not starting: \(holder) already holds :\(BridgePorts.control) — "
                    + "one supervisor owns the bottle",
            )
            return false
        } catch {
            EventLog.shared.log(
                .supervisor,
                "control endpoint failed to start: \(error.localizedDescription)",
            )
            return false
        }
    }

    /// Asks the port itself what is on the other end, so the refusal names it.
    private static func whoHoldsTheControlPort() async -> String {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.control)/status"),
              let (data, _) = try? await URLSession.shared.data(from: url),
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
            return Self.logTail(query: request.query)
        case ("POST", "/engine/use"):
            return useEngine(query: request.query)
        case ("POST", "/supervisor/pause"), ("POST", "/supervisor/resume"):
            let wantPaused = request.path.hasSuffix("pause")
            if (supervisor.health == .paused) != wantPaused {
                supervisor.togglePaused()
            }
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

    /// Everything that moves the client or the bottle. One owner, one door.
    private func clientVerb(_ request: HTTPRequest) async -> HTTPResponse {
        if Self.asksForAClient.contains(request.path) {
            supervisor.wantClient(because: "\(request.path) was asked for")
        }
        switch (request.method, request.path) {
        case ("POST", "/client/restart"):
            let reason = Self.value(of: "reason", in: request.query).removingPercentEncoding
            if Self.value(of: "windows", in: request.query) == "1" {
                supervisor.restartWindowsNow()
            } else {
                supervisor.restartNow(reason: reason ?? "sevo client restart")
            }
            return Self.json(#"{"ok":true,"note":"restart begun; poll /status"}"#)
        case ("POST", "/library/show-when-healthy"):
            supervisor.showLibraryWhenHealthy()
            return Self.json(#"{"ok":true}"#)
        case ("POST", "/supervisor/wake"):
            // The app sees some deaths first — the bridge's transport closes
            // four seconds before the launcher exits — so it says so rather
            // than leaving the cycle to notice at its next tick.
            supervisor.wake(.control("Sevoflurane saw something change"))
            return Self.json(#"{"ok":true}"#)
        case ("POST", "/client/start"):
            supervisor.startForControl()
            return Self.json(#"{"ok":true,"note":"start begun; poll /status"}"#)
        case ("POST", "/client/stop"):
            guard !supervisor.isBusyRestarting else {
                return .error(409, "restart in progress")
            }
            await supervisor.stopForControl()
            return Self.json(#"{"ok":true,"note":"client stopped; auto-restart paused"}"#)
        case ("POST", "/client/forcequit"):
            let scope: ClientLifecycle.ForceScope =
                ["all", "everything"].contains(Self.value(of: "scope", in: request.query))
                    ? .everything : .steam
            supervisor.forceQuit(scope)
            return Self.json(#"{"ok":true,"note":"force-quit begun; poll /status"}"#)
        case ("POST", "/quit"):
            // The quit contract: the app asks once, on its way out, and the
            // bottle comes down with it. A crash sends nothing, which is why
            // a crash leaves the game running.
            await onQuit()
            return Self.json(#"{"ok":true,"note":"bottle down"}"#)
        case ("POST", "/bottle/clear-shader-cache"):
            supervisor.clearShaderCache()
            return Self.json(#"{"ok":true,"note":"clearing shader cache; restarting — poll /status"}"#)
        case ("POST", "/game/launch"):
            return await launchGame(query: request.query)
        case ("POST", "/bottle/run"):
            return await runInBottle(request)
        case ("POST", "/bottle/launch"):
            return await launchInBottle(request)
        default:
            return await programVerb(request)
        }
    }

    /// The adopted Windows programs, which need no Steam client and so live
    /// past the verbs that ask for one.
    private func programVerb(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/program/launch"):
            await launchProgram(query: request.query)
        case ("POST", "/program/run"):
            await runProgram(request)
        default:
            .error(404, "Not Found")
        }
    }

    /// Starts a game the app's menu picked, restarting the client first when
    /// the game is pinned to a renderer the running session does not have. The
    /// restart is why this is the daemon's verb and not the app's: nothing
    /// outside the supervisor launches or kills bottle processes.
    private func launchGame(query: String) async -> HTTPResponse {
        guard let appID = Int(Self.value(of: "appid", in: query)) else {
            return .error(400, "pass ?appid=<steam app id>")
        }
        let name = Self.value(of: "name", in: query).removingPercentEncoding ?? String(appID)
        let renderer = Renderer(rawValue: Self.value(of: "renderer", in: query))
        await supervisor.launch(appID: appID, name: name, renderer: renderer)
        return Self.json(#"{"ok":true,"note":"launch requested"}"#)
    }

    /// Starts an adopted Windows program. The id is one of
    /// ``AdoptedPrograms``, not a Steam app id, and the two ranges never meet.
    private func launchProgram(query: String) async -> HTTPResponse {
        guard let id = Int(Self.value(of: "id", in: query)) else {
            return .error(400, "pass ?id=<adopted program id>")
        }
        let renderer = Renderer(rawValue: Self.value(of: "renderer", in: query))
        if let refusal = await supervisor.launchProgram(id: id, renderer: renderer) {
            return .error(404, refusal)
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
    /// `Engine.choose` has to run here, because `Engine.active` is cached per
    /// process: the supervisor's restart reads it to tear the old Windows down
    /// and assemble the new invocation. A caller that only wrote the shared
    /// preference would leave this process — the one that relaunches the
    /// client — still on the old engine, so the switch travels this endpoint.
    /// A switch during a restart is taken as well: the ladder abandons the
    /// boot it is waiting on and runs again under the new engine.
    private func useEngine(query: String) -> HTTPResponse {
        let version = Self.value(of: "version", in: query)
        guard !version.isEmpty else {
            return .error(400, "pass ?version=<engine> (sevo engine list)")
        }
        let engine: Engine = switch version {
        case "crossover": .crossover
        case "crossover-preview": .crossoverPreview
        default: .managed(version: version)
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
        Engine.choose(engine)
        if !bottle.isEmpty { SteamBottle.choose(bottle) }
        supervisor.wantClient(because: "an engine switch was asked for")
        EventLog.shared.log(
            .supervisor,
            "engine switched to \(engine.description), bottle \(targetBottle) (control)",
        )
        supervisor.restartNow(reason: "engine switched to \(engine.description)")
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

    /// One query parameter's value, or the empty string.
    private nonisolated static func value(of name: String, in query: String) -> String {
        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2, parts[0] == name { return parts[1] }
        }
        return ""
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
