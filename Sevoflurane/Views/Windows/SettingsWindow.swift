import AppKit
import SwiftUI

/// The settings window, built fresh on each open and released on close: the
/// panes read the machine as they appear.
@MainActor
final class SettingsWindow: NSObject, NSToolbarDelegate {
    private let provisioner: Provisioner
    private weak var supervisor: ClientSupervisor?
    private weak var host: SteamWebHost?
    private var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?
    /// Retitles the open window as the pane changes.
    private var titleTask: Task<Void, Never>?
    private let navigation = SettingsNavigation()
    private let makeGraphics: () -> GraphicsStore
    private let makeStorage: () -> StorageStore
    private let makeShaders: () -> ShaderStore
    /// One engine store for the app's lifetime: an engine switch outlives a
    /// closed window, and reopening must show it still running.
    private lazy var engineStore = makeEngine()
    private let makeEngine: () -> EngineStore
    private let makeCompatibility: () -> CompatibilityStore
    /// Opens the report window; nil in a simulated build.
    var showReports: (() -> Void)?
    /// Lives as long as the engine store, so a dependency install survives
    /// the window closing.
    private lazy var compatibilityStore = makeCompatibility()

    /// The graphics, storage and shader stores are made per window. A
    /// simulated build passes closures that return the same in-memory stores,
    /// so changes persist between visits.
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
        ActivationPolicy.becomeRegular()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        // Logged before the view logs the pane it opens on.
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
        let controller = NSHostingController(
            rootView: SettingsView(
                provisioner: provisioner,
                graphics: makeGraphics(),
                storage: makeStorage(),
                engine: engineStore,
                shaders: makeShaders(),
                compatibility: compatibilityStore,
                diagnostics: DiagnosticsStore(),
                steam: steamActions(),
                supervisor: supervisor,
                showReports: showReports,
                navigation: navigation,
            ),
        )
        // With the default options a tall form grows the window past the screen.
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        titleByPane(window)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        // The toolbar holds only the separator that aligns the split view's
        // divider with the titlebar.
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        // The default mode reserves a label line that grows the titlebar.
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

    /// What the panes can ask of the running client; `nil` without one.
    private func steamActions() -> SteamActions? {
        host.map { host in
            SteamActions(
                openSteamSettings: { [weak host] in
                    // Steam's settings open over the client's UI, so it comes up first.
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
                applyUserStyles: { [weak host] in host?.applyUserStyles() },
                applyStreamerMode: { [weak host] in host?.applyStreamerMode() },
            )
        }
    }

    /// Titles the window by its pane: an AppKit window takes no title from
    /// the split view's `navigationTitle`.
    private func titleByPane(_ window: NSWindow) {
        // Set now: the stream's first value arrives a run-loop turn later.
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
