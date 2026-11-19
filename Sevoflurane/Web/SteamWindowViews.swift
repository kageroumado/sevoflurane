import AppKit
import WebKit

/// A borderless panel that can become key: Steam's menus dismiss themselves
/// on losing focus, which a window that never becomes key never does.
final class SteamPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        hidesOnDeactivate = true
        worksWhenModal = true
        // A non-key panel otherwise gets no mouse-moved events for hover.
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool {
        true
    }
}

/// The window's content view: it hands drags in the page's reported
/// `-webkit-app-region: drag` rectangles to AppKit (WebKit ignores the
/// property), and relays hover to the page.
final class SteamContentView: NSView {
    weak var owner: SteamWindow?

    /// Relays native hover into the web view. WKWebView's tracking is
    /// `NSTrackingActiveInKeyWindow`, and a non-key panel's page would see no
    /// cursor; this `.activeAlways` area's genuine events go to WebKit's own
    /// event handler.
    var relaysHover = false {
        didSet { updateTrackingAreas() }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        super.updateTrackingAreas()
        guard relaysHover else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil,
        ))
    }

    /// Off once the window is key, where forwarding would double every event.
    private var shouldRelay: Bool {
        relaysHover && window?.isKeyWindow != true
    }

    /// WebKit's private entry points into its tracking-area pipeline. Never
    /// call `mouseEntered(with:)` on the web view: NSResponder forwards it up
    /// to this view, which recurses until the stack dies.
    private static let simulateEnter = Selector(("_simulateMouseEnter:"))
    private static let simulateMove = Selector(("_simulateMouseMove:"))
    private static let simulateExit = Selector(("_simulateMouseExit:"))

    private func relay(_ selector: Selector, _ event: NSEvent) {
        guard shouldRelay, let webView = owner?.webView,
              webView.responds(to: selector) else { return }
        webView.perform(selector, with: event)
    }

    /// Throttles the React relay to ~30Hz of evaluate calls.
    private var lastReactRelay = ContinuousClock.Instant.now

    private func relayReact(_ event: NSEvent, throttled: Bool) {
        guard shouldRelay, let owner else { return }
        if throttled {
            let now = ContinuousClock.Instant.now
            guard now - lastReactRelay > .milliseconds(33) else { return }
            lastReactRelay = now
        }
        owner.relayReactHover(
            contentPoint: convert(event.locationInWindow, from: nil),
            contentHeight: bounds.height,
        )
    }

    override func mouseEntered(with event: NSEvent) {
        relay(Self.simulateEnter, event)
        relayReact(event, throttled: false)
    }

    override func mouseMoved(with event: NSEvent) {
        relay(Self.simulateMove, event)
        relayReact(event, throttled: true)
    }

    override func mouseExited(with event: NSEvent) {
        relay(Self.simulateExit, event)
        if shouldRelay { owner?.relayReactHoverExit() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let owner, owner.isDragRegion(
            contentPoint: local,
            contentHeight: bounds.height,
        ) {
            return self
        }
        return super.hitTest(point)
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }
}
