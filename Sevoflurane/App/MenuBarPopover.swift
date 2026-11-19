import AppKit
import Propofol
import SwiftUI

/// The menu-bar item and the panel it opens. The panel is non-activating, so
/// opening it never takes focus from Steam's window, and it closes when
/// something else takes key.
@MainActor
final class MenuBarPopover: NSObject, NSWindowDelegate {
    private let host: SteamWebHost
    private let supervisor: ClientSupervisor
    private let notifications: SteamNotifications
    private let setup: SetupWindow
    /// The adopted Windows programs the popover lists beside the library.
    let quickLaunch = QuickLaunchStore()
    /// The renderer switch, made with the panel so a session that never opens
    /// the popover never reads the bottle for it.
    private lazy var graphics = GraphicsStore()
    private let presentation = PopoverPresentation()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: PopoverPanel?
    private var escapeMonitor: Any?
    private var refreshLoop: Task<Void, Never>?

    /// When the panel last closed. A click on the status item resigns the
    /// panel's key state before the button's action runs, so a click just after
    /// a close is the second half of that dismissal and must not reopen it.
    private var closedAt = ContinuousClock.now
    /// The menu bar's session for the open popover, which draws the item's
    /// pill.
    private var pillSession: NSObject?
    /// Watches for a click on the item while the popover is up: the session
    /// keeps it from the button, so it arrives only as a global mouse event.
    private var itemClickMonitor: Any?
    /// Runs on every open.
    var onOpen: () -> Void = {}

    init(
        host: SteamWebHost,
        supervisor: ClientSupervisor,
        notifications: SteamNotifications,
        setup: SetupWindow,
    ) {
        self.host = host
        self.supervisor = supervisor
        self.notifications = notifications
        self.setup = setup
        super.init()
        quickLaunch.launchHooks = QuickLaunchStore.LaunchHooks(reporting: host)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.setAccessibilityLabel("Sevoflurane")
        if Pill.isSupported, statusItem.responds(to: Pill.setDelegate) {
            statusItem.perform(Pill.setDelegate, with: self)
        }
        trackIcon()
    }

