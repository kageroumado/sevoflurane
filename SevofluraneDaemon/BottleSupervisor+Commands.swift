import Foundation

extension BottleSupervisor {
    /// Starts a game, restarting the client first when its renderer needs a
    /// new process tree (one the env files cannot carry). Answers whether the
    /// app took the launch; with no app attached the bottle is still made ready.
    @discardableResult
    func launch(
        appID: Int, name: String, renderer explicit: Renderer? = nil, option: Int? = nil,
    ) async -> Bool {
        // Ahead of the renderer below: a first launch's fixes can pick it.
        await prepareLaunch(appID: appID)
        // An explicit "Run with X" wins over the game's own choice. Either
        // holds the bottle for this run; the run's end hands it back.
        let desired = BottleGraphics.rendererToStage(forApp: appID, explicit: explicit)
        if let desired, desired != BottleGraphics.currentSelection().renderer {
            do {
                try BottleGraphics.beginLaunchRenderer(desired, forApp: appID)
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
            // The ladder returns at the spawn; a launch request means nothing
            // until the client, the page and Steam's services are all up.
            if await !waitForHealthy(), case .gaveUp = health {
                log.log(.client, "not launching \(name): the client did not come back")
                return false
            }
        } else if change.restage {
            // Only the renderer or D3DMetal moved: restage under the running
            // client, and the game loads the new DLLs at launch.
            log.log(.client, "restaging graphics for \(name) without a restart")
            if let note = BottleGraphics.stagingNote(BottleGraphics.reconcileManagedTree()) {
                log.log(.client, note)
            }
            BottleGraphics.recordBootedSelection()
        }
        return await app.launchGame(appID: appID, option: option)
    }

    /// Restarts unconditionally with a fresh crash-loop budget, because a
    /// person asked. A ladder in flight runs again.
    func restartNow(reason: String = "manual restart from the menu bar") {
        setPaused(false, note: "auto-restart resumed (manual restart)")
        recentRestarts.removeAll()
        hygieneTried = false
        Task(name: "Manual client restart") {
            await restartClient(reason: reason)
        }
    }

    /// Moves the client onto another engine, and optionally another bottle.
    /// The choice is held until the ladder stops the running client, so the
    /// stop goes through the engine it runs on.
    func switchEngine(to engine: Engine, bottle: String?) {
        pendingSwitch = EngineSwitch(engine: engine, bottle: bottle)
        restartNow(reason: "engine switched to \(engine.description)")
    }

    /// Makes a held engine switch the active choice. Called with the old
    /// client down; answers whether there was one.
    @discardableResult
    func applyPendingSwitch() -> Bool {
        guard let next = pendingSwitch else { return false }
        pendingSwitch = nil
        if next.persists {
            Engine.choose(next.engine)
        } else {
            Engine.active = next.engine
        }
        if let bottle = next.bottle { SteamBottle.choose(bottle) }
        log.log(
            .supervisor,
            "engine is now \(next.engine.description), bottle \(SteamBottle.name)",
        )
        return true
    }

    /// Restarts with the whole Windows machine brought down and booted fresh.
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

    /// SIGKILLs the Steam client, or with `everything` the whole machine,
    /// games included, and brings it back with a fresh crash-loop budget.
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

    /// Trashes `steamapps/shadercache` with the bottle down and relaunches a
    /// wanted client. With a client wanted it is one ladder pass, cleared
    /// between stop and launch, so nothing starts a client over the cache.
    func clearShaderCache() {
        recentRestarts.removeAll()
        hygieneTried = false
        guard wantsClient, !isQuitting else {
            Task(name: "Clear the shader cache") {
                guard !isRestarting, !isQuitting else { return }
                await app.duringClientStop {
                    await ClientLifecycle.stopAll(gracePolls: 10, hidingPopups: true)
                }
                clearShaderCacheNow()
            }
            return
        }
        pendingShaderCacheClear = true
        Task(name: "Clear the shader cache") {
            await restartClient(reason: "clearing the shader cache", fullWindows: true)
        }
    }

    /// Clears the cache a ladder pass was asked to, with the bottle down.
    func clearShaderCacheNow() {
        pendingShaderCacheClear = false
        let cleared = ClientLifecycle.clearShaderCache()
        log.log(.supervisor, cleared ? "shader cache cleared" : "no shader cache to clear")
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
        // The library window goes first, or it freezes dimmed over the stop.
        await app.send(.dismissWindows)
        await app.duringClientStop {
            await ClientLifecycle.stopAll(gracePolls: 10, hidingPopups: true)
        }
        log.log(.supervisor, "client stopped (sevo)")
    }

    /// Whether the bottle is not ready for a client: setup holds it
    /// (``ProvisioningLease``), it has no `Steam.exe`, or the last setup pass
    /// stopped where nothing can start. The verdict names the reason; the log
    /// says it once per failure.
    func provisioningBlocksStart(reason: String) -> Bool {
        let provisioning = ProvisioningLease.onConfiguredBottle.map {
            "setup is still installing Steam in bottle \($0.name)"
        }
        let missingSteam = FileManager.default.fileExists(atPath: SteamBottle.exe.path)
            ? nil : "bottle \(SteamBottle.name) has no Steam.exe yet"
        guard let failure = provisioning ?? missingSteam ?? BottleReadiness.clientStartBlock else {
            reportedProvisioningBlock = nil
            return false
        }
        if reportedProvisioningBlock != failure {
            reportedProvisioningBlock = failure
            log.log(
                .supervisor,
                "not starting the client (\(reason)): the bottle is unfinished — \(failure)",
            )
        }
        fault = .degraded("the bottle is unfinished — \(failure)")
        refreshHealth()
        return true
    }

    /// `sevo client start`: resumes supervision, and restarts the client if
    /// it is not already up — the supervisor's ladder, not a bare launch.
    func startForControl() {
        setPaused(false, note: "auto-restart resumed (sevo client start)")
        // A fresh count, or a ladder that gave up gives up again at the first rung.
        recentRestarts.removeAll()
        hygieneTried = false
        if case .gaveUp = fault {
            fault = nil
            refreshHealth()
        }
        Task(name: "sevo client start") {
            if await ClientLifecycle.probeClient() != .up {
                await restartClient(reason: "sevo client start")
            }
        }
    }

    /// Quit teardown: stops wanting a client, then brings down the booted, the
    /// configured and every other Sevoflurane bottle with a wineserver up. The
    /// client's processes are launched detached and would outlive the session
    /// otherwise. Reached only from `/quit` and `SIGTERM`; the daemon stays up.
    func shutdownForQuit() async {
        guard !isQuitting else { return }
        isQuitting = true
        wantsClient = false
        endBoot()
        refreshHealth()
        log.log(.supervisor, "quit: bringing the bottle down")
        // Hides the client's "Shutting down Steam…" popup.
        await app.send(.dismissWindowsForQuit)
        let booted = BootedBottle.target
        let strays = await strayBottles(during: "quit", beside: booted)
        let targets = BottleTarget.stopSet(booted: booted, configured: .configured, strays: strays)
        await app.duringClientStop {
            await ClientLifecycle.stopAll(gracePolls: 8, targets: targets, hidingPopups: true)
        }
        // A ladder that was mid-flight sees the quit at its next guard and
        // launches nothing; once it has returned, one more pass takes down
        // whatever it had spawned before the guard.
        if isRestarting {
            await ladderFinished()
            await app.duringClientStop {
                await ClientLifecycle.stopAll(gracePolls: 4, targets: targets, hidingPopups: true)
            }
        }
        let survivors = await ClientLifecycle.bottleProcessIDs(in: targets)
        let reach = BottleTarget.scopeNote(targets, configured: .configured)
        log.log(
            .supervisor,
            survivors.isEmpty
                ? "quit: \(reach) down"
                : "quit: pids \(survivors) in \(reach) survived SIGKILL",
        )
        let left = await BottleIdentity.verify(configured: .configured)
        for stray in left.strays {
            log.log(.supervisor, "quit: bottle \(stray.name) still has a wineserver running")
        }
        // A switch the quit overtook lands now, with the old bottle down,
        // so the next start boots the engine that was asked for.
        applyPendingSwitch()
        // The next client is a fresh start, not a recovery.
        hasSeenClientUp = false
        hasBeenHealthy = false
        isQuitting = false
        refreshHealth()
    }
}
