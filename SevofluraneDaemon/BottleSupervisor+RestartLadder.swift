import Foundation
import os

extension BottleSupervisor {
    func restartClient(reason: String, fullWindows: Bool = false) async {
        guard wantsClient else { return }
        guard !isQuitting, !provisioningBlocksStart(reason: reason) else { return }
        if isRestarting {
            restartAgain = reason
            log.log(.supervisor, "restart requested mid-restart (\(reason)); the ladder runs again")
            return
        }
        isRestarting = true
        defer {
            isRestarting = false
            refreshHealth()
        }
        var reason = reason, fullWindows = fullWindows
        while true {
            await runRestartLadder(reason: reason, fullWindows: fullWindows)
            guard let again = restartAgain, !isQuitting else { return }
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

        recentRestarts.removeAll { $0.timeIntervalSinceNow < -600 }
        guard recentRestarts.count < 3 else {
            await escalateCrashLoop()
            return
        }
        let stamp = Date.now
        recentRestarts.append(stamp)
        pendingRestart = stamp
        clientFailures = 0
        clientShowsLoginWindow = false
        // A pass that will launch is a fresh try, so the last one's verdict —
        // a crash loop included — stops being the state to report.
        fault = nil
        log.log(.supervisor, "\(hasSeenClientUp ? "restarting" : "starting") client: \(reason)")

        // Take the dead client's frozen windows off screen now, rather than
        // leaving a dimmed, unresponsive library up for the whole teardown.
        await app.send(.dismissWindows)

        setRestartPhase("checking for a running client")
        // Windows stays booted through a plain client restart — the ~20s
        // machine boot is the biggest slice of a restart, and the resident
        // wineserver only has to go when the next launch actually needs a
        // different one: another engine's, or new sync primitives (esync/
        // msync are negotiated with the server at spawn).
        let windowsCanStay = !fullWindows
            && BottleGraphics.bootedEngineRoot() == Engine.active.root.path
            && BottleGraphics.bootedSelection()?.msync
            == BottleGraphics.currentSelection().msync
        if windowsCanStay {
            await ClientLifecycle.stopClient(gracePolls: 10) { phase in
                setRestartPhase(phase)
            }
        } else {
            await app.duringClientStop {
                await ClientLifecycle.stopAll(gracePolls: 10, hidingPopups: true) { phase in
                    setRestartPhase(phase)
                }
            }
        }

        // The launcher can time out and *still* spawn a client later; a
        // steam.exe that survived everything above means launching now could
        // stack a second instance on top of it. This guard plus
        // `isRestarting` is the entire double-start defense: restart
        // generation tags were considered and dropped because
        // `-nocrashdialog` removed Steam's own watchdog — the only other
        // writer that could race a relaunch. If a double-start ever appears
        // in the log again, tags are the next step.
        let leftovers = await ClientLifecycle.bottleProcessIDs(matching: "steam.exe")
        guard leftovers.isEmpty else {
            fault = .degraded("a steam.exe survived kill -9 — not launching a second client")
            transition(
                logging: .client,
                "steam.exe pids \(leftovers) survived SIGKILL — manual intervention needed",
            )
            return
        }
        guard !isQuitting else { return }
        // The engine may have changed under this pass; the next one settles
        // what has to come down for it before anything is launched.
        guard restartAgain == nil else { return }

        setRestartPhase("launching the client")
        log.log(.client, "launching the bottle client with CDP on :\(BridgePorts.cdp)")
        clientStartedAt = .now
        await ClientLifecycle.launchClient()
        // The ladder's work ends with the spawn. Everything the client does
        // next — CDP arriving, its services, its sign-in window, the page
        // booting — is a state of the probe cycle, which has the guards and
        // the cadence for it.
        enterBoot(.awaitingClient)
    }

    /// The rung the ladder is on, as the menu bar and the footer show it.
    private func setRestartPhase(_ phase: String) {
        restartPhase = phase
        refreshHealth()
    }

    /// Three restarts in ten minutes is the crash-loop signature; another
    /// plain restart would only stack crash dumps. The proven response is one
    /// hygiene pass — trash the Chromium cache, headless client repair — and
    /// a crash loop that survives *that* gets `gaveUp`: the machine needs a
    /// human.
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
        guard !isQuitting else { return }
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
        guard !isQuitting else { return }
        setRestartPhase("launching the client")
        clientStartedAt = .now
        await ClientLifecycle.launchClient()
        enterBoot(.awaitingClient)
    }
}
