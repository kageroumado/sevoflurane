import AppKit

extension AppDelegate {
    // MARK: - What a launch records

    /// The moments a launch tells the app something: it began, one of its
    /// processes reached the Mac driver, one of them put up a window, Steam
    /// raised an error for it, and the game stopped running.
    func installLaunchHooks() {
        host.onProgramLaunchPressed = { [weak self] appID in
            guard let self else { return }
            gameLaunchWatch.noteLaunchPressed()
            runRecorder.noteLaunchPressed(appID: appID)
        }
        host.onGameLaunchStart = { [weak self] appID in
            guard let self else { return }
            // Arms the window watch for launches the bridge did not carry
            // (the CLI's, a steam:// URL the client handled itself).
            gameLaunchWatch.noteLaunchRequested(appID: appID)
            // Every launch path passes through here, so this is where the app
            // takes the activation right it will spend on the game's window.
            // A minute later, when that window finally arrives, there is no
            // event left for the window server to attribute the request to.
            ActivationPolicy.claimRightForALaunch()
            // The run record opens here rather than at the first window:
            // a game that dies before it draws is the one worth recording.
            runRecorder.arm(appID: appID)
            // A launch the app carries was prepared before it reached Steam
            // or the helper (``LaunchPreparation``). One it did not carry
            // gets its exes read here, so its env files, and the bundle that
            // names it in the Dock, are there by its first window at the
            // latest; its first-launch fixes wait for a launch that is
            // prepared before it starts.
            Task.detached(name: "Record app \(appID)'s executables") {
                if GameExecutables.recordFromInstall(appID: appID) {
                    ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
                }
            }
        }
        // A process of the launch loaded winemac.drv. This is the attribution
        // that survives a game which dies before it draws.
        gameLaunchWatch.onGameProcessArmed = { [weak self] exe, pid in
            guard let self, let appID = host.activeLaunch?.appID else { return }
            runRecorder.noteExecutable(exe, pid: pid, forApp: appID)
            record(exe, forApp: appID, detectingRuntime: false)
        }
        gameLaunchWatch.onGameWindowUp = { [weak self] owner in
            guard let self else { return }
            // Read before the host is told: the window's arrival is what ends
            // the launch, and ending it clears the record of which app it was.
            let launchedAppID = host.activeLaunch?.appID
            host.gameWindowDidAppear()
            supervisor.wake(.gameWindowChanged)
            // A game that has just run for the first time is also the first
            // chance to read its files: what it is built on decides which
            // runners it can be offered.
            if let launchedAppID {
                runRecorder.noteWindowUp(forApp: launchedAppID)
                record(owner, forApp: launchedAppID, detectingRuntime: true)
                publishToDiscord(appID: launchedAppID)
            }
        }
        host.onGameActionError = { [weak self] appID, detail in
            self?.runRecorder.noteSteamError(detail, forApp: appID)
        }
        // The client's own notification is the exit edge: a game Steam started
        // is not a process this app can wait on.
        host.onGameRunningChanged = { [weak self] appID, running in
            guard !running else {
                self?.runRecorder.noteRunning(appID: appID)
                return
            }
            self?.runRecorder.noteStopped(appID: appID)
        }
        // A run's close is the exit edge for every game, a Quick Launch
        // program's too, so the Discord activity goes with it.
        runRecorder.onClose = { appID in
            DiscordPresence.shared.gameStopped(appID)
            Task.detached(name: "Clear the Discord activity") {
                await DiscordPresence.shared.clear(forGame: appID)
            }
        }
    }

