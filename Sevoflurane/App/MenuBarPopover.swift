import AppKit
import Propofol
import SwiftUI

/// The menu-bar item and the panel it opens — what `MenuBarExtra(.window)`
/// gave the app before it moved to the AppKit lifecycle (`main.swift`).
///
/// The panel is a non-activating window so opening the popover never takes
/// focus from Steam's own window, and it dismisses itself the moment
/// something else takes key — the behavior every menu-bar popover has.
@MainActor
final class MenuBarPopover: NSObject, NSWindowDelegate {
    private let host: SteamWebHost
    private let supervisor: ClientSupervisor
    private let notifications: SteamNotifications
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: PopoverPanel?
    private var escapeMonitor: Any?

    /// When the panel last closed. A click on the status item while the
    /// popover is open resigns the panel's key state *before* the button's
    /// action runs, so by the time the toggle asks, the popover it should be
    /// closing is already gone — and it would reopen it. Clicks that land in
    /// that window are the second half of a dismissal, not a request.
    private var closedAt = ContinuousClock.now

    init(
        host: SteamWebHost,
        supervisor: ClientSupervisor,
        notifications: SteamNotifications,
    ) {
        self.host = host
        self.supervisor = supervisor
        self.notifications = notifications
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.setAccessibilityLabel("Sevoflurane")
        trackIcon()
    }

    /// Draws the glyph, and redraws it whenever what it has to say changes —
    /// the badge is the only thing the item says on its own.
    ///
    /// One dot, two reasons: the client needs a hand, or a conversation is
    /// waiting. They do not compete, because the dot means the same thing
    /// either way — open the popover, something is in it — and the popover
    /// says which. A second badge for the second reason would be two marks on
    /// an 18-point glyph saying one thing.
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
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        // Escape reaches the panel as a key event no SwiftUI control claims.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    private func close() {
        panel?.orderOut(nil)
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        closedAt = .now
    }

    func windowDidResignKey(_: Notification) {
        close()
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

        // The popover's own background: the view hierarchy inside draws cards
        // on top of it and never a backing surface of its own.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.Radius.card
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true

        let content = NSHostingView(
            rootView: MenuBarView(
                host: host, supervisor: supervisor, notifications: notifications,
            ),
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        panel.contentView = background
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
    }

    /// The drop below the menu bar, and the least the panel keeps from a
    /// screen edge — both the platform's, measured against the popover
    /// `MenuBarExtra` used to draw.
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8
}

/// Key without activating: the popover's controls work while the app itself
/// stays in the background, which is where a menu-bar app belongs.
private final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}
