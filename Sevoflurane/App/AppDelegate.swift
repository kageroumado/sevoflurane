import AppKit
import os
import SwiftUI

/// Application-level wiring: the menu bar, the menu-bar item, the activation
/// policy, and the single ``SteamWebHost`` everything else reads. Created and
/// installed by `main.swift`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = SteamWebHost()
    let bridge = SteamBridge()
    let provisioner = Provisioner()
    lazy var supervisor = ClientSupervisor(host: host, bridge: bridge)
    let notifications = SteamNotifications()
    private let gameLaunchWatch = GameLaunchWatch()
    private let runRecorder = RunRecorder()
    private let stallWatch = StallWatch()
    private var runMeter: Task<Void, Never>?
    private lazy var appLinkServer = AppLinkServer(
        supervisor: supervisor, host: host, bridge: bridge,
    )
    private var menuMirror: SteamMenuMirror?
    private var menuBarPopover: MenuBarPopover?
    private var setupWindow: NSWindow?
    private lazy var aboutWindows = AboutWindows()
    private lazy var reportWindows = ReportWindows()
    private lazy var processMonitorWindows = ProcessMonitorWindows(watch: stallWatch)
    private lazy var liveSettingsWindow: SettingsWindow = {
        let window = SettingsWindow(
            provisioner: provisioner, supervisor: supervisor, host: host,
        )
        window.showReports = { [weak self] in self?.reportWindows.show() }
        return window
    }()

    /// The settings window the gear and ⌘, open. A demo boot points this at
    /// one built on simulated stores instead.
    private var settingsWindow: SettingsWindow {
        #if DEBUG
            demoSettingsWindow ?? liveSettingsWindow
        #else
            liveSettingsWindow
        #endif
    }

    // Launches that do something other than run the app: the
    // helper-unregistering pass a worktree build ends with. Answers whether
    // one of them took the launch.
    #if DEBUG
        private func handledDebugLaunch() -> Bool {
            // Leaves the machine as a test run found it: a build run from a
            // worktree registers its own background helper, and a stale
            // registration would start that build's daemon at the next login
            // and give it the control port. `SMAppService` can only
            // unregister from the bundle that registered, so the trigger has
            // to live here. `open` strips the environment, so run the
            // executable inside the bundle directly.
            if ProcessInfo.processInfo.environment["SEVO_UNREGISTER_HELPER"] == "1" {
                isSimulatedBoot = true
                Task(name: "Unregister the background helper") {
                    await DaemonService.unregister()
                    print("unregistered \(SupervisorLink.launchAgentPlistName)")
                    NSApp.terminate(nil)
                }
                return true
            }
            return false
        }
    #endif

    /// Points the shared, process-agnostic code at this process's answers:
    /// where its lines go, and the one live connection to the client. The
    /// daemon installs its own set — the same seams, different answers.
    private func installSharedHooks() {
        ClientLifecycle.log = { EventLog.enqueue(.client, $0) }
        GameConfig.logChange = { EventLog.enqueue(.app, $0) }
        ClientLifecycle.hidePopupsOverBridge = { [bridge, host] scope in
            let sparing = await MainActor.run { host.launchPopupSparing }
            return await bridge.hideVisibleClientPopups(scope, sparing: sparing) ?? []
        }
        ClientLifecycle.servicesReadyOverBridge = { [bridge] in
            await bridge.clientServicesReady()
        }
        SetupLog.log = { EventLog.enqueue(.setup, $0) }
        NWJSRunner.log = { EventLog.enqueue(.client, $0) }
        GameLaunchers.log = { EventLog.enqueue(.client, $0) }
        GameExecutables.log = { EventLog.enqueue(.client, $0) }
        RunRecorder.log = { EventLog.enqueue(.client, $0) }
        Diagnostics.faceReport = { await Diagnostics.appFaceReport() }
        CrashPrompt.shared.install()
        RunRecorder.didRecord = Self.collectReports
    }

    /// What a finished run leaves on disk beyond its record: a report at level
    /// zero when it ended badly, after every run above that, with a doctor
    /// pass and compression at level two.
    ///
    /// Runs on the recorder's closing queue, which is where the record was
    /// just written and the Wine log just read.
    private nonisolated static func collectReports(_ record: RunRecord, wineTail: String) {
        let level = DiagnosticLevel.current
        let report = CrashCollector.collectIfWanted(
            for: record, wineTail: wineTail, level: level,
        ) { report in
            guard level == .two else { return }
            _ = CrashCollector.addDoctorReport(to: report)
        }
        if let report {
            EventLog.enqueue(
                .client,
                "collected \(report.manifest.sources.count) sources into "
                    + "\(report.directory.lastPathComponent)",
            )
        }
        // Level two is set to catch one crash; leaving it on is a gigabyte of
        // logs nobody asked for.
        if DiagnosticLevel.expireAfterRun() {
            EventLog.enqueue(.app, "diagnostics back to \(DiagnosticLevel.current.summary)")
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // The unit tests link against this binary, so running them launches
        // the app. Anything started here would boot the bottle, take the ports
        // off a copy the user is running, and stage into their Steam install —
        // from a test that only wanted to call a function. Before everything,
        // so a test run leaves nothing at all behind it.
        if TestHost.isHosting { return }
        #if DEBUG
            if handledDebugLaunch() { return }
        #endif
        // First, so a throw during the rest of startup is still recorded.
        ExceptionWatch.install()
        installSharedHooks()
        // Before anything can start a bottle process, so the client this
        // launch brings up is not the killed session's verbose one.
        DebugModeSwitch.shared.clearStaleFile()
        applyEngineManifestOverride()
        PerfProbe.poi.emitEvent("Launch")
        installLaunchHooks()
        // A game outlives the app that launched it, so a launch armed by a
        // process that was force-quit is picked up here: one Steam is still
        // running stays open under this recorder, one it has finished with is
        // recorded now.
        runRecorder.reattach()
        startRunMeter()
        startStallWatch()
        installMenuBar()
        #if DEBUG
            if bootedOnFixtures() { return }
        #endif
        // A person opened the app — the Dock, the Finder, `open` — rather
        // than the system opening it as a login item or to handle a file.
        // The window is what they came for, so it comes up as soon as the
        // client is healthy; a login-item launch stays a menu-bar app.
        if note.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true {
            EventLog.shared.log(.window, "opened by hand — Steam's window follows the client up")
            supervisor.showLibraryWhenHealthy()
        }
        startServices()
    }

    /// Points the engine manifest at the URL a developer named, from the
    /// environment or from the defaults key.
    ///
    /// An override manifest is trusted unsigned, and so are the tarballs it
    /// names. A release build takes only a `file://` one — a test rig on this
    /// Mac — so a defaults write alone cannot point it at a remote engine.
    private func applyEngineManifestOverride() {
        // The defaults key exists because `open` (the only launch path that
        // gets a real Aqua session) strips the environment.
        guard let manifest = ProcessInfo.processInfo.environment["SEVO_ENGINE_MANIFEST"]
            ?? Preferences.shared.string(forKey: "engineManifestOverride"),
            let url = URL(string: manifest) else { return }
        #if !DEBUG
            guard url.isFileURL else {
                EventLog.enqueue(.setup, "engine manifest override ignored: \(manifest) is not a file:// URL")
                return
            }
        #endif
        EngineManifest.overrideURL = url
        EventLog.enqueue(.setup, "engine manifest override: \(manifest)")
    }

    /// The app's own menus, its notifications, and the menu bar popover.
    private func installMenuBar() {
        let mirror = SteamMenuMirror(host: host)
        menuMirror = mirror
        host.menuMirror = mirror
        SevofluraneMainMenu.install(mirror: mirror)
        // Before the gallery and dry-run gates return: setting the delegate
        // is what lets a click on a notification that woke the app be
        // delivered at all, and reading the permission raises no prompt.
        notifications.host = host
        host.notifications = notifications
        notifications.start()
        menuBarPopover = MenuBarPopover(
            host: host, supervisor: supervisor, notifications: notifications,
        )
    }

    #if DEBUG
        /// Whether this launch asked for the gallery or the demo, both of
        /// which run on fixtures and start nothing else.
        private func bootedOnFixtures() -> Bool {
            if GalleryWindow.wasRequestedAtLaunch {
                // Nothing else starts: the gallery is fixtures all the way
                // down, and a client coming up behind it would only compete
                // for the ports.
                isSimulatedBoot = true
                galleryWindow.show()
                return true
            }
            if DemoMode.isOn {
                // No control server (a live instance may own the port), no
                // bridge, no client — nothing on the machine moves, and the
                // assistant and every Settings pane run against fixtures.
                isSimulatedBoot = true
                EventLog.shared.log(
                    .setup,
                    "demo: booted on '\(DemoMode.setup.rawValue)' — "
                        + "nothing on this Mac will be touched",
                )
                startDemo()
                if CrashPrompt.wasRequestedAtLaunch { CrashPrompt.shared.offerFixture() }
                return true
            }
            return false
        }
    #endif

    /// Takes the daemon link port, stocks the shader store, and then either
    /// walks the user through setup or brings the client up.
    private func startServices() {
        // Up before provisioning gates so the daemon can reach the page even
        // while the setup wizard is waiting for the user.
        Task(name: "Take the daemon link port") {
            guard await self.appLinkServer.start() else {
                self.reportAnotherCopyIsRunning()
                return
            }
        }
        // The bundle's shader packages are in the store before any game
        // could be launched naming one. Detached: it copies files.
        Task.detached(name: "Copy bundled shader packages") {
            ShaderPackages.ensureBundled()
        }
        Task {
            await provisioner.refreshDetection()
            if let detection = provisioner.detection {
                Engine.active = Engine.resolve(from: detection)
            }
            if provisioner.needsSetup {
                showSetupWizard(provisioner: provisioner) { [weak self] in
                    self?.closeSetupWindow()
                    self?.finishOnboarding()
                }
            } else {
                startRunning()
                Self.installBundledEngineIfNewer()
            }
        }
    }

    /// An app update that carries a newer engine installs it, off the main actor. The newest
    /// managed engine is the active one unless the user chose another, so it takes over at
    /// the client's next start.
    private static func installBundledEngineIfNewer() {
        Task.detached(name: "Install the engine this app carries") {
            guard let bundled = EngineInstaller.bundledUpgrade(installed: SetupProbe.managedEngineVersions())
            else { return }
            EventLog.enqueue(.setup, "engine: installing \(bundled.lastPathComponent), which this app carries")
            do {
                let version = try await EngineInstaller.install(from: bundled, requiringSignature: true)
                EventLog.enqueue(.setup, "engine: \(version) installed from the app; it runs from the client's next start")
            } catch {
                EventLog.enqueue(.setup, "engine: the engine this app carries did not install — \(error)")
            }
        }
    }

    // MARK: - What a launch records

    /// The moments a launch tells the app something: it began, one of its
    /// processes reached the Mac driver, one of them put up a window, Steam
    /// raised an error for it, and the game stopped running.
    private func installLaunchHooks() {
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
            // The game's exes, read from its install directory now, so its
            // env files — and the bundle that names it in the Dock — exist
            // before the process starts rather than after its first window.
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
    private func startRunMeter() {
        runMeter?.cancel()
        runMeter = Task(name: "Sample the open runs' meters") { [runRecorder] in
            var ticks = 0
            var holdWatch = DisplayHoldWatch()
            while !Task.isCancelled {
                try? await Task.sleep(for: RunRecorder.meterInterval)
                runRecorder.sample()
                if !runRecorder.isRecording { GameDisplayHold.gameDidExit() }
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
                guard runRecorder.isRecording,
                      let every = DiagnosticLevel.current.hostSampleInterval else { continue }
                let period = max(1, Int(every / RunRecorder.meterInterval))
                if ticks.isMultiple(of: period) { Self.logHostState() }
            }
        }
    }

    /// Every how many meter ticks the display holds are read: once a minute.
    private static let displayHoldCheckEvery = 30

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
    }

    /// Watches every process the app owns and unwedges a game that has stopped
    /// doing anything. It is on at every level: a killed game is a session
    /// lost either way, and the ladder is what turns a freeze into an ending
    /// the record can name.
    private func startStallWatch() {
        stallWatch.recorder = runRecorder
        stallWatch.onNotAnswering = { [stallWatch] process in
            // After the sample that found it: a modal alert must not run inside the pass.
            DispatchQueue.main.async {
                if NotAnsweringPrompt.userEnds(process.name) { stallWatch.end(process) }
            }
        }
        stallWatch.onGameProcessGone = { [bridge] appID in
            Task(name: "End Steam's entry for \(appID)") {
                if await !bridge.terminateApp(appID) {
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

    /// The wizard's finish button. The runtime usually started when
    /// provisioning completed — the client booted behind the wizard, so the
    /// window the button promises already exists: sign-in if Steam is
    /// waiting for one, the library otherwise.
    private func finishOnboarding() {
        guard isRuntimeStarted else {
            startRunning()
            return
        }
        host.releaseWindowHold()
        if !host.isAwaitingSignIn {
            host.showSteam()
        }
        startSilentUpdates()
        openPendingPrograms()
    }

    /// Set once this process has found another copy holding the ports. The
    /// bottle and the debug session belong to that copy, so this one's quit
    /// sends nothing on its way out.
    private var isDuplicate = false

    /// Another copy of Sevoflurane holds the ports. A half-alive instance —
    /// one that renders no Steam but answers the daemon's commands — is worse
    /// than saying so and going away. The link port and the bridge ports both
    /// find the other copy, and the alert shows once.
    private func reportAnotherCopyIsRunning() {
        guard !isDuplicate else { return }
        isDuplicate = true
        let alert = NSAlert()
        alert.messageText = "Sevoflurane is already running"
        alert.informativeText = "Another copy of Sevoflurane holds its ports. "
            + "Quit that copy, then open this one again."
        alert.runModal()
        NSApp.terminate(nil)
    }

    private var isRuntimeStarted = false

    /// Bridge listeners must be up before the web view's first load 302s
    /// through them.
    private func startRunning(holdingWindows: Bool = false) {
        guard !isRuntimeStarted else { return }
        isRuntimeStarted = true
        if holdingWindows {
            host.holdWindows()
        }
        Task {
            guard await bridge.start() else {
                // Almost always a second copy of the app holding the ports.
                reportAnotherCopyIsRunning()
                return
            }
            await bridge.setGameLaunchHandler { [weak self] in
                Task { @MainActor in self?.gameLaunchWatch.noteLaunchRequested() }
            }
            // The bridge sees a client die before any probe does.
            await bridge.setClientConnectionLostHandler { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.supervisor.wake(.clientConnectionLost) }
                }
            }
            host.bootstrap()
            supervisor.start()
            // The client's own cookie jar is the app's web session;
            // mirrored once at start, refreshed per browser view.
            WebSessionCookies.bridge = bridge
            WebSessionCookies.refresh()
            // Idempotent bottle config (tray suppression, …) — reasserted on
            // every boot so a client update or registry rewrite can't
            // silently bring the Wine tray icon back.
            await provisioner.configureBottle(named: SteamBottle.name)
        }
        // Past the setup gate, so a machine still being provisioned never
        // has its app swapped mid-wizard — a preloading runtime defers this
        // to the wizard's finish.
        if !holdingWindows {
            startSilentUpdates()
            openPendingPrograms()
        }
    }

    private func startSilentUpdates() {
        SilentUpdates.shared.sessionState = { [runRecorder, host] in
            (runRecorder.isRecording, host.activeLaunch != nil)
        }
        SilentUpdates.shared.start(
            autoInstall: UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true,
        )
    }

    private func showSetupWizard(
        provisioner: Provisioner,
        graphics: (() -> GraphicsStore)? = nil,
        onFinished: @escaping () -> Void,
    ) {
        let view = SetupView(
            provisioner: provisioner,
            signInPending: { [weak self] in self?.supervisor.health == .waitingForSignIn },
            onProvisioned: { [weak self] in
                // A dry-run wizard "provisions" fixtures; nothing real may start.
                guard !provisioner.isDryRun else { return }
                self?.startRunning(holdingWindows: true)
            },
            makeGraphics: graphics,
            onFinished: onFinished,
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Sevoflurane"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        setupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Again, once SwiftUI has sized the content: the first center ran
        // against the hosting controller's placeholder frame, and the window
        // then grew from a corner.
        DispatchQueue.main.async { window.center() }
    }

    private func closeSetupWindow() {
        setupWindow?.close()
        setupWindow = nil
    }

    #if DEBUG
        private lazy var galleryWindow = GalleryWindow()

        /// Debug ▸ UI Gallery — every surface in every state, no client.
        @objc
        func showGallery(_: Any?) {
            galleryWindow.show()
        }

        /// Whether this process booted simulated (``DemoMode``, a gallery
        /// launch, or a test run) rather than as the real app.
        private var isSimulatedBoot = false

        /// Retains the harness provisioner for the wizard's lifetime; the app's
        /// own `provisioner` keeps driving Settings › Repair untouched.
        private var dryRunProvisioner: Provisioner?

        /// Built once for a demo boot and kept, so what was changed in one
        /// visit to Settings is still there on the next.
        private var demoSettingsWindow: SettingsWindow?

        /// The whole app on fixtures: the assistant walks the chosen machine,
        /// and finishing it opens Settings on the chosen panes.
        private func startDemo() {
            let provisioner = Provisioner(
                environment: DryRunSetupEnvironment(scenario: DemoMode.setup),
            )
            dryRunProvisioner = provisioner
            let graphics = GraphicsStore(
                environment: DemoGraphicsEnvironment(scenario: DemoMode.graphics),
            )
            let storage = StorageStore(
                environment: DemoStorageEnvironment(scenario: DemoMode.storage),
            )
            // Its own provisioner, on the engine scenario's machine: the pane
            // builds its engine list from detection, and the assistant's
            // machine is a different one.
            let engineScenario = DemoMode.engine
            let engine = EngineStore(
                provisioner: Provisioner(
                    environment: DryRunSetupEnvironment(
                        scenario: .provisioned, detection: engineScenario.detection,
                    ),
                ),
                supervisor: nil,
                environment: DemoEngineEnvironment(scenario: engineScenario),
            )
            let compatibility = CompatibilityStore(
                environment: DemoCompatibilityEnvironment(scenario: DemoMode.compatibility),
            )
            // No supervisor and no host: a demo boot started neither, and the
            // Engine pane's switch must not reach for the client that a real
            // instance alongside this one owns.
            let shaders = ShaderStore(simulated: true)
            demoSettingsWindow = SettingsWindow(
                provisioner: provisioner,
                graphics: { graphics },
                storage: { storage },
                shaders: { shaders },
                engine: { engine },
                compatibility: { compatibility },
            )
            showSetupWizard(provisioner: provisioner, graphics: { graphics }) { [weak self] in
                self?.closeSetupWindow()
                self?.demoSettingsWindow?.show()
            }
        }

        /// Debug ▸ Onboarding Dry Run — reopens the wizard against the chosen
        /// scenario at any time, real machine untouched.
        @objc
        func runOnboardingDryRun(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let scenario = SetupScenario(rawValue: raw) else { return }
            presentDryRunWizard(scenario)
        }

        private func presentDryRunWizard(_ scenario: SetupScenario) {
            closeSetupWindow()
            let provisioner = Provisioner(
                environment: DryRunSetupEnvironment(scenario: scenario),
            )
            dryRunProvisioner = provisioner
            showSetupWizard(provisioner: provisioner) { [weak self] in
                EventLog.shared.log(
                    .setup,
                    "dry-run: wizard finished — a real run would start the bridge, "
                        + "page, and supervisor now",
                )
                self?.closeSetupWindow()
                self?.dryRunProvisioner = nil
            }
        }
    #endif

    /// The app lives in the menu bar; closing Steam's window is not quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// The log's queue is drained on the main actor, and nothing drains it
    /// after this: the lines describing the shutdown are the ones a reader
    /// wants most, so the process waits for them to reach the disk.
    func applicationWillTerminate(_: Notification) {
        if !isDuplicate { DebugModeSwitch.shared.endSession() }
        EventLog.shared.log(.app, "the app is stopping")
        EventLog.flush()
    }

    private var quitTask: Task<Void, Never>?

    /// Quitting Sevoflurane quits Steam: the daemon that owns the bottle is
    /// asked to bring it down, and the quit waits for its answer. This is the
    /// only path that asks — a crash or a force-quit sends nothing, which is
    /// why a game survives one.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A test host never started the client — and the bottle it would tear
        // down belongs to whatever real instance is running alongside.
        if TestHost.isHosting { return .terminateNow }
        #if DEBUG
            // Same for a harness boot.
            if isSimulatedBoot { return .terminateNow }
        #endif
        // The Steam this copy found running is the other copy's.
        if isDuplicate { return .terminateNow }
        guard quitTask == nil else { return .terminateCancel }
        // Before the bottle comes down: a game still up ends here, and after
        // the teardown nothing is left that could say how.
        runMeter?.cancel()
        stallWatch.stop()
        runRecorder.closeAll()
        quitTask = Task(name: "Quit teardown") {
            GameDisplayHold.gameDidExit()
            await provisioner.endForQuit()
            await supervisor.shutdownForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// `steam://` links from browsers and other apps (CFBundleURLTypes), and
    /// Windows executables opened with Sevoflurane from Finder
    /// (CFBundleDocumentTypes).
    ///
    /// A link brings Steam's window up first, so the routed page has
    /// somewhere to land; an executable opens the adoption panel instead,
    /// which is the whole of what this app shows for a program of its own.
    func application(_: NSApplication, open urls: [URL]) {
        let programs = urls.filter(\.isFileURL)
        let links = urls.filter { $0.scheme?.lowercased() == "steam" }
        if !links.isEmpty {
            host.showSteam()
            for url in links {
                host.executeSteamURL(url)
            }
        }
        for url in programs {
            openWindowsProgram(url)
        }
    }

    /// Windows programs handed to the app before it was ready to ask about
    /// them. Finder can open a document at launch, which arrives while the
    /// setup wizard may still own the screen.
    private var pendingPrograms: [URL] = []

    /// Shows the adoption panel, or holds the program until the app is past
    /// setup and has a bottle to offer it.
    private func openWindowsProgram(_ url: URL) {
        guard isRuntimeStarted, setupWindow == nil else {
            pendingPrograms.append(url)
            return
        }
        AdoptionPanel.shared.present(url)
    }

    /// Opens the panel for everything Finder handed over during launch.
    private func openPendingPrograms() {
        let waiting = pendingPrograms
        pendingPrograms = []
        for url in waiting {
            AdoptionPanel.shared.present(url)
        }
    }

    /// The context page lives in a window of its own, so AppKit counts a
    /// visible window and its own reopen logic would never fire. `host`
    /// answers the question the user is actually asking.
    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows _: Bool,
    ) -> Bool {
        EventLog.shared.log(
            .window,
            "reopen request (Dock icon or Finder) — Steam's window is "
                + "\(host.isSteamOnScreen ? "on screen; bringing it forward" : "hidden; showing it")",
        )
        host.showSteam()
        return true
    }

    @objc
    func reloadSteamUI(_: Any?) {
        host.reload()
    }

    /// The app's own settings — open at login, the graphics knobs, Repair.
    /// Steam's settings are its own, and keep ⌘, in the mirrored Steam menu.
    @objc
    func showSettings(_: Any?) {
        settingsWindow.show()
    }

    @objc
    func showRecovery(_: Any?) {
        settingsWindow.showRecovery()
    }

    /// The last runs, what each of them left behind, and the two ways to
    /// share one. Settings › Recovery and the app menu both open it.
    @objc
    func showReports(_: Any?) {
        reportWindows.show()
    }

    /// Every process the app owns, with what each is doing and what can be
    /// done to it.
    @objc
    func showProcesses(_: Any?) {
        processMonitorWindows.show()
    }

    /// About, and the two documents its buttons open. The Settings About
    /// pane reaches the same windows through the responder chain.
    @objc
    func showAbout(_: Any?) {
        aboutWindows.showAbout()
    }

    @objc
    func showAcknowledgements(_: Any?) {
        aboutWindows.showAcknowledgements()
    }

    @objc
    func showLicense(_: Any?) {
        aboutWindows.showLicense()
    }
}
