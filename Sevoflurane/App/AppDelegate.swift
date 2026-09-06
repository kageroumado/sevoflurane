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
    private lazy var controlServer = ControlServer(supervisor: supervisor, host: host)
    private var menuMirror: SteamMenuMirror?
    private var menuBarPopover: MenuBarPopover?
    private var setupWindow: NSWindow?
    private lazy var aboutWindows = AboutWindows()
    private lazy var liveSettingsWindow = SettingsWindow(
        provisioner: provisioner, supervisor: supervisor, host: host,
    )

    /// The settings window the gear and ⌘, open. A demo boot points this at
    /// one built on simulated stores instead.
    private var settingsWindow: SettingsWindow {
        #if DEBUG
            demoSettingsWindow ?? liveSettingsWindow
        #else
            liveSettingsWindow
        #endif
    }

    func applicationDidFinishLaunching(_: Notification) {
        #if DEBUG
            // The unit tests link against this binary, so running them
            // launches the app. Anything started here would boot the bottle,
            // take the ports off a copy the user is running, and stage into
            // their Steam install — from a test that only wanted to call a
            // function. Before everything, so a test run leaves nothing at
            // all behind it.
            if Self.isHostingTests {
                isSimulatedBoot = true
                return
            }
        #endif
        // First, so a throw during the rest of startup is still recorded.
        ExceptionWatch.install()
        ClientLifecycle.log = { EventLog.enqueue(.client, $0) }
        SetupLog.log = { EventLog.enqueue(.setup, $0) }
        NWJSRunner.log = { EventLog.enqueue(.client, $0) }
        GameLaunchers.log = { EventLog.enqueue(.client, $0) }
        // The defaults key exists because `open` (the only launch path that
        // gets a real Aqua session) strips the environment.
        if let manifest = ProcessInfo.processInfo.environment["SEVO_ENGINE_MANIFEST"]
            ?? Preferences.shared.string(forKey: "engineManifestOverride"),
            let url = URL(string: manifest)
        {
            EngineManifest.overrideURL = url
            EventLog.enqueue(.setup, "engine manifest override: \(manifest)")
        }
        PerfProbe.poi.emitEvent("Launch")
        host.onGameLaunchStart = { [weak self] appID in
            guard let self else { return }
            // Arms the window watch for launches the bridge did not carry
            // (the CLI's, a steam:// URL the client handled itself).
            gameLaunchWatch.noteLaunchRequested()
            // The game's exes, read from its install directory now, so its
            // env files — and the bundle that names it in the Dock — exist
            // before the process starts rather than after its first window.
            Task.detached(name: "Record app \(appID)'s executables") {
                if GameExecutables.recordFromInstall(appID: appID) {
                    ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
                }
            }
        }
        gameLaunchWatch.onGameWindowUp = { [weak self] owner in
            guard let self else { return }
            // Read before the host is told: the window's arrival is what ends
            // the launch, and ending it clears the record of which app it was.
            let launchedAppID = host.activeLaunch?.appID
            host.gameWindowDidAppear()
            // The exe that owns a launch's first window is what a per-game
            // setting is written against; the launch names the app.
            // A window another game has already claimed is that game's: a
            // launch that never shows a window must not adopt a bystander's.
            if let appID = launchedAppID, appID != 0,
               GameConfig.app(claiming: owner).map({ $0 == appID }) ?? true {
                GameConfig.noteExecutable(owner, forApp: appID)
                // A game that has just run for the first time is also the
                // first chance to read its files: what it is built on decides
                // which runners it can be offered. Detached, because reading
                // a game directory is disk work and this is the main actor.
                Task.detached(name: "Detect app \(appID)'s runtime") {
                    NWJSGames.record(appID: appID)
                    ConfigMaterializer.materialize(
                        bottle: SteamBottle.name, prefix: SteamBottle.root,
                    )
                }
            }
        }
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
        #if DEBUG
            if GalleryWindow.wasRequestedAtLaunch {
                // Nothing else starts: the gallery is fixtures all the way
                // down, and a client coming up behind it would only compete
                // for the ports.
                isSimulatedBoot = true
                galleryWindow.show()
                return
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
                return
            }
        #endif
        // Up before provisioning gates so `sevo status` can see the app even
        // while the setup wizard is waiting for the user.
        controlServer.start()
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
                // Almost always a second copy of the app holding the ports
                // (watched happen: a tester copy plus the installed one) —
                // a half-alive instance is worse than saying so.
                let alert = NSAlert()
                alert.messageText = "Sevoflurane is already running"
                alert.informativeText = "Another copy of Sevoflurane has the "
                    + "app's ports — possibly from a different location. Quit "
                    + "the other copy, then open this one again."
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
            await bridge.setGameLaunchHandler { [weak self] in
                Task { @MainActor in self?.gameLaunchWatch.noteLaunchRequested() }
            }
            host.bootstrap()
            supervisor.start()
            // The client's own cookie jar is the app's web session (R5.1);
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
        }
    }

    private func startSilentUpdates() {
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
        window.center()
        window.isReleasedWhenClosed = false
        setupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Again, once SwiftUI has sized the content: the first center ran
        // against the hosting controller's placeholder frame, and the window
        // then grew from a corner (seen bottom-left and top-right).
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

        /// Whether this process is the unit tests' host. `xctest` puts its
        /// configuration path in the environment of the process it loads the
        /// bundle into, which is this one.
        private static var isHostingTests: Bool {
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        }

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
            demoSettingsWindow = SettingsWindow(
                provisioner: provisioner,
                graphics: { graphics },
                storage: { storage },
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

    private var quitTask: Task<Void, Never>?

    /// Quitting Sevoflurane quits Steam: the bottle comes down first so no
    /// Wine process (or its Dock icon) outlives the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
            // A harness boot never started the client — and the bottle it would
            // tear down belongs to whatever real instance is running alongside.
            if isSimulatedBoot { return .terminateNow }
        #endif
        guard quitTask == nil else { return .terminateCancel }
        quitTask = Task(name: "Quit teardown") {
            GameDisplayHold.gameDidExit()
            await supervisor.shutdownForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// `steam://` links from browsers and other apps (CFBundleURLTypes).
    /// The window comes up first so the routed page has somewhere to land.
    func application(_: NSApplication, open urls: [URL]) {
        host.showSteam()
        for url in urls where url.scheme?.lowercased() == "steam" {
            host.executeSteamURL(url)
        }
    }

    /// The context web view lives in an off-screen window, so AppKit always
    /// reports a visible window and its own reopen logic would never fire.
    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows _: Bool,
    ) -> Bool {
        EventLog.shared.log(.window, "reopen request (Dock icon or Finder) — showing Steam")
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
