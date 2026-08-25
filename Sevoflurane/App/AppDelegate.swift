import AppKit
import os
import SwiftUI

/// Application-level wiring that SwiftUI has no scene for: the menu bar, the
/// activation policy, and the single ``SteamWebHost`` everything else reads.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = SteamWebHost()
    let bridge = SteamBridge()
    let provisioner = Provisioner()
    lazy var supervisor = ClientSupervisor(host: host)
    private lazy var controlServer = ControlServer(supervisor: supervisor)
    private var menuMirror: SteamMenuMirror?
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        ClientLifecycle.log = { EventLog.enqueue(.client, $0) }
        PerfProbe.poi.emitEvent("Launch")
        let mirror = SteamMenuMirror(host: host)
        menuMirror = mirror
        host.menuMirror = mirror
        SevofluraneMainMenu.install(mirror: mirror)
        #if DEBUG
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
            if provisioner.needsSetup {
                showSetupWizard(provisioner: provisioner) { [weak self] in
                    self?.closeSetupWindow()
                    self?.startRunning()
                }
            } else {
                startRunning()
            }
        }
    }

    /// Bridge listeners must be up before the web view's first load 302s
    /// through them.
    private func startRunning() {
        Task {
            await bridge.start()
            host.bootstrap()
            supervisor.start()
            // Idempotent bottle config (tray suppression, …) — reasserted on
            // every boot so a client update or registry rewrite can't
            // silently bring the Wine tray icon back.
            await provisioner.configureBottle(named: SteamBottle.name)
        }
    }

    private func showSetupWizard(
        provisioner: Provisioner, onFinished: @escaping () -> Void,
    ) {
        let view = SetupView(provisioner: provisioner, onFinished: onFinished)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Sevoflurane"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        setupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func closeSetupWindow() {
        setupWindow?.close()
        setupWindow = nil
    }

    #if DEBUG
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
}
