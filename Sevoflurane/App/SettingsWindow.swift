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
    private let navigation = SettingsNavigation()
    private let makeGraphics: () -> GraphicsStore
    private let makeStorage: () -> StorageStore
    private let makeShaders: () -> ShaderStore
    /// One engine store for the app's lifetime, not one per window: an
    /// engine switch outlives a closed Settings window, and reopening must
    /// show the switch still running rather than offer a second one.
    private lazy var engineStore = makeEngine()
    private let makeEngine: () -> EngineStore
    private let makeCompatibility: () -> CompatibilityStore
    /// Kept alongside the engine store: an install running in the
    /// dependencies section must survive the window closing over it.
    private lazy var compatibilityStore = makeCompatibility()

    /// The graphics and storage stores are made per window, because those
    /// panes read the machine as they appear; the engine store is made once.
    /// A simulated build hands over closures that answer with the same
    /// in-memory stores every time, so what was changed in one visit to
    /// Settings is still there on the next.
    init(
        provisioner: Provisioner, supervisor: ClientSupervisor? = nil,
        host: SteamWebHost? = nil,
        graphics: @escaping () -> GraphicsStore = { GraphicsStore() },
        storage: @escaping () -> StorageStore = { StorageStore() },
        shaders: @escaping () -> ShaderStore = { ShaderStore() },
        engine: (() -> EngineStore)? = nil,
        compatibility: @escaping () -> CompatibilityStore = { CompatibilityStore() },
    ) {
        self.supervisor = supervisor
        self.provisioner = provisioner
        self.host = host
        makeGraphics = graphics
        makeStorage = storage
        makeShaders = shaders
        makeCompatibility = compatibility
        makeEngine = engine ?? {
            EngineStore(provisioner: provisioner, supervisor: supervisor)
        }
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
        // Before the window is built: the view's first body evaluation logs
        // the pane it opens on, and that line reads as what followed this one.
        EventLog.shared.log(.window, "settings: opened")
        let window = makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showRecovery() {
        navigation.showRecovery()
        show()
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
                cancelStuckMenus: { [weak host] in host?.menuMirror?.cancelTracking() ?? [] },
            )
        }
        let controller = NSHostingController(
            rootView: SettingsView(
                provisioner: provisioner,
                graphics: makeGraphics(),
                storage: makeStorage(),
                engine: engineStore,
                shaders: makeShaders(),
                compatibility: compatibilityStore,
                steam: steam,
                supervisor: supervisor,
                navigation: navigation,
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
                EventLog.shared.log(.window, "settings: closed")
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
