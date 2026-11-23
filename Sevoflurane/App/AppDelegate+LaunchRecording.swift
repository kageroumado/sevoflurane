import AppKit

extension AppDelegate {
    // MARK: - What a launch records

    /// Wires the moments a launch reports: start, a process reaching the Mac
    /// driver, a window, a Steam error, and the game stopping.
    func installLaunchHooks() {
        host.onProgramLaunchPressed = { [weak self] appID in
            guard let self else { return }
            gameLaunchWatch.noteLaunchPressed()
            runRecorder.noteLaunchPressed(appID: appID)
        }
        host.onGameLaunchStart = { [weak self] appID in
            guard let self else { return }
            // Arms the window watch for launches the bridge did not carry (the
            // CLI's, a steam:// URL the client handled itself).
            gameLaunchWatch.noteLaunchRequested(appID: appID)
            // Every launch path passes here, so the activation right is taken
            // now: when the game's window arrives a minute later, no event is
            // left to attribute the request to.
            ActivationPolicy.claimRightForALaunch()
            // Opened here rather than at the first window: a game that dies
            // before it draws is the one worth recording.
            runRecorder.arm(appID: appID)
            Task.detached(name: "Put app \(appID) first in the Games folder") {
                GamesFolder.markPlayed(appID: appID)
            }
            // A launch the app did not carry through ``LaunchPreparation`` gets
            // its exes read and macOS symlinks made here, so its env files and
            // Dock bundle exist by its first window; its first-launch fixes
            // wait for a prepared launch.
            Task.detached(name: "Record app \(appID)'s executables") {
                // First, because Steam starts the process within moments: an
                // exe this game shares with another gets this game's lines.
                ConfigMaterializer.noteLaunch(of: appID, bottle: SteamBottle.name, prefix: SteamBottle.root)
                let linked = ReparseLinks.restoreInstalledMacOSVersion(appID: appID)
                if linked > 0 {
                    EventLog.enqueue(.client, "launch \(appID): made \(linked) symlinks of its macOS version real for macOS")
                }
                if GameExecutables.recordFromInstall(appID: appID) {
                    ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
                }
            }
        }
        // The attribution that survives a game which dies before it draws.
        gameLaunchWatch.onGameProcessArmed = { [weak self] exe, pid in
            guard let self, let appID = host.activeLaunch?.appID else { return }
            runRecorder.noteExecutable(exe, pid: pid, forApp: appID)
            record(exe, forApp: appID, detectingRuntime: false)
        }
        gameLaunchWatch.onGameWindowUp = { [weak self] owner in
            guard let self else { return }
            // Read before the host is told: ending the launch clears which app
            // it was.
            let launchedAppID = host.activeLaunch?.appID
            host.gameWindowDidAppear()
            supervisor.wake(.gameWindowChanged)
            // A first run is the first chance to read the game's files, which
            // decide the runners it can be offered.
            if let launchedAppID {
                runRecorder.noteWindowUp(forApp: launchedAppID)
                record(owner, forApp: launchedAppID, detectingRuntime: true)
                publishToDiscord(appID: launchedAppID)
            }
        }
        host.onGameActionError = { [weak self] appID, detail in
            self?.runRecorder.noteSteamError(detail, forApp: appID)
        }
        // The client's notification is the exit edge: a game Steam started is
        // not a process this app can wait on.
        host.onGameRunningChanged = { [weak self] appID, running in
            guard !running else {
                self?.runRecorder.noteRunning(appID: appID)
                return
            }
            self?.runRecorder.noteStopped(appID: appID)
        }
        // A run's close is the exit edge for every game, Quick Launch programs
        // included.
        runRecorder.onClose = { appID in
            DiscordPresence.shared.gameStopped(appID)
            Task.detached(name: "Clear the Discord activity") {
                await DiscordPresence.shared.clear(forGame: appID)
            }
        }
    }

    /// Samples every open run's meters on a timer: energy, retired instructions
    /// and the Game Mode session exist only while the game's process does.
    ///
    /// The same tick releases the display once no run is open, and wakes the
    /// daemon's probe cycle (a minute apart while a game is up) whenever a run
    /// closes.
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

    /// Meter ticks between display-hold reads: once a minute.
    private static let displayHoldCheckEvery = 30