    /// Draws the glyph and redraws it when the badge changes. One dot for two
    /// reasons (the client needs a hand, or a conversation is waiting); the
    /// popover says which.
    private func trackIcon() {
        withObservationTracking {
            statusItem.button?.image = MenuBarIcon.image(
                badged: supervisor.needsAttention || host.unreadChats > 0,
            )
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.trackIcon() }
            }
        }
    }

    // MARK: - Opening and closing

    @objc
    private func toggle() {
        if panel?.isVisible == true {
            close()
        } else if closedAt.duration(to: .now) > .milliseconds(200) {
            open()
        }
    }

    private func open() {
        // The view's `onAppear` fires only on the first open, usually before
        // Steam's `appStore` is filled, and an empty answer looks "unchanged"
        // to the refresh's guard; so ask on every open (one page evaluation).
        presentation.opened()
        onOpen()
        host.refreshRecentGames()
        quickLaunch.refresh()
        graphics.refresh()
        // Keep asking while the popover stays up, one page evaluation per tick.
        refreshLoop?.cancel()
        refreshLoop = Task(name: "Popover games refresh") { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.host.refreshRecentGames()
                self?.quickLaunch.refresh()
            }
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        // A click opens through a session the menu bar already began; an
        // accessibility press asks for one here. Deferred one turn, out of the
        // button's mouse tracking, which would clear the fallback highlight.
        if pillSession == nil {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard self?.panel?.isVisible == true, self?.pillSession == nil else { return }
                    self?.showsOpenPill(true)
                }
            }
        }
        itemClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfItemClicked() }
        }
        // Escape reaches the panel as a key event no SwiftUI control claims.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    private func close() {
        panel?.orderOut(nil)
        showsOpenPill(false)
        refreshLoop?.cancel()
        refreshLoop = nil
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let itemClickMonitor {
            NSEvent.removeMonitor(itemClickMonitor)
            self.itemClickMonitor = nil
        }
        closedAt = .now
    }

    /// A second click on the item closes the popover, as for a system item.
    private func closeIfItemClicked() {
        guard let item = statusItem.button?.window?.frame,
              item.contains(NSEvent.mouseLocation) else { return }
        close()
    }

    func windowDidResignKey(_: Notification) {
        close()
    }

    /// The pill a system item wears while its popover is up, drawn by the menu
    /// bar out of process through an expanded-interface session (the private
    /// API `MenuBarExtra` rides). On macOS 27, `highlight(_:)` and
    /// `setButtonHighlighted:` leave the pill off.
    private func showsOpenPill(_ isOpen: Bool) {
        guard Pill.isSupported, statusItem.responds(to: Pill.request) else {
            statusItem.button?.highlight(isOpen)
            return
        }
        if isOpen {
            statusItem.perform(Pill.request)
        } else if let session = pillSession {
            // Cleared first: the cancel reports back through the end callback.
            pillSession = nil
            _ = session.perform(Pill.cancel)
        }
    }

    /// The session started and the pill is up. With a delegate set, a click
    /// begins a session instead of sending the button's action, so a session
    /// arriving with the popover down is the click asking for it.
    @objc(statusItem:didBeginExpandedInterfaceSession:)
    private func statusItem(_: NSStatusItem, didBeginExpandedInterfaceSession session: NSObject) {
        pillSession = session
        guard panel?.isVisible != true else { return }
        if closedAt.duration(to: .now) > .milliseconds(200) {
            open()
        } else {
            // The popover closed as this began: the tail of the closing click,
            // or an outlived request.
            showsOpenPill(false)
        }
    }

    /// The menu bar ended the session, and the popover goes with it.
    @objc(statusItemDidEndExpandedInterfaceSession:animated:)
    private func statusItemDidEndExpandedInterfaceSession(_: NSStatusItem, animated _: Bool) {
        pillSession = nil
        if panel?.isVisible == true { close() }
    }

    private enum Pill {
        /// Proven on macOS 27 only: with the delegate set, a click begins a
        /// session in place of the button's action, so where the session
        /// differs the item would stop opening the popover.
        static let isSupported = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
        )
        static let setDelegate = NSSelectorFromString("setExpandedInterfaceDelegate:")
        static let request = NSSelectorFromString("_requestExpandedInterfaceSession")
        static let cancel = NSSelectorFromString("cancel")
    }

    // MARK: - The panel

    private func makePanel() -> PopoverPanel {
        let panel = PopoverPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Theme.popoverWidth, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow

        // The popover's background; the views inside draw cards on it and no
        // surface of their own. Glass rather than an `NSVisualEffectView`,
        // whose vibrancy blurs what is behind into a gray wash.
        let background = NSGlassEffectView()
        background.cornerRadius = Theme.Radius.card

        let content = NSHostingView(
            rootView: MenuBarView(
                host: host, supervisor: supervisor, notifications: notifications,
                quickLaunch: quickLaunch, graphics: graphics, setup: setup,
                presentation: presentation,
            ),
        )
        background.contentView = content

        // The window server cuts the shadow from the composited alpha, and
        // glass fills the whole rectangle; a layer clipped to the card's shape
        // gives the shadow its corners.
        let shape = NSView()
        shape.wantsLayer = true
        shape.layer?.cornerRadius = Theme.Radius.card
        shape.layer?.cornerCurve = .continuous
        shape.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        shape.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: shape.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: shape.trailingAnchor),
            background.topAnchor.constraint(equalTo: shape.topAnchor),
            background.bottomAnchor.constraint(equalTo: shape.bottomAnchor),
        ])
        panel.contentView = shape
        return panel
    }

    /// Hangs the panel under the status item, kept clear of the screen edges.
    private func position(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? .zero
        guard let button = statusItem.button, let itemWindow = button.window else { return }
        let item = itemWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(
            x: item.midX - size.width / 2,
            y: item.minY - Self.gap - size.height,
        )
        if let visible = (itemWindow.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(
                max(origin.x, visible.minX + Self.margin),
                visible.maxX - size.width - Self.margin,
            )
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.invalidateShadow()
    }

    /// The drop below the menu bar, and the margin kept from a screen edge.
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8
}

/// Key without activating: the controls work while the app stays in the
/// background.
private final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}
