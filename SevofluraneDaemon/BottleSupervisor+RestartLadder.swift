import Foundation
import os

extension BottleSupervisor {
    func restartClient(reason: String, fullWindows: Bool = false) async {
        guard wantsClient, !isQuitting else { return }
        // A held switch is judged by the bottle it moves to, once it has.
        if pendingSwitch == nil, provisioningBlocksStart(reason: reason) { return }
        if isRestarting {
            restartAgain = reason
            log.log(.supervisor, "restart requested mid-restart (\(reason)); the ladder runs again")
            return
        }
        isRestarting = true
        // The verdict moves to restarting before the first await, so a
        // caller polling for healthy never reads the client being replaced.
        refreshHealth()
        defer {
            isRestarting = false
            refreshHealth()
            let waiters = ladderWaiters
            ladderWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
        var reason = reason, fullWindows = fullWindows
        while true {
            await runRestartLadder(reason: reason, fullWindows: fullWindows)
            guard let again = restartAgain, wantsClient, !isQuitting else { return }
            restartAgain = nil
            reason = again
            fullWindows = false
        }
    }

    /// One pass of the ladder: stop what is up, launch under `Engine.active`
    /// as it is at launch time, wait for the client. A restart asked for on
    /// the way (`restartAgain`) ends the pass early, before the launch when
    /// it can, so the next pass decides afresh what has to come down.
    private func runRestartLadder(reason: String, fullWindows: Bool) async {
        let ladder = PerfProbe.supervisor.beginInterval("ClientRestart")
        defer { PerfProbe.supervisor.endInterval("ClientRestart", ladder) }
        let watchdog = Task(name: "Restart ladder watchdog") { [weak self] in
            try? await Task.sleep(for: LadderWatchdog.budget)
            guard !Task.isCancelled, let self else { return }
            await freeStalledPass()
            try? await Task.sleep(for: LadderWatchdog.budget)
            guard !Task.isCancelled else { return }
            reportStalledPass()
        }
        defer { watchdog.cancel() }

        recentRestarts.removeAll { $0.timeIntervalSinceNow < -600 }
        guard recentRestarts.count < 3 else {
            // The repair runs for minutes under its own timeout; the ladder's
            // watchdog would force-quit the updater it is waiting on.
            watchdog.cancel()
            await escalateCrashLoop()
            return
        }
        let stamp = Date.now
        recentRestarts.append(stamp)
        pendingRestart = stamp
        clientFailures = 0
        clientShowsLoginWindow = false
        // A fresh try clears the last verdict, a crash loop included.
        fault = nil
        log.log(.supervisor, "\(hasBeenHealthy ? "restarting" : "starting") client: \(reason)")

        // Otherwise a dimmed, frozen library stays up through the teardown.
        await app.send(.dismissWindows)

        setRestartPhase("checking for a running client")
        adoptEngineInstalledSinceStart()
        adoptBottleChosenSinceBoot()
        let booted = BootedBottle.target
        let strays = await strayBottles(during: "restart", beside: booted)
        let targets = BottleTarget.stopSet(booted: booted, configured: .configured, strays: strays)
        // Windows stays booted (its ~20 s boot is most of a restart) unless the
        // next launch needs another wineserver: another engine, bottle, or sync
        // mode (esync/msync are negotiated with the server at spawn).
        let windowsCanStay = !fullWindows && pendingSwitch == nil && !pendingShaderCacheClear
            && strays.isEmpty
            && BottleIdentity.windowsCanStay(
                booted: BottleIdentity.Boot(
                    engineRoot: BottleGraphics.bootedEngineRoot(),
                    msync: BottleGraphics.bootedSelection()?.msync,
                    bottle: booted?.path,
                ),
                current: BottleIdentity.Boot(
                    engineRoot: Engine.active.root.path,
                    msync: BottleGraphics.currentSelection().msync,
                    bottle: BottleTarget.configured.path,
                ),
            )
        if windowsCanStay {
            await ClientLifecycle.stopClient(gracePolls: 10, targets: targets) { phase in
                setRestartPhase(phase)
            }
        } else {
            await app.duringClientStop {
                await ClientLifecycle.stopAll(gracePolls: 10, targets: targets, hidingPopups: true) { phase in
                    setRestartPhase(phase)
                }
            }
        }

        await launchAfterStop(reason: reason, targets: targets)
    }

    /// Picks up an engine the app installed after this process resolved
    /// ``Engine/active``, through the held switch so the stop still addresses
    /// the running engine.
    func adoptEngineInstalledSinceStart() {
        guard pendingSwitch == nil else { return }
        let fresh = Engine.resolveFromDisk()
        guard fresh != Engine.active else { return }
        pendingSwitch = EngineSwitch(engine: fresh, bottle: nil, persists: false)
        log.log(.supervisor, "engine resolves to \(fresh.description) now, where it was \(Engine.active.description); the restart switches to it")
    }

    /// Logs a bottle choice written under a live client; the pass stops the
    /// booted bottle and launches in the configured one. Answers whether the
    /// bottle moved.
    @discardableResult
    func adoptBottleChosenSinceBoot() -> Bool {
        let configured = BottleTarget.configured
        guard let booted = BootedBottle.target,
              BottleIdentity.bottleMoved(booted: booted.path, configured: configured.path)
        else { return false }
        log.log(.supervisor, "bottle is \(configured.name) now, where the client booted in \(booted.name); the restart stops \(booted.name) and launches in \(configured.name)")
        return true
    }

    /// The launch that ends a pass, once its stop has run. It launches only
    /// when no `steam.exe` is left in any bottle the stop reached, with a
    /// client still wanted and no newer restart asked for, and applies a held
    /// engine switch first.
    private func launchAfterStop(
        reason: String, targets: [BottleTarget] = BottleTarget.inScope,
    ) async {
        // Never launch over a surviving steam.exe: a timed-out launcher can
        // still spawn a client. This guard and `isRestarting` are the
        // double-start defense (`-nocrashdialog` removes Steam's own watchdog).
        let leftovers = await ClientLifecycle.bottleProcessIDs(matching: "steam.exe", in: targets)
        guard leftovers.isEmpty else {
            fault = .degraded("a steam.exe survived kill -9 — not launching a second client")
            transition(
                logging: .client,
                "steam.exe pids \(leftovers) survived SIGKILL — manual intervention needed",
            )
            return
        }
        if pendingShaderCacheClear { clearShaderCacheNow() }
        // A quit that began during the stop wins.
        guard wantsClient, !isQuitting else { return }
        // The engine may have changed under this pass; the next one settles
        // what has to come down for it before anything is launched.
        guard restartAgain == nil else { return }
        applyPendingSwitch()
        // Judged again at the launch: setup can have taken the bottle while
        // the stop ran, and a held switch is judged by the bottle it moved to.
        if provisioningBlocksStart(reason: reason) { return }

        setRestartPhase("launching the client")
        log.log(.client, "launching the bottle client with CDP on :\(BridgePorts.cdp)")
        clientStartedAt = .now
        await ClientLifecycle.launchClient()
        // The ladder ends at the spawn; the probe cycle owns the boot from here.
        enterBoot(.awaitingClient)
    }

    enum LadderWatchdog {
        /// How long one pass may take before it counts as stalled: every rung
        /// is bounded, so a pass past this waits on something the old client holds.
        static let budget: Duration = .seconds(120)
    }

    /// Frees a stalled pass by SIGKILLing the client's processes, which
    /// returns every wait on them.
    private func freeStalledPass() async {
        let phase = restartPhase
        log.log(
            .supervisor,
            "restart ladder stalled at \"\(phase)\" for \(LadderWatchdog.budget.components.seconds)s "
                + "— force-quitting the client to free it",
        )
        setRestartPhase("stalled at \(phase) — force-quitting the client")
        let killed = await ClientLifecycle.forceQuit(.steam)
        log.log(.client, "stalled ladder: SIGKILL'd \(killed.count) Steam process(es) \(killed)")
    }

    /// A pass still running a budget after the force-quit is waiting on
    /// something that is not the client; the log and the phase say so, and
    /// the pass is left to return on its own.
    private func reportStalledPass() {
        log.log(
            .supervisor,
            "restart ladder still stalled at \"\(restartPhase)\" after the force-quit — "
                + "sample the helper (sevo diag) and relaunch Sevoflurane",
        )
        setRestartPhase("stalled — relaunch Sevoflurane")
    }

    /// Returns once no ladder is running. Quit waits here, so a ladder that
    /// was mid-stop when the quit arrived has returned before the quit
    /// declares the bottle down.
    func ladderFinished() async {
        guard isRestarting else { return }
        await withCheckedContinuation { ladderWaiters.append($0) }
    }

    /// The rung the ladder is on, as the menu bar and the footer show it.
    private func setRestartPhase(_ phase: String) {
        restartPhase = phase
        refreshHealth()
    }

    /// Three restarts in ten minutes is a crash loop: one hygiene pass
    /// (htmlcache purge, headless client repair), then `gaveUp`.
    private func escalateCrashLoop() async {
        let hygiene = PerfProbe.supervisor.beginInterval("CrashLoopHygiene")
        defer { PerfProbe.supervisor.endInterval("CrashLoopHygiene", hygiene) }
        let dumps = ClientLifecycle.recentDumpCount()
        guard !hygieneTried else {
            fault = .gaveUp("client keeps dying — likely crash-looping; see the log")
            transition(
                logging: .supervisor,
                "giving up: still crash-looping after the hygiene pass "
                    + "(\(dumps) fresh dumps in 10 min) — manual repair needed",
            )
            return
        }
        hygieneTried = true
        log.log(
            .supervisor,
            "3 restarts in 10 minutes (\(dumps) fresh dumps) — crash loop; "
                + "running the hygiene pass: htmlcache purge + headless client repair",
        )
        setRestartPhase("crash loop: stopping the client")
        await app.duringClientStop {
            await ClientLifecycle.stopAll(gracePolls: 10) { phase in
                setRestartPhase(phase)
            }
        }
        guard wantsClient, !isQuitting else { return }
        if ClientLifecycle.purgeHTMLCache() {
            log.log(.client, "trashed the bottle's htmlcache")
        }
        setRestartPhase("crash loop: repairing the client (takes minutes)")
        let updated = await ClientLifecycle.headlessUpdate()
        log.log(
            .client,
            updated ? "headless client repair finished"
                : "headless client repair did not exit cleanly",
        )
        if !updated {
            // An updater that timed out may have left a client of its own
            // running in the bottle; the relaunch starts from an empty one.
            await app.duringClientStop {
                await ClientLifecycle.stopAll(gracePolls: 10) { phase in
                    setRestartPhase(phase)
                }
            }
        }
        await launchAfterStop(reason: "crash-loop relaunch")
    }
}
