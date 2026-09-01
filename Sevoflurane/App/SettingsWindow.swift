import AppKit
import SwiftUI

/// The one settings window, opened from the app menu and the popover's gear.
///
/// Built fresh each time it is asked for and released when it closes: settings
/// hold no state worth keeping alive behind a closed window, and the panes
/// read the machine (engine, bottle, login item) as they appear.
@MainActor
final class SettingsWindow: NSObject, NSToolbarDelegate {
    private let provisioner: Provisioner
    private weak var supervisor: ClientSupervisor?
    private weak var host: SteamWebHost?
    private var window: NSWindow?
    /// One engine store for the app's lifetime, not one per window: an
    /// engine switch outlives a closed Settings window, and reopening must
    /// show the switch still running rather than offer a second one.
    private lazy var engineStore = EngineStore(
        provisioner: provisioner, supervisor: supervisor,
    )

    init(
        provisioner: Provisioner, supervisor: ClientSupervisor? = nil,
        host: SteamWebHost? = nil,
    ) {
        self.supervisor = supervisor
        self.provisioner = provisioner
        self.host = host
    }

    func show() {
        // Settings is a real window: while it's up the app has a Dock tile
        // and an active menu bar, like any app with a window on screen.
        ActivationPolicy.becomeRegular()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let steam = host.map { host in
            SteamActions(
                openSteamSettings: { [weak host] in
                    // The settings window needs the client's UI up to open
                    // over; showSteam brings both forward.
                    host?.showSteam()
                    host?.executeSteamURL(URL(string: "steam://open/settings")!)
                },
                uninstall: { [weak host] appID in
                    host?.showSteam()
                    host?.executeSteamURL(URL(string: "steam://uninstall/\(appID)")!)
                },
                restartClient: { [weak supervisor] in supervisor?.restartNow() },
            )
        }
        let controller = NSHostingController(
            rootView: SettingsView(
                provisioner: provisioner, graphics: .live(), storage: .live(),
                engine: engineStore,
                steam: steam,
                supervisor: supervisor,
            ),
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        // The separator is the whole toolbar: it is what aligns the split
        // view's divider with the titlebar, and without a toolbar at all the
        // sidebar and the pane get their own disjoint title areas.
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        window.toolbar = toolbar
        // A hosting controller sizes itself from the view, and the view sizes
        // itself from the window — so somebody has to name a number first.
        window.setContentSize(NSSize(width: 720, height: 460))
        window.minSize = NSSize(width: 660, height: 420)
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main,
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.window = nil
                ActivationPolicy.recedeIfLastWindow(closing: window)
            }
        }
        return window
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier _: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool,
    ) -> NSToolbarItem? {
        nil
    }
}