    /// Reads every open run's meters on a timer. Energy, retired instructions
    /// and the Game Mode session exist only while the game's process does, so
    /// they are sampled during the run rather than read at its close.
    ///
    /// The same tick lets the display sleep again once no run is open: every
    /// way a run closes — Steam's exit edge, a native runner's processes
    /// going, the stall watch ending a game — passes through the recorder.
    /// The daemon holds the display too, and lets it go when its probe cycle
    /// finds the game window gone; that cycle is a minute apart while a game
    /// is up, so every run closing wakes it, one followed at once by the next
    /// game's launch included.
    func startRunMeter() {
        runMeter?.cancel()
        runMeter = Task(name: "Sample the open runs' meters") { [runRecorder, weak self] in
            var ticks = 0
            var holdWatch = DisplayHoldWatch()
            var closedRuns = runRecorder.closedRuns
            while !Task.isCancelled {
                try? await Task.sleep(for: RunRecorder.meterInterval)
                runRecorder.sample { GameScreen.observe(pid: $0) }
                if !runRecorder.isRecording { GameDisplayHold.gameDidExit() }
                if runRecorder.closedRuns != closedRuns {
                    closedRuns = runRecorder.closedRuns
                    self?.supervisor.wake(.gameWindowChanged)
                }
                ticks += 1
                if ticks.isMultiple(of: Self.displayHoldCheckEvery) {
                    let holds = await Task.detached(name: "Read the display holds") { DisplayHolds.current() }.value
                    for hold in holdWatch.check(holds, runOpen: runRecorder.isRecording) {
                        EventLog.shared.log(
                            .app, "display: held with no game running — \(DisplayHolds.describe(hold))",
                        )
                    }
                }
                if ticks.isMultiple(of: RunRecorder.nativeCheckEvery) {
                    await Self.checkNativeRuns(runRecorder)
                }
                if ticks.isMultiple(of: RunRecorder.provenanceCheckEvery) {
                    await Self.readProvenance(runRecorder)
                }
                guard runRecorder.isRecording,
                      let every = DiagnosticLevel.current.hostSampleInterval else { continue }
                let period = max(1, Int(every / RunRecorder.meterInterval))
                if ticks.isMultiple(of: period) { Self.logHostState() }
            }
        }
    }

    /// Every how many meter ticks the display holds are read: once a minute.
    private static let displayHoldCheckEvery = 30

    /// The engine names the renderer that answered in the Wine log during the
    /// run, and a long run's log outgrows what its close reads back, so the
    /// line is gathered while the game plays. The reads run off the main actor.
    private static func readProvenance(_ recorder: RunRecorder) async {
        for read in recorder.provenanceReads {
            let found = await Task.detached(name: "Read the engine's renderer lines") {
                RunRecorder.provenance(in: read.log, from: read.offset)
            }.value
            recorder.noteProvenance(found.lines, readTo: found.end, for: read)
        }
    }

    /// A game on the native NW.js runner is a macOS process Steam does not
    /// track, and the client sends no lifetime edge for it: the run ends when
    /// its processes are gone. `ps` runs off the main actor.
    private static func checkNativeRuns(_ recorder: RunRecorder) async {
        for appID in recorder.nativeRuns {
            let alive = await Task.detached(name: "Look for the native game's processes") {
                let running = NWJSRunner.runningProcesses(appID: appID)
                return !running.browser.isEmpty || !running.helpers.isEmpty
            }.value
            recorder.noteNativeProcesses(alive: alive, forApp: appID)
        }
        // A Quick Launch program is the same case in a Wine process: Steam
        // never started it, so nothing but its process says it has ended.
        let programs = recorder.programRuns.compactMap { appID in
            AdoptedPrograms.program(appID).map { (appID, $0.url.lastPathComponent) }
        }
        guard !programs.isEmpty else { return }
        let listing = await Subprocess.run("/usr/bin/pgrep", WineProcessList.pgrepArguments).output
        for (appID, exe) in programs {
            recorder.noteNativeProcesses(
                alive: !WineProcessList.pids(named: exe, inPgrepLong: listing).isEmpty,
                forApp: appID, gone: nil, neverSeenChecks: RunRecorder.programNeverSeenChecks,
            )
        }
    }

