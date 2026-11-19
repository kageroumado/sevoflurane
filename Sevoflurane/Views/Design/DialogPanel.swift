import AppKit
import SwiftUI

/// A floating panel dressed as a macOS alert: no title bar to read, no window
/// buttons, content up to its top edge. Its own buttons end it, it moves by
/// its background, and Escape does what a close button would have: asks the
/// delegate's `windowShouldClose`, which each prompt answers with its own
/// "not now".
///
/// A menu-bar agent has no window to hang a sheet on, so its questions come
/// up in one of these.
@MainActor
final class DialogPanel: NSPanel {
    convenience init(size: NSSize, title: String) {
        self.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        // Kept for VoiceOver and the Window menu.
        self.title = title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovableByWindowBackground = true
        isFloatingPanel = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    /// Shows `view` at its own size, centered and in front: the app has no
    /// activation of its own, so the panel would otherwise open behind
    /// whatever the person was in.
    func show(_ view: some View) {
        let hosting = NSHostingView(rootView: view)
        // The hidden title bar reserves no room.
        hosting.safeAreaRegions = []
        let fallback = frame.size
        contentView = hosting
        setContentSize(hosting.fittingSize == .zero ? fallback : hosting.fittingSize)
        center()
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    /// Takes the panel off screen and lets go of its view.
    func dismiss() {
        orderOut(nil)
        contentView = nil
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_: Any?) {
        if delegate?.windowShouldClose?(self) ?? true { dismiss() }
    }
}
