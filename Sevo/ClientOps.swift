import Foundation

/// The lifecycle verbs. When the app is running, mutating verbs route through
/// its control endpoint so the supervisor's ladder has one owner; otherwise
/// the CLI drives ``ClientLifecycle`` directly. `--no-app` forces direct mode
/// for debugging (with the app running it will fight the supervisor —
/// that's what the flag is for).
///
/// Every verb answers an ``Outcome``, not void: the reply is the observation.
/// The verdict vocabulary mirrors rocuronium so an agent fluent in one reads
/// the other — `confirmed` the intended state was reached, `noEffect` nothing
/// changed because it was already so, `unverifiable` the act may have landed
/// but the wait ran out before it could be seen. A `throw` is reserved for a
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
    static func appIsRunning(noApp: Bool) async -> Bool {
        if noApp { return false }
        return await AppControl.status() != nil
    }

    static func start(noApp: Bool, progress: (String) -> Void) async throws -> Outcome {
        if await appIsRunning(noApp: noApp) {
            let alreadyHealthy = (await AppControl.status())?["health"] as? String == "healthy"
            guard await AppControl.post("/client/start") != nil else {
                throw Failure.message("the app's control endpoint refused /client/start")
            }
            if alreadyHealthy {
                return Outcome(verdict: .noEffect, intent: "start", note: "client was already healthy")
            }
            progress("start requested via the app — waiting for healthy")
            return await pollAppHealthy(intent: "start", progress: progress)
        }
        try await ensureProvisioned()
        switch await ClientLifecycle.probeClient() {
        case .up:
            return Outcome(verdict: .noEffect, intent: "start", note: "client already running")
        case .portWithoutContext:
            throw Failure.message("CDP is up but lists no SharedJSContext — sevo recover")
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
        if await appIsRunning(noApp: noApp) {
            progress("stopping via the app (auto-restart pauses)")
            guard await AppControl.post("/client/stop", timeout: 120) != nil else {
                throw Failure.message(
                    "the app refused /client/stop (a restart may be in progress)",
                )
            }
            let survivors = await ClientLifecycle.bottleProcessIDs()
            return survivors.isEmpty
                ? Outcome(verdict: .confirmed, intent: "stop", note: "client stopped, auto-restart paused")
                : Outcome(verdict: .unverifiable, intent: "stop",
                          note: "stop requested; pids \(survivors) still up — poll sevo status")
        }
        let before = await ClientLifecycle.bottleProcessIDs()
        guard !before.isEmpty else {
            return Outcome(verdict: .noEffect, intent: "stop", note: "nothing was running")
        }
        await ClientLifecycle.stopAll(gracePolls: 15) { progress($0) }
        let survivors = await ClientLifecycle.bottleProcessIDs()
        return survivors.isEmpty
            ? Outcome(verdict: .confirmed, intent: "stop", note: "client stopped")
            : Outcome(verdict: .unverifiable, intent: "stop",
                      note: "pids \(survivors) survived the kill ladder — sevo client force-quit all")
    }

    static func restart(noApp: Bool, progress: (String) -> Void) async throws -> Outcome {
        if await appIsRunning(noApp: noApp) {
            guard await AppControl.post("/client/restart") != nil else {
                throw Failure.message("the app's control endpoint refused /client/restart")
            }
            progress("restart begun via the app — waiting for healthy")
            return await pollAppHealthy(intent: "restart", progress: progress)
        }
        _ = try await stop(noApp: true, progress: progress)
        return try await start(noApp: true, progress: progress).renamed("restart")
    }

    /// `sevo engine use`: point the active engine (and optionally the bottle)
    /// at `engine`, then restart under it. Through the app when it is running,
    /// because `Engine.active` is cached in that process and the supervisor
    /// reads it to relaunch; directly otherwise, where this CLI process is the
    /// one that both writes the choice and launches.
    static func useEngine(
        _ engine: Engine, version: String, bottle: String?,
        noApp: Bool, progress: (String) -> Void,
    ) async throws -> Outcome {
        let alreadyActive = Engine.active == engine
        if await appIsRunning(noApp: noApp) {
            var path = "/engine/use?version=\(version)"
            if let bottle, !bottle.isEmpty { path += "&bottle=\(bottle)" }
            guard let reply = await AppControl.postReply(path, timeout: 120) else {
                throw Failure.message("the app's control endpoint did not answer /engine/use")
            }
            guard (200 ..< 300).contains(reply.status) else {
                throw Failure.message(
                    String(decoding: reply.body, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                )
            }
            // The switch lands in the app's process; this one resolved
            // `Engine.active` before it and reports the outcome from there.
            Engine.active = engine
            progress("engine switch requested via the app — waiting for healthy")
            return await pollAppHealthy(intent: "engine use", progress: progress)
        }
        Engine.choose(engine)
        if let bottle, !bottle.isEmpty { SteamBottle.choose(bottle) }
        try await ensureProvisioned()
        progress("engine set to \(version) — restarting the client")
        let outcome = try await restart(noApp: true, progress: progress).renamed("engine use")
        // A restart always moves the client, so its verdict is about health,
        // not about the switch; when nothing actually changed, say so.
        if alreadyActive, bottle == nil, outcome.verdict == .confirmed {
            return Outcome(verdict: .noEffect, intent: "engine use",
                           note: "already on \(version); restarted, healthy")
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
            : Outcome(verdict: .unverifiable, intent: "update",
                      note: "updater did not exit cleanly — sevo logs")
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
                return Outcome(verdict: .noEffect, intent: "recover",
                               note: "client healthy (services initialized) — nothing to do")
            }
            progress("CDP up but services dead — restarting the client")
        } else if !deep {
            progress("client wedged (CDP unreachable) — restarting")
        }

        if await appIsRunning(noApp: noApp), !deep {
            guard await AppControl.post("/client/restart") != nil else {
                throw Failure.message("the app's control endpoint refused /client/restart")
            }
            return await pollAppHealthy(intent: "recover", progress: progress)
        }

        let viaApp = await appIsRunning(noApp: noApp)
        if viaApp {
            guard await AppControl.post("/client/stop", timeout: 120) != nil else {
                throw Failure.message("the app refused /client/stop (a restart may be in progress)")
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
                return Outcome(verdict: .confirmed, intent: intent,
                               note: "client up — CDP + SharedJSContext after ~\(waited)s")
            }
            if waited % 15 == 0 { progress("waiting for the client (\(waited)s)") }
        }
        return Outcome(verdict: .unverifiable, intent: intent,
                       note: "client not up within \(timeout)s — sevo status / sevo doctor")
    }

    /// App mode: the supervisor's own healthy verdict (client + bridge +
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
                return Outcome(verdict: .unverifiable, intent: intent,
                               note: "the app went away mid-operation — sevo logs")
            }
            let health = status["health"] as? String ?? "?"
            if health == "healthy" {
                healthyStreak += 1
                if healthyStreak >= 2 {
                    return Outcome(verdict: .confirmed, intent: intent,
                                   note: "healthy after ~\(waited)s")
                }
                continue
            }
            healthyStreak = 0
            if health == "gaveUp" {
                return Outcome(verdict: .unverifiable, intent: intent,
                               note: "supervisor gave up: \(status["detail"] as? String ?? "") — sevo logs")
            }
            let detail = status["detail"] as? String ?? health
            if detail != lastDetail {
                lastDetail = detail
                progress(detail)
            }
        }
        return Outcome(verdict: .unverifiable, intent: intent,
                       note: "not healthy within \(timeout)s — sevo doctor")
    }

    /// Blocks until no bottle process remains, or the timeout — the `--gone`
    /// half of `sevo wait`, mirroring rocuronium's `wait --gone`.
    static func waitGone(timeout: Int, progress: (String) -> Void) async -> Outcome {
        for waited in stride(from: 2, through: timeout, by: 2) {
            if (await ClientLifecycle.bottleProcessIDs()).isEmpty {
                return Outcome(verdict: .confirmed, intent: "wait",
                               note: "client gone after ~\(waited)s")
            }
            try? await Task.sleep(for: .seconds(2))
            if waited % 10 == 0 { progress("waiting for the client to go (\(waited)s)") }
        }
        let survivors = await ClientLifecycle.bottleProcessIDs()
        return Outcome(verdict: .unverifiable, intent: "wait",
                       note: "pids \(survivors) still up after \(timeout)s")
    }

    private static func ensureProvisioned() async throws {
        let detection = await SetupProbe.detect()
        guard detection.hasEngine else {
            throw Failure.unprovisioned(
                "no usable engine — install CrossOver, or run: sevo engine install",
            )
        }
        guard detection.bottles.first(where: { $0.name == SteamBottle.name })?.hasSteam == true else {
            throw Failure.unprovisioned(
                "no Steam client in bottle '\(SteamBottle.name)' — run Sevoflurane's setup wizard",
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
