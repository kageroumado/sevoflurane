import AppKit
import SwiftUI

/// The setup assistant's window, until its finish button runs. Closing it
/// keeps the assistant's place, and the popover, the Dock icon and
/// ``AppDelegate``'s reopen bring it back; it must stay reachable, since the
/// client's windows are held until the finish (``SteamWebHost/holdWindows()``).
@MainActor
@Observable
final class SetupWindow {
    /// The assistant that has started and not finished, on screen or closed.
    /// The popover reads how its work stands from it.
    private(set) var store: SetupStore?

    /// Whether setup has started and not finished.
    var isUnfinished: Bool {
        store != nil || isStagedUnfinished
    }

    private var isStagedUnfinished = false
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var closeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var heightFollower: Task<Void, Never>?

    /// Opens the assistant in a new window, replacing any earlier one.
    func present(_ store: SetupStore) {
        finish()
        let controller = NSHostingController(rootView: SetupView(store: store))
        // Sized here from ``SetupMetrics``: left to the hosting controller, a
        // tall screen grows the window and it never shrinks back.
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(SetupMetrics.windowSize)
        window.contentMinSize = SetupMetrics.windowSize
        window.contentMaxSize = SetupMetrics.windowSize
        window.title = String(localized: "Welcome to Sevoflurane")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main,
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                EventLog.shared.log(.setup, "setup window closed — the popover and the Dock icon reopen it")
                ActivationPolicy.recedeIfLastWindow(closing: window)
            }
        }
        self.window = window
        self.store = store
        heightFollower = Task(name: "Follow the assistant's height") { [weak self] in
            for await isTall in Observations({ store.wantsTallWindow }) {
                self?.resize(tall: isTall)
            }
        }
        window.center()
        show()
    }

    /// Switches between ``SetupMetrics/tallWindowHeight`` (within the screen)
    /// and ``SetupMetrics/windowSize``, keeping the top edge in place.
    private func resize(tall: Bool) {
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        var size = SetupMetrics.windowSize
        if tall, let visible {
            size.height = max(size.height, min(SetupMetrics.tallWindowHeight, visible.height - 40))
        }
        guard window.contentRect(forFrameRect: window.frame).size != size else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        if let visible, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setFrame(
            frame, display: true,
            animate: window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        )
    }

    #if DEBUG
        /// Reads as a setup under way with no window behind it, so the gallery
        /// can draw the popover that leads back to one; `store` is the
        /// assistant whose work the popover then shows.
        func stageUnfinished(_ store: SetupStore? = nil) {
            isStagedUnfinished = true
            self.store = store
        }
    #endif

    /// Brings the assistant back; answers whether there was one.
    @discardableResult
    func show() -> Bool {
        guard let window else { return false }
        // An accessory app's only window would have no Dock tile.
        ActivationPolicy.becomeRegular()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }

    /// Closes the assistant for good. The Dock tile stays: Steam's promised
    /// window arrives a moment later.
    func finish() {
        guard let window else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        heightFollower?.cancel()
        heightFollower = nil
        self.window = nil
        store = nil
        ActivationPolicy.becomeRegular(forAWindowWithin: ActivationPolicy.graceForAPromisedWindow)
        window.close()
    }
}
