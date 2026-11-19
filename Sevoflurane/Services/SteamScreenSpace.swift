import AppKit

/// Translates between the coordinate system Steam's UI speaks and AppKit's.
///
/// Steam's coordinates start at the primary display's top-left with y growing
/// down (as `window.screenX`/`screenY` do); AppKit's start bottom-left with y
/// growing up. Every `MoveTo`, `GetWindowDimensions` and context-menu
/// placement crosses this seam.
enum SteamScreenSpace {
    /// The top edge of the primary display, the line both conventions mirror
    /// around. `NSScreen.screens[0]` is the menu-bar screen, origin `(0, 0)`.
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
    /// Tested against each display's frame: the box around an L-shaped layout
    /// has corners no display covers.
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
