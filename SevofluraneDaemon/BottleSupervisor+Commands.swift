import Foundation

extension BottleSupervisor {
    /// Starts a game, restarting the client first when that game asks for a
    /// renderer the running session does not have.
    ///
    /// A renderer the env files can carry reaches the game on its own, in its
    /// per-program file; every other one reaches it through the environment of
    /// the process tree Steam already lives in, so it takes a new tree. The
    /// menu bar says so before the click; this is the click.
    func launch(appID: Int, name: String, renderer explicit: Renderer? = nil) async {
        // The renderer this launch has to move the bottle onto — an explicit
        // "Run with X" wins over the game's own choice, and neither persists
        // past the launch beyond the bottle default it sets.
        let desired = BottleGraphics.rendererToStage(forApp: appID, explicit: explicit)
        if let desired, desired != BottleGraphics.currentSelection().renderer {
            do {
                let current = BottleGraphics.currentSelection()
                try BottleGraphics.applyToActiveEngine(
                    BottleGraphics.Selection(
                        renderer: desired, msync: current.msync, gpu: current.gpu,
                    ),
                )
            } catch {
                log.log(.client, "could not set \(desired.label) for \(name): \(error)")
            }
        }

        let change = BottleGraphics.graphicsChangeSinceBoot()
        let mustBounce = change.bounce
            || (change.restage && !BottleGraphics.hotRestageSupported)

        if mustBounce {
            // msync or the engine moved: a fresh wineserver is owed, so the
            // client restarts and the spawn reconciles the tree.
            log.log(.client, "\(name) needs a client restart for its graphics")
            recentRestarts.removeAll()
            hygieneTried = false
            await restartClient(reason: "graphics change for \(name)")
            // The client is up and the page reloaded; Steam's own services
            // need a moment more before a launch request means anything.
            for _ in 0 ..< 40 where health != .healthy {
                try? await Task.sleep(for: .seconds(3))
            }
        } else if change.restage {
            // Hot: only the renderer or D3DMetal version moved. Restage the
            // tree under the running client; the game loads the new DLLs when
            // it launches, and the booted record now matches.
            log.log(.client, "restaging graphics for \(name) without a restart")
            if let note = BottleGraphics.stagingNote(BottleGraphics.reconcileManagedTree()) {
                log.log(.client, note)
            }
            BottleGraphics.recordBootedSelection()
        }
        await app.launchGame(appID: appID)
    }

    /// The menu-bar button and the control endpoint: restarts
    /// unconditionally, with a fresh crash-loop budget — the user asking is
    /// what distinguishes "try again" from a loop. A ladder already in flight
    /// runs again rather than being fought or refused.
    func restartNow(reason: String = "manual restart from the menu bar") {
        setPaused(false, note: "auto-restart resumed (manual restart)")
        recentRestarts.removeAll()
        hygieneTried = false
        Task(name: "Manual client restart") {
            await restartClient(reason: reason)
        }
    }

    /// The heavier menu-bar restart: the whole fake Windows comes down and
    /// boots fresh — for when the machine itself is suspect, not just Steam.
    func restartWindowsNow() {
        setPaused(false, note: "auto-restart resumed (Windows restart)")
        recentRestarts.removeAll()
        hygieneTried = false
        Task(name: "Manual Windows restart") {
            await restartClient(
                reason: "manual Windows restart from the menu bar",
                fullWindows: true,
            )
        }
    }

    /// The escape hatch when a graceful restart is itself hung: SIGKILL the
    /// Steam client straight away, then bring it back clean. `everything`
    /// takes the whole fake machine — games and services included — down
    /// first. The crash-loop budget resets because the user asked.
    func forceQuit(_ scope: ClientLifecycle.ForceScope) {
        setPaused(false, note: "auto-restart resumed (force-quit and restart)")
        recentRestarts.removeAll()
        hygieneTried = false
        Task(name: "Force quit \(scope == .steam ? "Steam" : "everything")") {
            let killed = await ClientLifecycle.forceQuit(scope)
            log.log(
                .client,
                "force-quit \(scope == .steam ? "Steam" : "everything")"
                    + " — \(killed.count) process(es) killed, restarting clean",
            )
            await restartClient(
                reason: "force-quit from the menu bar",
                fullWindows: scope == .everything,
            )
        }
    }

