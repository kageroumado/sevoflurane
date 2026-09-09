import AppKit

/// Translates between the coordinate system Steam's UI speaks and AppKit's.
///
/// Steam was written against Windows and CEF: screen coordinates start at the
/// top-left of the primary display and y grows downward, which is also what
/// `window.screenX` / `window.screenY` report in a browser. AppKit puts the
/// origin at the bottom-left with y growing up. Every `MoveTo`, every
/// `GetWindowDimensions`, and every context-menu placement crosses this seam,
/// so it lives in one place.
enum SteamScreenSpace {
    /// The top edge of the primary display, which is the line both conventions
    /// are mirrored around. `NSScreen.screens[0]` is the screen whose origin is
    /// `(0, 0)`; the menu-bar screen, and the one Steam measures from.
    static var flipLine: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// A window frame expressed the way Steam expects to read it back.
    static func steamRect(from frame: NSRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: flipLine - frame.maxY,
            width: frame.width,
            height: frame.height,
        )
    }

    /// An AppKit frame origin for a Steam top-left point and a known size.
    static func appKitOrigin(
        steamX: CGFloat,
        steamY: CGFloat,
        size: CGSize,
    ) -> CGPoint {
        CGPoint(x: steamX, y: flipLine - steamY - size.height)
    }

    /// Whether a frame lands anywhere a person could see it.
    ///
    /// Tested against each display's own frame rather than the box around all
    /// of them: an L-shaped layout — a portrait display beside a wide one —
    /// leaves corners inside that box which no display covers, and a window
    /// there is as lost as one at (−20000, −20000).
    static func isOnSomeScreen(
        _ frame: CGRect,
        screens: [CGRect] = NSScreen.screens.map(\.frame),
    ) -> Bool {
        screens.contains { $0.intersects(frame) }
    }

    /// The mouse location in Steam's convention.
    static var steamMouseLocation: CGPoint {
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: flipLine - point.y)
    }
}
