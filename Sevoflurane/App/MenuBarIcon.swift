import AppKit

/// The menu-bar glyph: the app icon's vapor waves inside a circle, echoing
/// the shape of Steam's own tray icon so the item reads as "Steam" at a
/// glance. Drawn programmatically as a template image so it stays sharp at
/// any backing scale and follows the menu bar's light/dark tinting.
///
/// The badged variant carries a corner dot — punched out of the circle with
/// a cleared ring so it reads at menu-bar size — for health states that
/// need the user (degraded, gave up).
@MainActor
enum MenuBarIcon {
    static func image(badged: Bool) -> NSImage {
        badged ? badgedImage : plainImage
    }

    private static let plainImage = draw(badged: false)
    private static let badgedImage = draw(badged: true)

    private static func draw(badged: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()

            let circle = NSBezierPath(
                ovalIn: NSRect(x: 1.1, y: 1.1, width: 15.8, height: 15.8),
            )
            circle.lineWidth = 1.4
            circle.stroke()

            /// Same one-period wave as the app icon's strokes, widest at the
            /// bottom, drifting slightly as it rises.
            func wave(
                centerX: CGFloat,
                y: CGFloat,
                width: CGFloat,
                amplitude: CGFloat,
                stroke: CGFloat,
            ) {
                let x0 = centerX - width / 2
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x0, y: y))
                path.curve(
                    to: NSPoint(x: x0 + width * 0.5, y: y),
                    controlPoint1: NSPoint(x: x0 + width * 0.16, y: y - amplitude),
                    controlPoint2: NSPoint(x: x0 + width * 0.34, y: y - amplitude),
                )
                path.curve(
                    to: NSPoint(x: x0 + width, y: y),
                    controlPoint1: NSPoint(x: x0 + width * 0.66, y: y + amplitude),
                    controlPoint2: NSPoint(x: x0 + width * 0.84, y: y + amplitude),
                )
                path.lineWidth = stroke
                path.lineCapStyle = .round
                path.stroke()
            }
            wave(centerX: 9.4, y: 5.6, width: 7.6, amplitude: 1.2, stroke: 1.5)
            wave(centerX: 9.1, y: 9.0, width: 8.8, amplitude: 1.3, stroke: 1.6)
            wave(centerX: 8.8, y: 12.4, width: 8.2, amplitude: 1.3, stroke: 1.7)

            if badged, let context = NSGraphicsContext.current?.cgContext {
                context.setBlendMode(.clear)
                context.fillEllipse(in: CGRect(x: 11.0, y: 11.0, width: 7.0, height: 7.0))
                context.setBlendMode(.normal)
                NSColor.black.setFill()
                NSBezierPath(
                    ovalIn: NSRect(x: 12.4, y: 12.4, width: 4.2, height: 4.2),
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
