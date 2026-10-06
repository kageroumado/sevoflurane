import AppKit
import SwiftUI

/// The setup assistant's window, from the moment it opens until its finish
/// button runs.
///
/// Closing the window is putting setup aside, not abandoning it: the window
/// and the wizard's place in it are kept, and the popover, the Dock icon and
/// ``AppDelegate``'s reopen all bring the same window back. Until the finish,
/// the client's windows are held behind it (``SteamWebHost/holdWindows()``),
/// so this window is the only way forward and has to stay reachable.
@MainActor
@Observable
final class SetupWindow {
    /// Whether setup has been started and not finished — on screen or
    /// closed. The popover shows the way back into it instead of Steam's
    /// controls while this is true.
    private(set) var isUnfinished = false

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var closeObserver: (any NSObjectProtocol)?

    /// Opens the wizard in a new window, replacing any earlier one.
    func present(_ view: SetupView) {
        finish()
        var view = view
        view.resizeWindow = { [weak self] tall in self?.resize(tall: tall) }
        let controller = NSHostingController(rootView: view)
        // The window's size is this controller's to set: ``SetupMetrics``
        // for the flow, taller only for Apple's sign-in page. Left to the
        // hosting controller, a step whose content asks for more grows the
        // window mid-flow and it never shrinks back.
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
        isUnfinished = true
        window.center()
        show()
    }

    /// Grows the window to ``SetupMetrics/tallWindowHeight`` (within the
    /// screen) or returns it to ``SetupMetrics/windowSize``, keeping its top
    /// edge where it is unless the screen's bottom pushes it up.
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

    /// Brings the wizard back where it was left. Answers whether there was
    /// one to bring back.
    @discardableResult
    func show() -> Bool {
        guard let window else { return false }
        // The wizard is the app's only window during a first run, and an
        // accessory app's window has no Dock tile to say anything is going on.
        ActivationPolicy.becomeRegular()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }

    /// The wizard's finish: the window goes for good.
    ///
    /// The Dock tile stays through it. The finish button promises Steam's
    /// window — sign-in or the library — and that window arrives a moment
    /// later; receding now would drop the tile and put it straight back.
    func finish() {
        guard let window else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        self.window = nil
        isUnfinished = false
        ActivationPolicy.becomeRegular(forAWindowWithin: ActivationPolicy.graceForAPromisedWindow)
        window.close()
    }
}