    /// Gathers the engine's renderer lines from the Wine log while the game
    /// plays, since a long run's log outgrows what its close reads back. Reads
    /// run off the main actor.
    private static func readProvenance(_ recorder: RunRecorder) async {
        for read in recorder.provenanceReads {
            let found = await Task.detached(name: "Read the engine's renderer lines") {
                RunRecorder.provenance(in: read.log, from: read.offset)
            }.value
            recorder.noteProvenance(found.lines, readTo: found.end, for: read)
        }
    }

    /// A native NW.js game is a macOS process; on an engine whose shim execs
    /// NW.js in place (r12 and earlier) Steam sends no lifetime edge, so the
    /// run ends when its processes are gone. On a newer engine, whichever of
    /// Steam's edge and this check comes first closes the run.
    private static func checkNativeRuns(_ recorder: RunRecorder) async {
        for appID in recorder.nativeRuns {
            let alive = await Task.detached(name: "Look for the native game's processes") {
                let running = NWJSRunner.runningProcesses(appID: appID)
                return !running.browser.isEmpty || !running.helpers.isEmpty
            }.value
            recorder.noteNativeProcesses(alive: alive, forApp: appID)
        }
        // Steam never started a Quick Launch program either, so only its
        // process says it has ended.
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

    /// A program the helper saw draw nothing after its kernel driver failed to
    /// load, however it was started: the driver goes into the program's open
    /// run, and the panel says what happened. A run that has closed already
    /// read the driver from Wine's log at its close.
    func explainKernelDriverFailure(_ driver: String, programID: Int) {
        guard let record = runRecorder.noteKernelDriver(driver, forApp: programID) else { return }
        RunDiagnosisPrompt.shared.offer(record)
    }

    /// Watches every process the app owns and unwedges a game that has stopped
    /// doing anything. On at every level: the ladder turns a freeze into an
    /// ending the record can name.
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

    /// Logs the machine's state while a game runs, at the level that asks for
    /// it; the run record keeps only the state at the start.
    private nonisolated static func logHostState() {
        let host = HostSnapshot.take()
        EventLog.enqueue(
            .app,
            "host: thermal \(host.thermalState), load \(host.loadAverage1m), "
                + "\(host.activeProcessors) processors, \(host.freeMemoryMB) MB free, "
                + "\(host.compressedMemoryMB) MB compressed",
        )
    }

    /// Tells Discord which game is on screen, under the game's own Discord
    /// application when Discord's database names it (by Steam app id, then
    /// adopted executable, then name), otherwise under Sevoflurane's with the
    /// game's name and, for a Steam game, its Steam box art.
    ///
    /// A game that ships its own Discord library publishes through the
    /// in-bottle bridge and is left alone. The ticket is taken on the main
    /// actor, so a stop during the lookup voids the publish.
    private func publishToDiscord(appID: Int) {
        guard Preferences.discordPresence else { return }
        let configured = GameConfig.game(appID).name
        let executable = AdoptedPrograms.program(appID)?.path
        let ticket = DiscordPresence.shared.ticket(forGame: appID)
        Task.detached(name: "Publish app \(appID) to Discord") {
            guard let name = configured ?? SharedGames.installed(appID: appID)?.name else { return }
            guard !DiscordPresence.publishesItsOwn(appID: appID) else { return }
            let applications = DiscordApplications.shared
            var resolved = await applications.applicationID(steamAppID: appID)
            if resolved == nil, let executable {
                resolved = await applications.applicationID(executable: executable)
            }
            if resolved == nil { resolved = await applications.applicationID(named: name) }
            let activity: DiscordPresence.Activity
            if let application = resolved {
                activity = .init(applicationID: application.id, name: application.name)
            } else {
                let cover = appID < AdoptedPrograms.firstID ? await SteamArtwork.cover(appID: appID) : nil
                EventLog.enqueue(
                    .client,
                    "\(name) is not in Discord's game list, so it is published under Sevoflurane's application as itself"
                        + (cover.map { ", pictured by \($0.lastPathComponent)" } ?? ", without art"),
                )
                activity = .fallback(named: name, cover: cover)
            }
            try? await DiscordPresence.shared.show(activity, forGame: appID, ticket: ticket)
        }
    }

    /// Records the exe a launch of `appID` started, unless another game already
    /// claimed it. Detached: it reads configs and rewrites env files.
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
