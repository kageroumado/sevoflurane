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
    /// The open window's close observer, removed when it fires.
    private var closeObserver: (any NSObjectProtocol)?
    /// Retitles the open window as the pane changes; cancelled when it closes.
    private var titleTask: Task<Void, Never>?
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
    /// Opens the report window, which lives beside Settings rather than in a
    /// pane of it. Nil in a simulated build, where no second window opens.
    var showReports: (() -> Void)?
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

    func showReportGuide() {
        navigation.showReportGuide()
        show()
    }

    func showGame(id: Int, name: String) {
        navigation.showGame(id: id, name: name)
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
                applyCompatibilityStrip: { [weak host] in host?.applyCompatibilityStrip() },
                applyStreamerMode: { [weak host] in host?.applyStreamerMode() },
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
                showReports: showReports,
                navigation: navigation,
            ),
        )
        // The window's size is the window's: with the default options a pane
        // whose ideal height is its whole form — a game's settings — grows
        // the window past the bottom of the screen.
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        titleByPane(window)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        // The separator is the whole toolbar: it is what aligns the split
        // view's divider with the titlebar, and without a toolbar at all the
        // sidebar and the pane get their own disjoint title areas.
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        // The default mode reserves a label line under every item, which
        // grows the titlebar by that line though the toolbar has no items.
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: 800, height: 560))
        window.minSize = NSSize(width: 720, height: 460)
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main,
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.window = nil
                self?.titleTask?.cancel()
                self?.titleTask = nil
                if let observer = self?.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self?.closeObserver = nil
                }
                EventLog.shared.log(.window, "settings: closed")
                ActivationPolicy.recedeIfLastWindow(closing: window)
            }
        }
        return window
    }

    /// The window is titled by the pane it shows, as a settings window is.
    /// An AppKit window takes no title from the split view's
    /// `navigationTitle`, so the selection is observed here.
    private func titleByPane(_ window: NSWindow) {
        // Set before the window is ordered front; the stream's first value
        // arrives a turn of the run loop later.
        window.title = navigation.category.title
        let titles = Observations { [navigation] in navigation.category.title }
        titleTask = Task(name: "Title settings by pane") { [weak window] in
            for await title in titles {
                guard let window else { return }
                window.title = title
            }
        }
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
