import AppKit
import WebKit

/// A panel that can take key focus while borderless.
///
/// Steam's menus dismiss themselves when their window loses focus, which only
/// happens if it could hold focus in the first place — a plain borderless
/// `NSWindow` never becomes key, so every menu would stay on screen forever.
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
        // Steam's hover menus track the cursor inside their own page; without
        // this a never-key panel starves its web view of mouse-moved events.
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool {
        true
    }
}

/// The window's content view, which decides where the window may be dragged
/// and, for panels, tracks the cursor on the page's behalf.
///
/// WebKit does not act on `-webkit-app-region: drag`, so the page reports those
/// regions and the hit test hands the drag back to AppKit for exactly those
/// rectangles. Everywhere else the click belongs to the page.
final class SteamContentView: NSView {
    weak var owner: SteamWindow?

    /// Panels relay native hover into the web view's own responder methods.
    ///
    /// WKWebView's mouse tracking is `NSTrackingActiveInKeyWindow` and a menu
    /// panel opens without key status, so the page would see no cursor at all
    /// until a click makes the panel key — no `:hover`, no highlight, and
    /// Steam's own dismiss-on-mouse-out never arms. This `.activeAlways` area
    /// generates the events WKWebView's area would have, and forwarding the
    /// genuine `NSEvent`s drives the full native pipeline (WebKit passes
    /// foreign-tracking-area events straight to its event handler).
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

    /// Once the panel is key (after a click), WKWebView's own tracking is
    /// live and forwarding would double every event.
    private var shouldRelay: Bool {
        relaysHover && window?.isKeyWindow != true
    }

    /// WKWebView implements no public mouse responder selectors — calling
    /// `mouseEntered(with:)` on it falls through NSResponder's default, which
    /// forwards up the chain to this very view and recurses until the stack
    /// dies. These private selectors are WebKit's own entry points into the
    /// same event pipeline its tracking area would use.
    private static let simulateEnter = Selector(("_simulateMouseEnter:"))
    private static let simulateMove = Selector(("_simulateMouseMove:"))
    private static let simulateExit = Selector(("_simulateMouseExit:"))

    private func relay(_ selector: Selector, _ event: NSEvent) {
        guard shouldRelay, let webView = owner?.webView,
              webView.responds(to: selector) else { return }
        webView.perform(selector, with: event)
    }

    /// ~30Hz is plenty for hover, and every native move would flood the page
    /// with evaluate calls.
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