    /// Watches every process the app owns and unwedges a game that has stopped
    /// doing anything. It is on at every level: a killed game is a session
    /// lost either way, and the ladder is what turns a freeze into an ending
    /// the record can name.
    func startStallWatch() {
        stallWatch.recorder = runRecorder
        stallWatch.onNotAnswering = { [stallWatch] process in
            // After the sample that found it: a modal alert must not run inside the pass.
            ModalAlerts.present {
                if NotAnsweringPrompt.userEnds(process.name) { stallWatch.end(process) }
            }
        }
        stallWatch.onGameProcessGone = { [bridge] appID in
            let gameID = AdoptedPrograms.program(appID)?.steamShortcutID
                .map(SteamShortcuts.gameID(shortcutID:)) ?? String(appID)
            Task(name: "End Steam's entry for \(appID)") {
                if await !bridge.terminateApp(gameID: gameID) {
                    EventLog.enqueue(.client, "could not ask the client to end \(appID): the bridge is down")
                }
            }
        }
        stallWatch.start()
    }

    /// The machine while a game runs, at the level that asks for it. It goes
    /// to the event log rather than into the run record: one line per ten
    /// seconds is a trail, and the record holds the state at the start.
    private nonisolated static func logHostState() {
        let host = HostSnapshot.take()
        EventLog.enqueue(
            .app,
            "host: thermal \(host.thermalState), load \(host.loadAverage1m), "
                + "\(host.activeProcessors) processors, \(host.freeMemoryMB) MB free, "
                + "\(host.compressedMemoryMB) MB compressed",
        )
    }

    /// Tells Discord which game is on screen, under that game's own Discord
    /// application: a game Discord's database names shows the way its native
    /// build would, and one it does not name shows nothing.
    ///
    /// Detached, because the name comes off disk and the socket is the Discord
    /// client's to answer at its own pace. A game that ships its own Discord
    /// library publishes a richer activity through the in-bottle bridge, so the
    /// app leaves that one alone. The ticket is taken here on the main actor,
    /// so a stop that lands during the lookup voids the publish.
    private func publishToDiscord(appID: Int) {
        guard Preferences.discordPresence else { return }
        let configured = GameConfig.game(appID).name
        let ticket = DiscordPresence.shared.ticket(forGame: appID)
        Task.detached(name: "Publish app \(appID) to Discord") {
            guard let name = configured ?? SharedGames.installed(appID: appID)?.name else { return }
            guard !DiscordPresence.publishesItsOwn(appID: appID) else { return }
            let applications = DiscordApplications.shared
            var resolved = await applications.applicationID(steamAppID: appID)
            if resolved == nil { resolved = await applications.applicationID(named: name) }
            guard let application = resolved else {
                EventLog.enqueue(.client, "\(name) is not in Discord's game list, so nothing is published")
                return
            }
            let activity = DiscordPresence.Activity(
                applicationID: application.id, name: application.name,
            )
            try? await DiscordPresence.shared.show(activity, forGame: appID, ticket: ticket)
        }
    }

    /// Records the exe a launch of `appID` started, unless another game has
    /// already claimed that exe — a window or a process another game owns is
    /// that game's, whatever launch is in flight.
    ///
    /// Detached, because reading the game configs and a game's directory and
    /// rewriting the env files is disk work and this is the main actor.
    private func record(_ exe: String, forApp appID: Int, detectingRuntime: Bool) {
        guard appID != 0 else { return }
        Task.detached(name: "Record app \(appID)'s \(exe)") {
            guard GameConfig.app(claiming: exe).map({ $0 == appID }) ?? true else { return }
            let known = GameConfig.game(appID).exes?.contains(exe) ?? false
            guard !known || detectingRuntime else { return }
            GameConfig.noteExecutable(exe, forApp: appID)
            if detectingRuntime { NWJSGames.record(appID: appID) }
            ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        }
    }
}
