import AppKit
import os
import SwiftUI

/// Application-level wiring: the menus, the menu-bar item, the activation
/// policy, and the single ``SteamWebHost`` everything else reads.
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

    /// The settings window the gear and ⌘, open; a demo boot uses one on
    /// simulated stores.
    private var settingsWindow: SettingsWindow {
        #if DEBUG
            demoSettingsWindow ?? liveSettingsWindow
        #else
            liveSettingsWindow
        #endif
    }

    // Launches that do something other than run the app. Answers whether one
    // took the launch.
    #if DEBUG
        private func handledDebugLaunch() -> Bool {
            // A worktree build registers its own background helper, and a stale
            // registration would start that build's daemon at the next login.
            // `SMAppService` can only unregister from the bundle that
            // registered, so the trigger lives here; `open` strips the
            // environment, so run the bundle's executable directly.
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

    /// Points the shared, process-agnostic code at this process's logging and
    /// client connection; the daemon installs its own set.
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
    /// zero when it ended badly, after every run above that, with a doctor pass
    /// and compression at level two. Runs on the recorder's closing queue.
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
        // Level two is set to catch one crash; left on, it writes a gigabyte of
        // logs.
        if DiagnosticLevel.expireAfterRun() {
            EventLog.enqueue(.app, "diagnostics back to \(DiagnosticLevel.current.summary)")
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // The unit tests launch this binary; anything started here would boot
        // the bottle, take the ports off a running copy, and stage into the
        // user's Steam install.
        if TestHost.isHosting { return }
        #if DEBUG
            if handledDebugLaunch() { return }
        #endif
        // First, so a throw during the rest of startup is still recorded.
        ExceptionWatch.install()
        installSharedHooks()
        NativeSteam.adoptEarlierChoices(games: Array(GameConfig.games().values))
        // Before anything can start a bottle process, so this launch's client
        // is not the killed session's verbose one.
        DebugModeSwitch.shared.clearStaleFile()
        applyEngineManifestOverride()
        PerfProbe.poi.emitEvent("Launch")
        installLaunchHooks()
        // A game outlives the app that launched it, so a launch armed by a
        // force-quit process is picked up here.
        runRecorder.reattach()
        startRunMeter()
        startStallWatch()
        installMenuBar()
        #if DEBUG
            if bootedOnFixtures() { return }
        #endif
        // Opened by a person (Dock, Finder, `open`) rather than as a login item
        // or to handle a file: Steam's window comes up once the client is
        // healthy. A login-item launch stays a menu-bar app.
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
    /// environment or the defaults key.
    ///
    /// An override manifest and its tarballs are trusted unsigned, so a release
    /// build takes only a `file://` one and a defaults write cannot point it at
    /// a remote engine.
    private func applyEngineManifestOverride() {
        // The defaults key exists because `open`, the only launch path with a
        // real Aqua session, strips the environment.
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

    private func installMenuBar() {
        let mirror = SteamMenuMirror(host: host)
        menuMirror = mirror
        host.menuMirror = mirror
        SevofluraneMainMenu.install(mirror: mirror)
        // Before the gallery and dry-run gates return: setting the delegate is
        // what lets a click on a notification that woke the app be delivered.
        // Reading the permission raises no prompt.
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
        /// Whether this launch asked for the gallery or the demo, which run on
        /// fixtures and start nothing else.
        private func bootedOnFixtures() -> Bool {
            if GalleryWindow.wasRequestedAtLaunch {
                // A client coming up behind the gallery would only compete for
                // the ports.
                isSimulatedBoot = true
                galleryWindow.show()
                return true
            }
            if DemoMode.isOn {
                // No control server (a live instance may own the port), no
                // bridge, no client.
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

    /// Takes the daemon link port, stocks the shader store, then runs setup or
    /// brings the client up.
    private func startServices() {
        Task(name: "Start services") {
            // First, and everything else waits on it: the port is how a second
            // copy finds out, and that copy must not touch the bottle, the
            // engines or the shared folders the first one is using. Up before
            // provisioning, so the daemon can reach the page while the setup
            // wizard waits.
            guard await self.appLinkServer.start() else {
                self.reportAnotherCopyIsRunning()
                return
            }
            self.startServicesHoldingThePort()
        }
    }

    private func startServicesHoldingThePort() {
        // Before any game could be launched naming one. Detached: it copies
        // files.
        Task.detached(name: "Copy bundled shader packages") {
            ShaderPackages.ensureBundled()
        }
        Task.detached(name: "Adopt the engines' D3DMetal toolkits") {
            D3DMetalInstaller.adoptInstalledEnginesToolkits()
        }
        // Setup too: the assistant also opens for an existing Mac whose bottle is missing,
        // and its engine stage installs only onto a Mac with no managed engine.
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
                        // No window follows this finish: the app is a menu-bar
                        // app from here.
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

    /// Installs an engine newer than every managed one, off the main actor; it takes over at
    /// the client's next start unless the user chose another.
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

    /// The wizard's finish button. The client usually booted behind the wizard,
    /// so the window it promises (sign-in or the library) already exists.
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

    /// Set once another copy was found holding the ports. The bottle and the
    /// debug session are that copy's, so this one's quit sends nothing.
    private var isDuplicate = false

    /// Another copy of Sevoflurane holds the ports. A half-alive instance that
    /// renders no Steam but answers the daemon is worse than saying so and
    /// quitting. Both the link port and the bridge ports find the other copy;
    /// the alert shows once.
    private func reportAnotherCopyIsRunning() {
        guard !isDuplicate else { return }
        isDuplicate = true
        // Callers are Tasks: a modal or a terminate inside a main-queue job
        // freezes every other MainActor job until it returns.
        ModalAlerts.present {
            let alert = NSAlert()
            alert.messageText = "Sevoflurane is already running"
            alert.informativeText = "Another copy of Sevoflurane holds its ports. "
                + "Quit that copy, then open this one again."
            alert.runModal()
            NSApp.terminate(nil)
        }
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
            SteamLibraryShortcuts.shared.bridge = bridge
            SteamLibraryShortcuts.shared.onAliases = { [host] in host.shortcutPrograms = $0 }
            supervisor.onHealthy = { SteamLibraryShortcuts.shared.sync() }
            host.bootstrap()
            supervisor.start()
            // The client's own cookie jar is the app's web session; mirrored
            // once at start, refreshed per browser view.
            WebSessionCookies.bridge = bridge
            WebSessionCookies.refresh()
            // Reasserted on every boot so a client update or registry rewrite
            // cannot bring the Wine tray icon back.
            await provisioner.configureBottle(named: SteamBottle.name)
        }
        // Never swap the app mid-wizard: a preloading runtime defers this to
        // the wizard's finish.
        if !holdingWindows {
            startSilentUpdates()
            openPendingPrograms()
        }
    }

    private func startSilentUpdates() {
        SilentUpdates.shared.sessionState = { [runRecorder, host, provisioner] in
            (runRecorder.isRecording, host.activeLaunch != nil, provisioner.isWorking)
        }
        SilentUpdates.shared.start(
            autoInstall: Preferences.app.object(forKey: "autoUpdate") as? Bool ?? true,
        )
    }

    /// The window the assistant's finish button would bring up, read from
    /// Steam's windows directly: the supervisor's health lags a probe cycle.
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
                // A dry-run wizard provisions fixtures; nothing real may start.
                guard !provisioner.isDryRun else { return }
                self?.startRunning(holdingWindows: true)
                // The stop before a bottle switch may have paused supervision;
                // this start resumes it, and the daemon holds the client while
                // the provisioning lease stands.
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

        /// Debug ▸ UI Gallery: every surface in every state, no client.
        @objc
        func showGallery(_: Any?) {
            galleryWindow.show()
        }

        /// Whether this process booted simulated (``DemoMode``, a gallery
        /// launch, or a test run).
        private var isSimulatedBoot = false

        /// The harness provisioner, held for the wizard's lifetime.
        private var dryRunProvisioner: Provisioner?

        /// Kept, so changes in one visit to the demo's Settings survive to the
        /// next.
        private var demoSettingsWindow: SettingsWindow?

        /// The whole app on fixtures: the assistant walks the chosen machine,
        /// and finishing it opens Settings.
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
            // Its own provisioner: the Engine pane builds its list from
            // detection, and the assistant's machine is a different one.
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
            // No supervisor and no host: the Engine pane's switch must not
            // reach for a real instance's client.
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

        /// Debug ▸ Onboarding Dry Run: reopens the wizard against the chosen
        /// scenario, real machine untouched.
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

    /// The app lives in the menu bar, so closing Steam's window leaves it running.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Nothing drains the log's main-actor queue after this, so the shutdown
    /// lines are flushed to disk here.
    func applicationWillTerminate(_: Notification) {
        if !isDuplicate { DebugModeSwitch.shared.endSession() }
        EventLog.shared.log(.app, "the app is stopping")
        EventLog.flush()
    }

    private var quitTask: Task<Void, Never>?

    /// The quit teardown is under way, for anything that would otherwise read the wait for
    /// the process to end as a failure.
    private(set) static var isQuitting = false

    private var isQuittingFromRunLoop = false

    /// Quitting Sevoflurane quits Steam: the daemon is asked to bring the
    /// bottle down and the quit waits for its answer. A crash or force-quit
    /// sends nothing, which is why a game survives one.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A test host never started the client; the bottle belongs to a real
        // instance alongside.
        if TestHost.isHosting { return .terminateNow }
        #if DEBUG
            // Same for a harness boot.
            if isSimulatedBoot { return .terminateNow }
        #endif
        // The Steam this copy found running is the other copy's.
        if isDuplicate { return .terminateNow }
        guard quitTask == nil else { return .terminateCancel }
        // `.terminateLater` waits for a teardown whose jobs run on the main queue. A terminate
        // issued from inside a main-queue job (AppUpdater's swap, any `Task` that quits) holds
        // that queue while AppKit's nested loop runs, so the app would sit on "Quitting" forever;
        // such a quit is reissued from the run loop. A quit Apple event (logout, restart,
        // `osascript`) is answered in place, since cancelling it would cancel the logout.
        if !isQuittingFromRunLoop, NSAppleEventManager.shared().currentAppleEvent == nil {
            isQuittingFromRunLoop = true
            RunLoop.main.perform(inModes: [.default, .modalPanel]) { NSApp.terminate(nil) }
            return .terminateCancel
        }
        // Before the bottle comes down: after the teardown nothing is left that
        // could say how a running game ended.
        runMeter?.cancel()
        stallWatch.stop()
        runRecorder.closeAll()
        supervisor.beginQuit()
        Self.isQuitting = true
        quitTask = Task(name: "Quit teardown") {
            GameDisplayHold.gameDidExit()
            await provisioner.endForQuit()
            await supervisor.shutdownForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The store a Dock tile launches through when its URL arrives before the
    /// menu bar is installed. Wired like the popover's store, so the status
    /// line, window watch and run record open as for any launch.
    lazy var dockQuickLaunch: QuickLaunchStore = {
        let store = QuickLaunchStore()
        store.launchHooks = QuickLaunchStore.LaunchHooks(reporting: host)
        return store
    }()

    /// Windows programs handed over before setup finished (Finder can open a
    /// document at launch).
    var pendingPrograms: [URL] = []

    @objc
    func reloadSteamUI(_: Any?) {
        host.reloadAskedByUser()
    }

    /// Flips Streamer Mode from the app menu.
    @objc
    func toggleStreamerMode(_: Any?) {
        StreamerMode.isOn.toggle()
        host.applyStreamerMode()
    }

    /// The app's own settings. Steam's settings keep ⌘, in the mirrored Steam
    /// menu.
    @objc
    func showSettings(_: Any?) {
        // Waits for setup: Settings edits a bottle and engine the assistant is
        // still choosing.
        if setupWindow.show() { return }
        settingsWindow.show()
    }

    @objc
    func showRecovery(_: Any?) {
        settingsWindow.showRecovery()
    }

    /// Settings › Diagnostics on the report steps; waits behind an unfinished
    /// setup.
    func showReportGuide() {
        if setupWindow.show() { return }
        settingsWindow.showReportGuide()
    }

    /// Settings › Games on one game; waits behind an unfinished setup.
    func showGameSettings(id: Int, name: String) {
        if setupWindow.show() { return }
        settingsWindow.showGame(id: id, name: name)
    }

    /// The last runs and what each left behind. Settings › Recovery and the app
    /// menu both open it.
    @objc
    func showReports(_: Any?) {
        reportWindows.show()
    }

    /// Every process the app owns, and what can be done to each.
    @objc
    func showProcesses(_: Any?) {
        processMonitorWindows.show()
    }

    /// About and its two documents. The Settings About pane reaches them
    /// through the responder chain.
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

    /// Checks the Streamer Mode item and titles the update item; every item
    /// stays enabled.
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
