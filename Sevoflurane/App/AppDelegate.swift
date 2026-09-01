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
    private lazy var settingsWindow = SettingsWindow(
        provisioner: provisioner, supervisor: supervisor, host: host,
    )

    func applicationDidFinishLaunching(_: Notification) {
        // First, so a throw during the rest of startup is still recorded.
        ExceptionWatch.install()
        ClientLifecycle.log = { EventLog.enqueue(.client, $0) }
        SetupLog.log = { EventLog.enqueue(.setup, $0) }
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
        gameLaunchWatch.onGameWindowUp = { [weak self] in
            self?.host.gameWindowDidAppear()
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
                isDryRunBoot = true
                galleryWindow.show()
                return
            }
            if let scenario = SetupScenario.fromLaunchEnvironment() {
                // The onboarding harness: no control server (a live instance may
                // own the port), no bridge, no client — nothing on the machine
                // moves, and the wizard runs against the scenario fixture.
                isDryRunBoot = true
                EventLog.shared.log(
                    .setup, "dry-run: onboarding harness booted (\(scenario.rawValue))",
                )
                presentDryRunWizard(scenario)
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
        provisioner: Provisioner, onFinished: @escaping () -> Void,
    ) {
        let view = SetupView(
            provisioner: provisioner,
            onFinished: onFinished,
            signInPending: { [weak self] in self?.supervisor.health == .waitingForSignIn },
            onProvisioned: { [weak self] in
                // A dry-run wizard "provisions" fixtures; nothing real may start.
                guard !provisioner.isDryRun else { return }
                self?.startRunning(holdingWindows: true)
            },
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

        /// Whether this process booted as the onboarding harness
        /// (`SEVO_SETUP_DRY_RUN`) rather than as the real app.
        private var isDryRunBoot = false

        /// Retains the harness provisioner for the wizard's lifetime; the app's
        /// own `provisioner` keeps driving Settings › Repair untouched.
        private var dryRunProvisioner: Provisioner?

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
            if isDryRunBoot { return .terminateNow }
        #endif
        guard quitTask == nil else { return .terminateCancel }
        quitTask = Task(name: "Quit teardown") {
            await GameModeSession.restoreForQuit()
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
}