    /// Trashes Steam's shader cache and brings the client back: the bottle
    /// comes down first so nothing holds the cache, it is cleared, then the
    /// client relaunches if one is still wanted. Only `steamapps/shadercache`
    /// is removed — saves and game files stay — and Steam rebuilds it.
    func clearShaderCache() {
        recentRestarts.removeAll()
        hygieneTried = false
        Task(name: "Clear the shader cache") {
            await app.duringClientStop {
                await ClientLifecycle.stopAll(gracePolls: 10, hidingPopups: true)
            }
            let cleared = ClientLifecycle.clearShaderCache()
            log.log(.supervisor, cleared ? "shader cache cleared" : "no shader cache to clear")
            await restartClient(reason: "shader cache cleared")
        }
    }

    /// Whether the restart ladder is mid-flight — control verbs that would
    /// race it (`sevo client stop`) refuse instead of interleaving.
    var isBusyRestarting: Bool {
        isRestarting
    }

    /// `sevo client stop`: pauses supervision (so nothing relaunches the
    /// client behind the CLI's back) and brings the bottle down.
    func stopForControl() async {
        guard !isQuitting, !isRestarting else { return }
        endBoot()
        setPaused(true, note: "auto-restart paused (sevo client stop)")
        // A deliberate stop should look like one: the app's own library
        // window comes down first (left up it freezes dimmed over the whole
        // stop), and the client's shutdown dialog is hidden as it exits.
        await app.send(.dismissWindows)
        await app.duringClientStop {
            await ClientLifecycle.stopAll(gracePolls: 10, hidingPopups: true)
        }
        log.log(.supervisor, "client stopped (sevo)")
    }

    /// Whether a provisioning failure is holding the client down: the last
    /// setup pass for this engine and bottle stopped at a stage that leaves
    /// nothing to start, and nobody has retried it or asked for the client
    /// anyway (Settings › Engine). Says so in the log once per attempt,
    /// because a client that never comes up is otherwise a mystery.
    func provisioningBlocksStart(reason: String) -> Bool {
        guard let failure = BottleReadiness.clientStartBlock else { return false }
        log.log(
            .supervisor,
            "not starting the client (\(reason)): the bottle is unfinished — \(failure)",
        )
        return true
    }

    /// `sevo client start`: resumes supervision, and restarts the client if
    /// it is not already up — the supervisor's ladder, not a bare launch.
    func startForControl() {
        setPaused(false, note: "auto-restart resumed (sevo client start)")
        Task(name: "sevo client start") {
            if await ClientLifecycle.probeClient() != .up {
                await restartClient(reason: "sevo client start")
            }
        }
    }

    /// Quit teardown: quitting Sevoflurane quits Steam. Stops wanting a client
    /// so nothing relaunches it, then brings every bottle process down — the
    /// client's processes are launched detached, so without this they outlive
    /// the session (and a leaked webhelper window parks a dead icon in the
    /// Dock). Reached only from `/quit` and `SIGTERM`: a bottle that nobody
    /// asked to come down keeps running, which is the whole of what surviving
    /// an app crash means.
    ///
    /// The daemon itself stays up and idle afterwards — it still answers
    /// `sevo status`, and the next ask starts a client again.
    func shutdownForQuit() async {
        guard !isQuitting else { return }
        isQuitting = true
        wantsClient = false
        endBoot()
        refreshHealth()
        log.log(.supervisor, "quit: bringing the bottle down")
        // The last thing a user sees of this app is the teardown, so the
        // popup sweep runs here too: the client puts up "Shutting down
        // Steam…" on its way out, and a quit is the one moment nothing else
        // is left to hide it.
        await app.send(.dismissWindowsForQuit)
        await app.duringClientStop {
            await ClientLifecycle.stopAll(gracePolls: 8, hidingPopups: true)
        }
        let survivors = await ClientLifecycle.bottleProcessIDs()
        log.log(
            .supervisor,
            survivors.isEmpty
                ? "quit: bottle is down"
                : "quit: pids \(survivors) survived SIGKILL",
        )
        // The next client is a start: the one this session saw is gone on
        // purpose, and the daemon outlives the app that asked.
        hasSeenClientUp = false
        hasBeenHealthy = false
        isQuitting = false
        refreshHealth()
    }
}
