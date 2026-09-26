import Foundation

/// The lifecycle verbs. Mutating verbs route through the daemon's control
/// endpoint so the restart ladder has one owner and the bottle has one parent;
/// `--no-app` forces direct mode for debugging (with the daemon running it will
/// fight the supervisor — that's what the flag is for).
///
/// Every verb answers an ``Outcome``, not void: the reply is the observation.
/// The verdict is one of three words: `confirmed` the intended state was
/// reached, `noEffect` nothing changed because it was already so,
/// `unverifiable` the act may have landed but the wait ran out before it
/// could be seen. A `throw` is reserved for a
/// refusal that never began (unprovisioned, an endpoint that said no); a
/// timeout is an observation, not an error.
nonisolated enum ClientOps {
    enum Failure: Error {
        case message(String)
        /// The environment can't run a client at all (exit 3).
        case unprovisioned(String)
    }

    struct Outcome: Sendable {
        enum Verdict: String, Sendable { case confirmed, noEffect, unverifiable }
        let verdict: Verdict
        /// The act attempted, for the reply — "restart", "stop", "engine use".
        let intent: String
        /// One line a human can read; the structured state rides alongside it.
        let note: String
    }

    /// Resolves which mode a mutating verb runs in.
    static func supervisionIsRunning(noApp: Bool) async -> Bool {
        if noApp { return false }
        return await AppControl.status() != nil
    }

    static func start(noApp: Bool, progress: (String) -> Void) async throws -> Outcome {
        if !noApp, await AppControl.status() == nil {
            progress("supervision is not running — starting the daemon")
            switch await SupervisionDaemon.start() {
            case .started:
                progress("daemon started")
            case .notInstalled:
                throw Failure.message(
                    "supervision is not running: open Sevoflurane once so it can register "
                        + "its background helper, then try again",
                )
            case let .refused(reason):
                throw Failure.message("the daemon would not start: \(reason)")
            }
        }
        if await supervisionIsRunning(noApp: noApp) {
            let alreadyHealthy = await (AppControl.status())?["health"] as? String == "healthy"
            guard await AppControl.post("/client/start") != nil else {
                throw Failure.message("the daemon's control endpoint refused /client/start")
            }
            if alreadyHealthy {
                return Outcome(verdict: .noEffect, intent: "start", note: "client was already healthy")
            }
            progress("start requested via the daemon — waiting for healthy")
            return await pollAppHealthy(intent: "start", progress: progress)
        }
        try await ensureProvisioned()
        switch await ClientLifecycle.probeClient() {
        case .up:
            return Outcome(verdict: .noEffect, intent: "start", note: "client already running")
        case .portWithoutContext:
            throw Failure.message("CDP is up but lists no SharedJSContext — sevo recover")
        case .busy:
            throw Failure.message(
                "the client is running but too busy to answer CDP — try again shortly",
            )
        case .down:
            let alive = await ClientLifecycle.bottleProcessIDs(matching: "steam.exe")
            guard alive.isEmpty else {
                // The double-start hazard: a launcher that timed out can still
                // spawn a client later; stacking a second one on top corrupts
                // both.
                throw Failure.message(
                    "steam.exe already running (pids \(alive)) without CDP — sevo recover",
                )
            }
        }
        progress("launching the client")
        await ClientLifecycle.launchClient()
        return await pollClientUp(intent: "start", progress: progress)
    }

    static func stop(noApp: Bool, progress: (String) -> Void) async throws -> Outcome {
        if await supervisionIsRunning(noApp: noApp) {
            progress("stopping via the daemon (auto-restart pauses)")
            guard await AppControl.post("/client/stop", timeout: 120) != nil else {
                throw Failure.message(
                    "the daemon refused /client/stop (a restart may be in progress)",
                )
            }
            let survivors = await ClientLifecycle.bottleProcessIDs()
            return survivors.isEmpty
                ? Outcome(verdict: .confirmed, intent: "stop", note: "client stopped, auto-restart paused")
                : Outcome(
                    verdict: .unverifiable,
                    intent: "stop",
                    note: "stop requested; pids \(survivors) still up — poll sevo status",
                )
        }
        let before = await ClientLifecycle.bottleProcessIDs()
        guard !before.isEmpty else {
            return Outcome(verdict: .noEffect, intent: "stop", note: "nothing was running")
        }
        await ClientLifecycle.stopAll(gracePolls: 15) { progress($0) }
        let survivors = await ClientLifecycle.bottleProcessIDs()
        return survivors.isEmpty
            ? Outcome(verdict: .confirmed, intent: "stop", note: "client stopped")
            : Outcome(
                verdict: .unverifiable,
                intent: "stop",
                note: "pids \(survivors) survived the kill ladder — sevo client force-quit all",
            )
    }

    /// `windows` tears the whole fake Windows down — wineserver included — and
    /// boots it fresh, rather than keeping it warm across the client restart.
    /// A direct restart already brings everything down, so the flag only
    /// changes the supervised path.
    static func restart(
        noApp: Bool, windows: Bool = false, progress: (String) -> Void,
    ) async throws -> Outcome {
        if await supervisionIsRunning(noApp: noApp) {
            let path = windows ? "/client/restart?windows=1" : "/client/restart"
            guard await AppControl.post(path) != nil else {
                throw Failure.message("the daemon's control endpoint refused /client/restart")
            }
            progress(windows
                ? "Windows restart begun via the daemon — waiting for healthy"
                : "restart begun via the daemon — waiting for healthy")
            return await pollAppHealthy(intent: "restart", progress: progress)
        }
        _ = try await stop(noApp: true, progress: progress)
        return try await start(noApp: true, progress: progress).renamed("restart")
    }

    /// Trashes Steam's shader cache and brings the client back. Through the
    /// daemon it is one verb — the supervisor stops the bottle, clears the
    /// cache, and relaunches, so nothing holds the cache while it goes. Direct
    /// mode stops the bottle and clears, leaving the relaunch to `sevo client
    /// start` (there is no supervisor to bring it back). Never reaches saves or
    /// game files: only `steamapps/shadercache` is removed.
    static func clearShaderCache(noApp: Bool, progress: (String) -> Void) async throws -> Outcome {
        if await supervisionIsRunning(noApp: noApp) {
            guard await AppControl.post("/bottle/clear-shader-cache", timeout: 120) != nil else {
                throw Failure.message("the daemon refused /bottle/clear-shader-cache")
            }
            progress("shader cache clear requested via the daemon — waiting for healthy")
            return await pollAppHealthy(intent: "clear shader cache", progress: progress)
        }
        let alive = await ClientLifecycle.bottleProcessIDs()
        if !alive.isEmpty {
            progress("stopping the bottle before clearing the cache")
            await ClientLifecycle.stopAll(gracePolls: 10) { progress($0) }
        }
        let cleared = ClientLifecycle.clearShaderCache()
        return Outcome(
            verdict: cleared ? .confirmed : .noEffect, intent: "clear shader cache",
            note: cleared
                ? "shader cache cleared — sevo client start to relaunch"
                : "no shader cache to clear",
        )
    }

    /// `sevo engine use`: point the active engine (and optionally the bottle)
    /// at `engine`, then restart under it. Through the daemon, because
    /// `Engine.active` is cached per process and the daemon's copy is the one
    /// that tears the old Windows down and assembles the new invocation — a
    /// CLI that only wrote the shared preference would leave the process that
    /// relaunches the client still on the old engine. `--no-app` drives the
    /// client directly, for debugging.
    static func useEngine(
        _ engine: Engine, version: String, bottle: String?,
        noApp: Bool, progress: (String) -> Void,
    ) async throws -> Outcome {
        let alreadyActive = Engine.active == engine
        if !noApp, await AppControl.status() == nil {
            progress("supervision is not running — starting the daemon")
            switch await SupervisionDaemon.start() {
            case .started:
                break
            case .notInstalled:
                Engine.choose(engine)
                if let bottle, !bottle.isEmpty { SteamBottle.choose(bottle) }
                return Outcome(
                    verdict: .confirmed,
                    intent: "engine use",
                    note: "engine set to \(version); Sevoflurane is not installed here, so nothing was started",
                )
            case let .refused(reason):
                throw Failure.message("the daemon would not start: \(reason)")
            }
        }
        if await supervisionIsRunning(noApp: noApp) {
            var query = [(name: "version", value: version)]
            if let bottle, !bottle.isEmpty { query.append((name: "bottle", value: bottle)) }
            let path = "/engine/use?" + QueryString.encode(query)
            guard let reply = await AppControl.postReply(path, timeout: 120) else {
                throw Failure.message("the daemon's control endpoint did not answer /engine/use")
            }
            guard (200 ..< 300).contains(reply.status) else {
                throw Failure.message(
                    String(decoding: reply.body, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                )
            }
            // The switch lands in the daemon's process; this one resolved
            // `Engine.active` before it and reports the outcome from there.
            Engine.active = engine
            progress("engine switch requested via the daemon — waiting for healthy")
            return await pollAppHealthy(intent: "engine use", progress: progress)
        }
        // The stop runs under the old choice: its graceful ask, `wineserver -k`
        // and sweeps address the active engine's prefix, and choosing first
        // would leave the old client running beside the new one.
        _ = try await stop(noApp: true, progress: progress)
        Engine.choose(engine)
        if let bottle, !bottle.isEmpty { SteamBottle.choose(bottle) }
        try await ensureProvisioned()
        progress("engine set to \(version) — starting the client")
        let outcome = try await start(noApp: true, progress: progress).renamed("engine use")
        // A restart always moves the client, so its verdict is about health,
        // not about the switch; when nothing actually changed, say so.
        if alreadyActive, bottle == nil, outcome.verdict == .confirmed {
            return Outcome(
                verdict: .noEffect,
                intent: "engine use",
                note: "already on \(version); restarted, healthy",
            )
        }
        return outcome
    }

    /// Headless client refresh. Only sane with everything stopped — a live
    /// client and its updater racing each other corrupts the install.
    static func update(progress: (String) -> Void) async throws -> Outcome {
        try await ensureProvisioned()
        let alive = await ClientLifecycle.bottleProcessIDs()
        guard alive.isEmpty else {
            throw Failure.message("client processes running (pids \(alive)) — sevo client stop first")
        }
        progress("running the headless client update (takes ~1–5 min)")
        return await ClientLifecycle.headlessUpdate()
            ? Outcome(verdict: .confirmed, intent: "update", note: "client updated")
            : Outcome(
                verdict: .unverifiable,
                intent: "update",
                note: "updater did not exit cleanly — sevo logs",
            )
    }

    /// The wedge playbook: probe → reload/restart ladder. Recover fixes a
    /// *wedged* client; a client that simply isn't running is `client
    /// start`'s job — a stopped client is a state, not a fault.
    static func recover(deep: Bool, noApp: Bool, progress: (String) -> Void) async throws -> Outcome {
        let alive = await ClientLifecycle.bottleProcessIDs()
        guard !alive.isEmpty else {
            throw Failure.message("client is not running (nothing wedged) — use: sevo client start")
        }
        if await ClientLifecycle.probeClient() == .up, !deep {
            let services = try? await SteamJS.eval(
                "String(!!(window.App&&App.GetServicesInitialized&&App.GetServicesInitialized()))",
            )
            if services?.contains("true") == true {
                return Outcome(
                    verdict: .noEffect,
                    intent: "recover",
                    note: "client healthy (services initialized) — nothing to do",
                )
            }
            progress("CDP up but services dead — restarting the client")
        } else if !deep {
            progress("client wedged (CDP unreachable) — restarting")
        }

        if await supervisionIsRunning(noApp: noApp), !deep {
            guard await AppControl.post("/client/restart") != nil else {
                throw Failure.message("the daemon's control endpoint refused /client/restart")
            }
            return await pollAppHealthy(intent: "recover", progress: progress)
        }

        let viaApp = await supervisionIsRunning(noApp: noApp)
        if viaApp {
            guard await AppControl.post("/client/stop", timeout: 120) != nil else {
                throw Failure.message("the daemon refused /client/stop (a restart may be in progress)")
            }
        } else {
            await ClientLifecycle.stopAll(gracePolls: 15) { progress($0) }
        }
        if deep {
            progress("deep: trashing the bottle's htmlcache")
            if !ClientLifecycle.purgeHTMLCache() {
                progress("deep: no htmlcache to trash")
            }
            progress("deep: headless client repair (takes minutes)")
            if await !ClientLifecycle.headlessUpdate() {
                progress("deep: updater did not exit cleanly — continuing to launch")
            }
        }
        if viaApp {
            _ = await AppControl.post("/client/start")
            return await pollAppHealthy(intent: "recover", progress: progress)
        }
        progress("launching the client")
        await ClientLifecycle.launchClient()
        return await pollClientUp(intent: "recover", progress: progress)
    }

    // MARK: - Waiting

    /// Direct mode: CDP + SharedJSContext up is the bar (there is no page or
    /// bridge without the app). A timeout is `unverifiable`, not a throw — the
    /// client may still be coming up; the caller polls `sevo status`.
    static func pollClientUp(
        intent: String, timeout: Int = 180, progress: (String) -> Void,
    ) async -> Outcome {
        for waited in stride(from: 3, through: timeout, by: 3) {
            try? await Task.sleep(for: .seconds(3))
            if await ClientLifecycle.probeClient() == .up {
                return Outcome(
                    verdict: .confirmed,
                    intent: intent,
                    note: "client up — CDP + SharedJSContext after ~\(waited)s",
                )
            }
            if waited % 15 == 0 { progress("waiting for the client (\(waited)s)") }
        }
        return Outcome(
            verdict: .unverifiable,
            intent: intent,
            note: "client not up within \(timeout)s — sevo status / sevo doctor",
        )
    }

    /// Daemon mode: the supervisor's own healthy verdict (client + bridge +
    /// page + services) is the bar. Two consecutive healthy reads: right
    /// after a reload the *old* page still answers the services probe, so a
    /// single healthy can be a stale-page flicker that re-degrades a probe
    /// cycle later.
    static func pollAppHealthy(
        intent: String, timeout: Int = 300, progress: (String) -> Void,
    ) async -> Outcome {
        var lastDetail = ""
        var healthyStreak = 0
        for waited in stride(from: 3, through: timeout, by: 3) {
            try? await Task.sleep(for: .seconds(3))
            guard let status = await AppControl.status() else {
                return Outcome(
                    verdict: .unverifiable,
                    intent: intent,
                    note: "the daemon went away mid-operation — sevo logs",
                )
            }
            let health = status["health"] as? String ?? "?"
            if health == "healthy" {
                healthyStreak += 1
                if healthyStreak >= 2 {
                    return Outcome(
                        verdict: .confirmed,
                        intent: intent,
                        note: "healthy after ~\(waited)s",
                    )
                }
                continue
            }
            healthyStreak = 0
            if health == "gaveUp" {
                return Outcome(
                    verdict: .unverifiable,
                    intent: intent,
                    note: "supervisor gave up: \(status["detail"] as? String ?? "") — sevo logs",
                )
            }
            let detail = status["detail"] as? String ?? health
            if detail != lastDetail {
                lastDetail = detail
                progress(detail)
            }
        }
        return Outcome(
            verdict: .unverifiable,
            intent: intent,
            note: "not healthy within \(timeout)s — sevo doctor",
        )
    }

    /// Blocks until no bottle process remains, or the timeout — the `--gone`
    /// half of `sevo wait`.
    static func waitGone(timeout: Int, progress: (String) -> Void) async -> Outcome {
        for waited in stride(from: 2, through: timeout, by: 2) {
            if await (ClientLifecycle.bottleProcessIDs()).isEmpty {
                return Outcome(
                    verdict: .confirmed,
                    intent: "wait",
                    note: "client gone after ~\(waited)s",
                )
            }
            try? await Task.sleep(for: .seconds(2))
            if waited % 10 == 0 { progress("waiting for the client to go (\(waited)s)") }
        }
        let survivors = await ClientLifecycle.bottleProcessIDs()
        return Outcome(
            verdict: .unverifiable,
            intent: "wait",
            note: "pids \(survivors) still up after \(timeout)s",
        )
    }

    // MARK: - Adopted Windows programs

    /// Starts an adopted program through the daemon, which is the bottle's
    /// one parent. The observation is the spawn, not the program's own life:
    /// a game has no exit worth waiting for.
    static func launchProgram(id: Int, renderer: String?) async throws -> Outcome {
        guard let entry = AdoptedPrograms.entry(id) else {
            throw Failure.message("no adopted program with id \(id) — sevo program list")
        }
        let query = renderer.map { "&renderer=\($0)" } ?? ""
        // The daemon answers once the program has started. The first launch
        // of a program that needs a steam.exe parent creates that parent's
        // companion prefix first (`wineboot`, about 15 s), so allow for it.
        guard let reply = await AppControl.postReply("/program/launch?id=\(id)\(query)", timeout: 240) else {
            throw Failure.message("the daemon would not start \(entry.name) — sevo status")
        }
        // 409: it is starting or running already, which is what was asked
        // for, so the observation says that rather than failing.
        if reply.status == 409 {
            return Outcome(
                verdict: .confirmed, intent: "program launch",
                note: Self.refusalReason(reply.body) ?? "\(entry.name) is already running",
            )
        }
        guard (200 ..< 300).contains(reply.status) else {
            throw Failure.message(Self.refusalReason(reply.body) ?? "the daemon would not start \(entry.name) — sevo status")
        }
        return Outcome(
            verdict: .confirmed,
            intent: "program launch",
            note: "\(entry.name) started",
        )
    }

    /// The reason in a daemon refusal's body, which is `"<status> <reason>"`.
    private static func refusalReason(_ body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        guard let space = text.firstIndex(of: " ") else { return nil }
        let reason = text[text.index(after: space)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }

    /// Runs one Windows program once, by path. Waiting is what an installer
    /// is asked for; anything else is started and let go.
    static func runProgram(
        at path: String, arguments: [String], wait: Bool,
    ) async throws -> Outcome {
        let body = Data(([path] + arguments).joined(separator: "\n").appending("\n").utf8)
        let route = wait ? "/program/run?timeout=3600" : "/program/run?wait=0"
        guard let data = await AppControl.post(
            route, body: body, timeout: wait ? 3700 : 30,
        ) else {
            throw Failure.message("the daemon would not run \(path) — sevo status")
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard wait else {
            return Outcome(verdict: .confirmed, intent: "program run", note: "\(name) started")
        }
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (reply?["status"] as? Int).map(String.init) ?? "unknown"
        return Outcome(
            verdict: .confirmed,
            intent: "program run",
            note: "\(name) exited (status \(status))",
        )
    }

    private static func ensureProvisioned() async throws {
        let detection = await SetupProbe.detect()
        guard detection.hasEngine else {
            throw Failure.unprovisioned(
                "no usable engine — install CrossOver, or run: sevo engine install",
            )
        }
        guard SetupProbe.bottles(for: Engine.active).first(where: { $0.name == SteamBottle.name })?.hasSteam == true else {
            throw Failure.unprovisioned(
                "no Steam client in bottle '\(SteamBottle.name)' — run Sevoflurane's setup wizard",
            )
        }
        if let lease = ProvisioningLease.onConfiguredBottle {
            throw Failure.unprovisioned(
                "setup is still installing Steam in bottle '\(lease.name)' — start the client once it finishes",
            )
        }
    }
}

private extension ClientOps.Outcome {
    /// Same verdict and note, relabelled for the verb the caller is really in.
    func renamed(_ intent: String) -> Self {
        .init(verdict: verdict, intent: intent, note: note)
    }
}
