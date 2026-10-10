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
    lazy var steamSession = SteamSessionWatch(bridge: bridge)
    let gameLaunchWatch = GameLaunchWatch()
    let runRecorder = RunRecorder()
    let stallWatch = StallWatch()
    var runMeter: Task<Void, Never>?
    private lazy var appLinkServer: AppLinkServer = {
        let server = AppLinkServer(
            supervisor: supervisor, host: host, bridge: bridge, presentStats: runRecorder.presentStats,
        )
        server.onFixesApplied = { [weak self] appID in self?.announceFixesApplied(appID: appID) }
        return server
    }()
    private var menuMirror: SteamMenuMirror?
    private(set) var menuBarPopover: MenuBarPopover?
    let setupWindow = SetupWindow()
    private lazy var aboutWindows = AboutWindows()
    private lazy var reportWindows: ReportWindows = {
        let windows = ReportWindows()
        windows.showGuide = { [weak self] in self?.showReportGuide() }
        return windows
    }()
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
        StatsUploader.log = { EventLog.enqueue(.app, "stats: \($0)") }
        FixList.log = { EventLog.enqueue(.app, $0) }
        Diagnostics.faceReport = { await Diagnostics.appFaceReport() }
        CrashPrompt.shared.install()
        RunRecorder.didRecord = { record, wineTail in
            Self.collectReports(record, wineTail: wineTail)
            StatsUploader.submit(record)
        }
        Task.detached(name: "Send queued shared runs") { await StatsUploader.shared.flush() }
        Task.detached(name: "Refresh the fix list") { await FixList.refreshIfStale() }
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
        NativeSteam.adoptEarlierChoices(games: Array(GameConfig.games().values))
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
        countsUse = true
        UsageCounting.start()
        startServices()
    }

    /// Set once a real launch is under way: a test host, the gallery and the
    /// demo are not someone using the app.
    private(set) var countsUse = false

    func applicationDidBecomeActive(_: Notification) {
        if countsUse { UsageCounting.noteUse() }
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
        steamSession.notifications = notifications
        supervisor.session = steamSession
        menuBarPopover = MenuBarPopover(
            host: host, supervisor: supervisor, notifications: notifications,
            setup: setupWindow,
        )
        menuBarPopover?.onOpen = { [weak self] in
            if self?.countsUse == true { UsageCounting.noteUse() }
        }
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
        Task.detached(name: "Adopt the engines' D3DMetal toolkits") {
            D3DMetalInstaller.adoptInstalledEnginesToolkits()
        }
        // Setup too: the assistant also opens for an existing Mac whose bottle is missing,
        // and its own engine stage installs only onto a Mac with no managed engine.
        Self.installBundledEngineIfNewer()
        Task {
            await provisioner.refreshDetection()
            if let detection = provisioner.detection {
                Engine.active = Engine.resolve(from: detection)
            }
            if provisioner.needsSetup {
                showSetupWizard(
                    provisioner: provisioner,
                    onSkipSignIn: { [weak self] in
                        guard let self else { return }
                        EventLog.shared.log(.setup, "finished without signing in to Steam")
                        host.signInIsSkipped = true
                        setupWindow.finish()
                        finishOnboarding()
                        // No window follows this finish: the app is a
                        // menu-bar app from here.
                        ActivationPolicy.recedeIfLastWindow(closing: nil)
                    },
                ) { [weak self] in
                    self?.setupWindow.finish()
                    self?.finishOnboarding()
                }
            } else {
                startRunning()
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
                if Engine.adoptNewerRelease(version) {
                    EventLog.enqueue(.setup, "engine: the stored choice named an older release; it names \(version) now")
                }
            } catch {
                EventLog.enqueue(.setup, "engine: the engine this app carries did not install — \(error)")
            }
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

    private(set) var isRuntimeStarted = false

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
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.gameLaunchWatch.noteLaunchRequested() }
                }
            }
            await bridge.setLaunchPreparation { [weak self] gameID in
                guard let appID = await self?.host.appID(fromSteam: gameID), appID != 0 else { return }
                await Self.prepareLaunch(appID: appID)
            }
            await bridge.setInstallGate { [weak self] appID in
                guard let host = await self?.host else { return true }
                return await host.confirmInstall(appID: appID)
            }
            // The bridge sees a client die before any probe does.
            await bridge.setClientConnectionLostHandler { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.supervisor.wake(.clientConnectionLost) }
                }
            }
            // Steam's list of non-Steam games follows the adopted programs
            // whenever a client is there to take the calls.
            SteamLibraryShortcuts.shared.bridge = bridge
            SteamLibraryShortcuts.shared.onAliases = { [host] in host.shortcutPrograms = $0 }
            supervisor.onHealthy = { SteamLibraryShortcuts.shared.sync() }
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
            autoInstall: Preferences.app.object(forKey: "autoUpdate") as? Bool ?? true,
        )
    }

    /// The window the assistant's finish button would bring up. Steam's own
    /// windows, read directly: the supervisor's health reaches the app a probe
    /// cycle later.
    private var setupSteamWindow: SetupSteamWindow {
        if supervisor.daemonIsUnreachable { return .helperDown(supervisor.statusText.sentenceCased) }
        if host.hasLoginWindow { return .signIn }
        if host.desktop != nil { return .library }
        return .starting
    }

    private func showSetupWizard(
        provisioner: Provisioner,
        graphics: (() -> GraphicsStore)? = nil,
        onSkipSignIn: (() -> Void)? = nil,
        onFinished: @escaping () -> Void,
    ) {
        let view = SetupView(
            provisioner: provisioner,
            // A simulated run starts no Steam; its finish opens straight away.
            steamWindow: { [weak self] in
                provisioner.isDryRun ? .library : self?.setupSteamWindow ?? .starting
            },
            onRepairHelper: { [weak self] in
                Task(name: "Repair the background helper from setup") {
                    let result = await DaemonService.repair()
                    EventLog.shared.log(.setup, "background helper repair from setup: \(result)")
                    await self?.supervisor.attach()
                }
            },
            onProvisioned: { [weak self] in
                // A dry-run wizard "provisions" fixtures; nothing real may start.
                guard !provisioner.isDryRun else { return }
                self?.startRunning(holdingWindows: true)
                // Supervision may be paused by the stop that preceded a bottle
                // switch. The start resumes it and boots the client in the
                // bottle setup just finished; the daemon holds it while the
                // provisioning lease stands.
                self?.supervisor.startAfterSetup()
            },
            stopClient: { [weak self] narrate in
                await self?.supervisor.stopBeforeBottleSwitch(narrate: narrate)
            },
            onSkipSignIn: onSkipSignIn,
            makeGraphics: graphics,
            onFinished: onFinished,
        )
        setupWindow.present(view)
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
                self?.setupWindow.finish()
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
            setupWindow.finish()
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
                self?.setupWindow.finish()
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

    /// Set when a quit is reissued from the run loop (``applicationShouldTerminate(_:)``).
    private var isQuittingFromRunLoop = false

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
        // `.terminateLater` waits for the teardown task below, whose jobs run on the main queue.
        // A terminate issued from inside a main-queue job (AppUpdater's swap, any `Task` that
        // quits) holds that queue for as long as AppKit's nested loop runs, so the teardown never
        // starts and the app sits on "Quitting" forever. Such a quit is reissued from the run
        // loop, where the main queue drains. A quit Apple event (logout, restart, `osascript`)
        // is answered in place: cancelling it would cancel the logout.
        if !isQuittingFromRunLoop, NSAppleEventManager.shared().currentAppleEvent == nil {
            isQuittingFromRunLoop = true
            RunLoop.main.perform(inModes: [.default, .modalPanel]) { NSApp.terminate(nil) }
            return .terminateCancel
        }
        // Before the bottle comes down: a game still up ends here, and after
        // the teardown nothing is left that could say how.
        runMeter?.cancel()
        stallWatch.stop()
        runRecorder.closeAll()
        supervisor.beginQuit()
        quitTask = Task(name: "Quit teardown") {
            GameDisplayHold.gameDidExit()
            await provisioner.endForQuit()
            await supervisor.shutdownForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The store a program's Dock tile launches through when its URL arrives
    /// before the menu bar is installed — a tile that started this app opens
    /// it first. Wired like the popover's store, so the status line, the
    /// window watch and the run record open for that launch as for any other.
    lazy var dockQuickLaunch: QuickLaunchStore = {
        let store = QuickLaunchStore()
        store.launchHooks = QuickLaunchStore.LaunchHooks(reporting: host)
        return store
    }()

    /// Windows programs handed to the app before it was ready to ask about
    /// them. Finder can open a document at launch, which arrives while the
    /// setup wizard may still own the screen.
    var pendingPrograms: [URL] = []

    @objc
    func reloadSteamUI(_: Any?) {
        host.reload()
    }

    /// Flips Streamer Mode from the app menu, for the moment before a
    /// recording starts.
    @objc
    func toggleStreamerMode(_: Any?) {
        StreamerMode.isOn.toggle()
        host.applyStreamerMode()
    }

    /// The app's own settings — open at login, the graphics knobs, Repair.
    /// Steam's settings are its own, and keep ⌘, in the mirrored Steam menu.
    @objc
    func showSettings(_: Any?) {
        // Settings edits a bottle and an engine the assistant is still
        // choosing; it opens once setup is finished.
        if setupWindow.show() { return }
        settingsWindow.show()
    }

    @objc
    func showRecovery(_: Any?) {
        settingsWindow.showRecovery()
    }

    /// Settings › Diagnostics, open on the steps for a useful report. Waits
    /// behind an unfinished setup, as ``showSettings(_:)`` does.
    func showReportGuide() {
        if setupWindow.show() { return }
        settingsWindow.showReportGuide()
    }

    /// Settings › Games, open on one game's own settings. Waits behind an
    /// unfinished setup, as ``showSettings(_:)`` does.
    func showGameSettings(id: Int, name: String) {
        if setupWindow.show() { return }
        settingsWindow.showGame(id: id, name: name)
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

extension AppDelegate: NSMenuItemValidation {
    @objc
    func checkForUpdates(_: Any?) {
        SilentUpdates.shared.checkOrInstallFromMenu()
    }

    /// Checks the Streamer Mode item while the mode is on and titles the update
    /// item. Every item this delegate answers for stays enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleStreamerMode(_:)) {
            menuItem.state = StreamerMode.isOn ? .on : .off
        }
        if menuItem.action == #selector(checkForUpdates(_:)) {
            SilentUpdates.shared.refresh()
            menuItem.title = SilentUpdates.shared.menuItemTitle
        }
        return true
    }
}
