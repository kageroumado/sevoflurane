import AppKit
import SwiftUI

/// Application-level wiring that SwiftUI has no scene for: the menu bar, the
/// activation policy, and the single ``SteamWebHost`` everything else reads.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = SteamWebHost()
    let bridge = SteamBridge()
    let provisioner = Provisioner()
    lazy var supervisor = ClientSupervisor(host: host)
    private var menuMirror: SteamMenuMirror?
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        let mirror = SteamMenuMirror(host: host)
        menuMirror = mirror
        host.menuMirror = mirror
        SevofluraneMainMenu.install(mirror: mirror)
        Task {
            await provisioner.refreshDetection()
            if provisioner.needsSetup {
                showSetupWizard()
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

    private func showSetupWizard() {
        let view = SetupView(provisioner: provisioner) { [weak self] in
            self?.setupWindow?.close()
            self?.setupWindow = nil
            self?.startRunning()
        }
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

    /// The app lives in the menu bar; closing Steam's window is not quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    private var quitTask: Task<Void, Never>?

    /// Quitting Sevoflurane quits Steam: the bottle comes down first so no
    /// Wine process (or its Dock icon) outlives the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard quitTask == nil else { return .terminateCancel }
        quitTask = Task(name: "Quit teardown") {
            await supervisor.shutdownForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
