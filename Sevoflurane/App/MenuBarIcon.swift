import AppKit

/// The menu-bar glyph: the app icon's vaporizer reduced to its outline — the
/// dial ring sitting above the body, a gap of clear bar between them, and the
/// hose leaving to the left. It resembles nothing else in a menu bar, which is
/// the point: the shape is learned once, from the app icon, and then owned.
/// Drawn programmatically as a template image so it stays sharp at any
/// backing scale and follows the menu bar's light/dark tinting.
///
/// The badged variant carries a corner dot — punched out of the body with a
/// cleared disc so it reads at menu-bar size — for health states that need
/// the user (degraded, gave up) and for waiting conversations.
@MainActor
enum MenuBarIcon {
    static func image(badged: Bool) -> NSImage {
        badged ? badgedImage : plainImage
    }

    private static let plainImage = draw(badged: false)
    private static let badgedImage = draw(badged: true)

    private enum Geometry {
        static let size = NSSize(width: 18, height: 18)
        /// The dial: a ring above the body.
        static let dialCenter = NSPoint(x: 11.0, y: 5.6)
        static let dialRadius: CGFloat = 3.7
        static let dialStroke: CGFloat = 1.8
        /// Clear bar between the ring's outer edge and the body, so the dial
        /// reads as a separate part rather than a bump on the body.
        static let dialGap: CGFloat = 1.3
        /// The body: a rounded block under the dial.
        static let body = NSRect(x: 6.4, y: 7.6, width: 9.2, height: 9.8)
        static let bodyCorner: CGFloat = 2.2
        /// The hose: a rounded stub leaving the body to the left.
        static let hoseY: CGFloat = 13.6
        static let hoseEnd: CGFloat = 2.8
        static let hoseStroke: CGFloat = 2.4
    }

    private static func draw(badged: Bool) -> NSImage {
        let image = NSImage(size: Geometry.size, flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            drawBody()
            clearDialGap()
            drawDial()
            drawHose()
            if badged { drawBadge() }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawBody() {
        NSBezierPath(
            roundedRect: Geometry.body,
            xRadius: Geometry.bodyCorner, yRadius: Geometry.bodyCorner,
        ).fill()
    }

    private static func clearDialGap() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = Geometry.dialRadius + Geometry.dialStroke / 2 + Geometry.dialGap
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(
            x: Geometry.dialCenter.x - radius, y: Geometry.dialCenter.y - radius,
            width: radius * 2, height: radius * 2,
        ))
        context.setBlendMode(.normal)
    }

    private static func drawDial() {
        let radius = Geometry.dialRadius
        let ring = NSBezierPath(ovalIn: NSRect(
            x: Geometry.dialCenter.x - radius, y: Geometry.dialCenter.y - radius,
            width: radius * 2, height: radius * 2,
        ))
        ring.lineWidth = Geometry.dialStroke
        ring.stroke()
    }

    private static func drawHose() {
        let hose = NSBezierPath()
        hose.lineWidth = Geometry.hoseStroke
        hose.lineCapStyle = .round
        hose.move(to: NSPoint(x: Geometry.body.minX + 0.5, y: Geometry.hoseY))
        hose.line(to: NSPoint(x: Geometry.hoseEnd, y: Geometry.hoseY))
        hose.stroke()
    }

    private static func drawBadge() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: 12.2, y: 12.2, width: 6.4, height: 6.4))
        context.setBlendMode(.normal)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 13.4, y: 13.4, width: 4.0, height: 4.0)).fill()
    }
}
