import Foundation

/// The lifecycle verbs. When the app is running, mutating verbs route through
/// its control endpoint so the supervisor's ladder has one owner; otherwise
/// the CLI drives ``ClientLifecycle`` directly. `--no-app` forces direct mode
/// for debugging (with the app running it will fight the supervisor —
/// that's what the flag is for).
nonisolated enum ClientOps {
    enum Failure: Error {
        case message(String)
        /// The environment can't run a client at all (exit 3).
        case unprovisioned(String)
    }

    /// Resolves which mode a mutating verb runs in.
    static func appIsRunning(noApp: Bool) async -> Bool {
        if noApp { return false }
        return await AppControl.status() != nil
    }

    static func start(noApp: Bool, progress: (String) -> Void) async throws {
        if await appIsRunning(noApp: noApp) {
            guard await AppControl.post("/client/start") != nil else {
                throw Failure.message("the app's control endpoint refused /client/start")
            }
            progress("start requested via the app — waiting for healthy")
            try await pollAppHealthy(progress: progress)
            return
        }
        try await ensureProvisioned()
        switch await ClientLifecycle.probeClient() {
        case .up:
            progress("client already running")
            return
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
        try await pollClientUp(progress: progress)
    }

    static func stop(noApp: Bool, progress: (String) -> Void) async throws {
        if await appIsRunning(noApp: noApp) {
            progress("stopping via the app (auto-restart pauses)")
            guard await AppControl.post("/client/stop", timeout: 120) != nil else {
                throw Failure.message(
                    "the app refused /client/stop (a restart may be in progress)",
                )
            }
            progress("client stopped")
            return
        }
        await ClientLifecycle.stopAll(gracePolls: 15) { progress($0) }
        let survivors = await ClientLifecycle.bottleProcessIDs()
        guard survivors.isEmpty else {
            throw Failure.message("pids \(survivors) survived the kill ladder")
        }
        progress("client stopped")
    }

    static func restart(noApp: Bool, progress: (String) -> Void) async throws {
        if await appIsRunning(noApp: noApp) {
            guard await AppControl.post("/client/restart") != nil else {
                throw Failure.message("the app's control endpoint refused /client/restart")
            }
            progress("restart begun via the app — waiting for healthy")
            try await pollAppHealthy(progress: progress)
            return
        }
        try await stop(noApp: true, progress: progress)
        try await start(noApp: true, progress: progress)
    }

    /// Headless client refresh. Only sane with everything stopped — a live
    /// client and its updater racing each other corrupts the install.
    static func update(progress: (String) -> Void) async throws {
        try await ensureProvisioned()
        let alive = await ClientLifecycle.bottleProcessIDs()
        guard alive.isEmpty else {
            throw Failure.message("client processes running (pids \(alive)) — sevo client stop first")
        }
        progress("running the headless client update (takes ~1–5 min)")
        guard await ClientLifecycle.headlessUpdate() else {
            throw Failure.message("updater did not exit cleanly — sevo logs")
        }
        progress("client updated")
    }

    /// The wedge playbook: probe → reload/restart ladder. Recover fixes a
    /// *wedged* client; a client that simply isn't running is `client
    /// start`'s job — a stopped client is a state, not a fault.
    static func recover(deep: Bool, noApp: Bool, progress: (String) -> Void) async throws {
        let alive = await ClientLifecycle.bottleProcessIDs()
        guard !alive.isEmpty else {
            throw Failure.message("client is not running (nothing wedged) — use: sevo client start")
        }
        if await ClientLifecycle.probeClient() == .up, !deep {
            let services = try? await SteamJS.eval(
                "String(!!(window.App&&App.GetServicesInitialized&&App.GetServicesInitialized()))",
            )
            if services?.contains("true") == true {
                progress("client healthy (services initialized) — nothing to do")
                return
            }
            progress("CDP up but services dead — restarting the client")
        } else if !deep {
            progress("client wedged (CDP unreachable) — restarting")
        }

        if await appIsRunning(noApp: noApp), !deep {
            guard await AppControl.post("/client/restart") != nil else {
                throw Failure.message("the app's control endpoint refused /client/restart")
            }
            try await pollAppHealthy(progress: progress)
            return
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
            try await pollAppHealthy(progress: progress)
        } else {
            progress("launching the client")
            await ClientLifecycle.launchClient()
            try await pollClientUp(progress: progress)
        }
    }

    // MARK: - Waiting

    /// Direct mode: CDP + SharedJSContext up is the bar (there is no page or
    /// bridge without the app).
    private static func pollClientUp(progress: (String) -> Void) async throws {
        for waited in stride(from: 3, through: 180, by: 3) {
            try? await Task.sleep(for: .seconds(3))
            if await ClientLifecycle.probeClient() == .up {
                progress("client up — CDP + SharedJSContext after ~\(waited)s")
                return
            }
            if waited % 15 == 0 { progress("waiting for the client (\(waited)s)") }
        }
        throw Failure.message("client did not come up within 180s — sevo doctor")
    }

    /// App mode: the supervisor's own healthy verdict (client + bridge +
    /// page + services) is the bar. Two consecutive healthy reads: right
    /// after a reload the *old* page still answers the services probe, so a
    /// single healthy can be a stale-page flicker that re-degrades a probe
    /// cycle later.
    private static func pollAppHealthy(progress: (String) -> Void) async throws {
        var lastDetail = ""
        var healthyStreak = 0
        for waited in stride(from: 3, through: 300, by: 3) {
            try? await Task.sleep(for: .seconds(3))
            guard let status = await AppControl.status() else {
                throw Failure.message("the app went away mid-operation — sevo logs")
            }
            let health = status["health"] as? String ?? "?"
            if health == "healthy" {
                healthyStreak += 1
                if healthyStreak >= 2 {
                    progress("healthy after ~\(waited)s")
                    return
                }
                continue
            }
            healthyStreak = 0
            if health == "gaveUp" {
                throw Failure.message(
                    "supervisor gave up: \(status["detail"] as? String ?? "") — sevo logs",
                )
            }
            let detail = status["detail"] as? String ?? health
            if detail != lastDetail {
                lastDetail = detail
                progress(detail)
            }
        }
        throw Failure.message("not healthy within 300s — sevo doctor")
    }

    private static func ensureProvisioned() async throws {
        let detection = await SetupProbe.detect()
        guard detection.hasEngine else {
            throw Failure.unprovisioned(
                "no usable engine — install CrossOver, or run: sevo engine install")
        }
        guard detection.bottles.first(where: { $0.name == SteamBottle.name })?.hasSteam == true else {
            throw Failure.unprovisioned(
                "no Steam client in bottle '\(SteamBottle.name)' — run Sevoflurane's setup wizard",
            )
        }
    }
}
