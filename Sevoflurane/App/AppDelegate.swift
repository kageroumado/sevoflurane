import AppKit

/// Application-level wiring that SwiftUI has no scene for: the menu bar, the
/// activation policy, and the single ``SteamWebHost`` everything else reads.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = SteamWebHost()
    lazy var supervisor = ClientSupervisor(host: host)
    private var menuMirror: SteamMenuMirror?

    func applicationDidFinishLaunching(_: Notification) {
        let mirror = SteamMenuMirror(host: host)
        menuMirror = mirror
        host.menuMirror = mirror
        SevofluraneMainMenu.install(mirror: mirror)
        host.bootstrap()
        supervisor.start()
    }

    /// The app lives in the menu bar; closing Steam's window is not quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// The context web view lives in an off-screen window, so AppKit always
    /// reports a visible window and its own reopen logic would never fire.
    func applicationShouldHandleReopen(_: NSApplication,
                                       hasVisibleWindows _: Bool) -> Bool {
        host.showSteam()
        return true
    }

    @objc func reloadSteamUI(_: Any?) {
        host.reload()
    }
}
