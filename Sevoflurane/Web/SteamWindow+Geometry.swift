import AppKit

extension SteamWindow {
    /// Puts a freshly built window where Steam asked for it, or where the
    /// user last left it.
    func place(_ window: NSWindow) {
        if role == .login {
            // Steam centers its login window against its own screen model,
            // which lands bottom-left here. A sign-in dialog belongs in the
            // middle of the screen, wherever Steam thinks it put it.
            window.center()
        } else if role == .dialog {
            centerOnDesktop(window)
        } else if let requestedOrigin {
            window.setFrameOrigin(
                SteamScreenSpace.appKitOrigin(
                    steamX: requestedOrigin.x,
                    steamY: requestedOrigin.y,
                    size: window.frame.size,
                ),
            )
        } else if role == .desktop, !window.setFrameUsingName(Self.desktopFrameName) {
            // Centered only the first time: the desktop window is torn down
            // and rebuilt on every close, and a window that forgets where the
            // user put it is a window the user has to place again every time.
            window.center()
        }
        centerIfOffScreen(window, placedBy: "the frame it was built with")
    }

    /// Brings a window back onto a display when the frame it was given lands
    /// on none. A frame saved on a display that has since been unplugged, and
    /// a `MoveTo` computed against Steam's own screen model, both produce a
    /// window that exists and that nobody can reach — and the desktop
    /// window's frame is autosaved, so one bad placement persists across
    /// every later launch.
    private func centerIfOffScreen(_ window: NSWindow, placedBy source: String) {
        guard role.needsAReachableFrame,
              !SteamScreenSpace.isOnSomeScreen(window.frame) else { return }
        EventLog.shared.log(
            .window,
            "\(name): \(source) put it at \(NSStringFromRect(window.frame)), "
                + "which is on no display — centering instead",
        )
        window.center()
    }

    /// A dialog sits in the middle of the desktop window when there is one on
    /// screen, and in the middle of the screen otherwise.
    private func centerOnDesktop(_ window: NSWindow) {
        guard let parent = host?.desktop?.nsWindow, parent.isVisible else {
            window.center()
            return
        }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: parent.frame.midX - size.width / 2,
            y: parent.frame.midY - size.height / 2,
        ))
    }

    /// Makes a dialog the desktop window's child, so it rides above it and
    /// moves with it.
    func attachDialogToDesktop() {
        guard role == .dialog, let window, window.parent == nil,
              let parent = host?.desktop?.nsWindow, parent.isVisible else { return }
        parent.addChildWindow(window, ordered: .above)
    }

    /// Keeps a toast's page alive without ever putting it on screen: it is
    /// invisible, click-through, out of every window list, and parked off
    /// every display. WebKit schedules it because it lives in a window, which
    /// is all its dismissal timer needs.
    func park(_ window: NSWindow) {
        window.setFrameOrigin(Self.toastParkOrigin)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.orderBack(nil)
    }

    /// Where a toast's page is kept while it renders: off every screen, the
    /// same park the context page uses.
    private static let toastParkOrigin = CGPoint(x: -20_000, y: -20_000)

    /// Whether this window's position is the app's to decide rather than
    /// Steam's.
    ///
    /// A toast is parked off every display for its whole life, so a move is
    /// meaningless — and Steam issues them per animation frame while the
    /// toast slides in, every one of them carrying `NaN` for the x it
    /// computes against a screen edge it cannot measure here. Refusing them
    /// by role rather than by value keeps the non-finite guard for the case
    /// it was written for (a menu against a window that has gone) instead of
    /// making it a log of an animation.
    var isParked: Bool {
        role == .toast
    }

    /// The largest side AppKit gives a window; a larger request gets this.
    nonisolated static let maximumSide: CGFloat = 10000
    /// The farthest from the primary display's origin a window is placed,
    /// with room for a window parked far off-screen.
    nonisolated static let maximumOffset: CGFloat = 1_000_000

    /// A size Steam asked for, held to what a window can be.
    nonisolated static func clampedSize(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: min(max(width, 0), maximumSide), height: min(max(height, 0), maximumSide))
    }

    /// One coordinate Steam asked for, held to ``maximumOffset``.
    nonisolated static func clampedOffset(_ value: CGFloat) -> CGFloat {
        min(max(value, -maximumOffset), maximumOffset)
    }

    func moveTo(x: CGFloat, y: CGFloat) {
        requestedOrigin = CGPoint(x: x, y: y)
        guard let window else { return }
        window.setFrameOrigin(
            SteamScreenSpace.appKitOrigin(
                steamX: x,
                steamY: y,
                size: window.frame.size,
            ),
        )
        centerIfOffScreen(window, placedBy: "Steam's MoveTo(\(Int(x)), \(Int(y)))")
    }

    func resizeTo(width: CGFloat, height: CGFloat) {
        requestedSize = CGSize(width: width, height: height)
        guard let window else { return }
        // Resizing an AppKit window grows it downward from its origin; Steam
        // expects the top-left to stay put, as it does on Windows.
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(requestedSize)
        window.setFrameTopLeftPoint(topLeft)
        if role == .dialog { centerOnDesktop(window) }
    }

    /// Places a menu against the window that opened it.
    ///
    /// Steam computes the offset as `menuLeft - parentWindow.screenX`, so the
    /// coordinates are relative to the parent's top-left in screen space, and
    /// the first argument is the parent's restore-details token.
    func positionRelative(
        toWindowNamed parentName: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
    ) {
        realize()
        guard let window else { return }
        let parent = host?.steamOrigin(ofWindowNamed: parentName) ?? .zero
        requestedSize = CGSize(width: width, height: height)
        window.setContentSize(requestedSize)
        window.setFrameOrigin(
            SteamScreenSpace.appKitOrigin(
                steamX: parent.x + x,
                steamY: parent.y + y,
                size: window.frame.size,
            ),
        )
    }

    /// This window's top-left in the coordinates Steam measures in.
    var steamOrigin: CGPoint {
        guard let window else { return requestedOrigin ?? .zero }
        let rect = SteamScreenSpace.steamRect(from: window.frame)
        return CGPoint(x: rect.minX, y: rect.minY)
    }

    /// The display this window is measured against. A Mac with no display
    /// attached has no screen at all, and Steam is answered with a nominal
    /// 1920×1080 one.
    private var measuredScreen: (frame: NSRect, visible: NSRect, scale: CGFloat) {
        if let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first {
            return (screen.frame, screen.visibleFrame, screen.backingScaleFactor)
        }
        let nominal = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        return (nominal, nominal, 1)
    }

    /// This window's geometry and the display it is on, in Steam's
    /// coordinates. The screen's own origin travels with its size, the way
    /// ``monitorDimensions()`` reports `nAvailableLeft`: a display at a
    /// negative x holds windows at a negative x, and a screen described by
    /// size alone cannot say so.
    func dimensions() -> [String: Any] {
        let screenRect = SteamScreenSpace.steamRect(from: measuredScreen.frame)
        var answer: [String: Any] = [
            "screenLeft": screenRect.minX,
            "screenTop": screenRect.minY,
            "screenWidth": screenRect.width,
            "screenHeight": screenRect.height,
        ]
        guard let window else {
            answer["x"] = requestedOrigin?.x ?? 0
            answer["y"] = requestedOrigin?.y ?? 0
            answer["width"] = requestedSize.width
            answer["height"] = requestedSize.height
            return answer
        }
        let rect = SteamScreenSpace.steamRect(from: window.frame)
        answer["x"] = rect.minX
        answer["y"] = rect.minY
        answer["width"] = window.contentLayoutRect.width
        answer["height"] = window.contentLayoutRect.height
        return answer
    }

    func monitorDimensions() -> [String: Any] {
        let screen = measuredScreen
        let visible = screen.visible
        return [
            "flHorizontalScale": screen.scale,
            "flVerticalScale": screen.scale,
            "nFullWidth": screen.frame.width,
            "nFullHeight": screen.frame.height,
            "nAvailableWidth": visible.width,
            "nAvailableHeight": visible.height,
            "nAvailableLeft": visible.minX,
            "nAvailableTop": SteamScreenSpace.flipLine - visible.maxY,
        ]
    }
}
