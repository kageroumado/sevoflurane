import AppKit

/// The menu-bar glyph: the app icon's concentration dial — the vaporizer's
/// bezel ring, its tick marks, and the knob's handle — reduced to what 18
/// points can carry: a ring, a handle turned to a setting, and the scale's
/// ticks across from it. Drawn programmatically as a template image so it
/// stays sharp at any backing scale and follows the menu bar's light/dark
/// tinting.
///
/// The badged variant carries a corner dot — punched out of the ring with a
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
        static let center = NSPoint(x: 9, y: 9)
        /// The bezel ring.
        static let ringRadius: CGFloat = 7.6
        static let ringStroke: CGFloat = 1.3
        /// Three scale ticks along the bottom arc, opposite the handle. A
        /// symmetric ring of ticks around a vertical pill read as an insect
        /// (legs around a body); a handle turned to a setting with the scale
        /// across from it reads as a dial.
        static let tickAngles: [CGFloat] = [135, 180, 225].map { $0 * .pi / 180 }
        static let tickOuterRadius: CGFloat = 5.7
        static let tickLength: CGFloat = 1.4
        static let tickStroke: CGFloat = 1.0
        /// The knob's handle: a pill through the center, turned to a setting
        /// (up-left), with a short tail past the center like the icon's bar.
        static let handleAngle: CGFloat = 330 * .pi / 180
        static let handleStroke: CGFloat = 2.6
        static let handleInner: CGFloat = -2.2
        static let handleOuter: CGFloat = 3.4
    }

    private static func draw(badged: Bool) -> NSImage {
        let image = NSImage(size: Geometry.size, flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            drawRing()
            drawTicks()
            drawHandle()
            if badged { drawBadge() }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawRing() {
        let radius = Geometry.ringRadius
        let ring = NSBezierPath(ovalIn: NSRect(
            x: Geometry.center.x - radius, y: Geometry.center.y - radius,
            width: radius * 2, height: radius * 2,
        ))
        ring.lineWidth = Geometry.ringStroke
        ring.stroke()
    }

    private static func drawTicks() {
        let ticks = NSBezierPath()
        ticks.lineWidth = Geometry.tickStroke
        ticks.lineCapStyle = .round
        for angle in Geometry.tickAngles {
            let outer = Geometry.tickOuterRadius
            let inner = outer - Geometry.tickLength
            let direction = NSPoint(x: sin(angle), y: -cos(angle))
            ticks.move(to: NSPoint(
                x: Geometry.center.x + direction.x * outer,
                y: Geometry.center.y + direction.y * outer,
            ))
            ticks.line(to: NSPoint(
                x: Geometry.center.x + direction.x * inner,
                y: Geometry.center.y + direction.y * inner,
            ))
        }
        ticks.stroke()
    }

    private static func drawHandle() {
        let direction = NSPoint(x: sin(Geometry.handleAngle), y: -cos(Geometry.handleAngle))
        let handle = NSBezierPath()
        handle.lineWidth = Geometry.handleStroke
        handle.lineCapStyle = .round
        handle.move(to: NSPoint(
            x: Geometry.center.x + direction.x * Geometry.handleInner,
            y: Geometry.center.y + direction.y * Geometry.handleInner,
        ))
        handle.line(to: NSPoint(
            x: Geometry.center.x + direction.x * Geometry.handleOuter,
            y: Geometry.center.y + direction.y * Geometry.handleOuter,
        ))
        handle.stroke()
    }

    private static func drawBadge() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: 11.0, y: 11.0, width: 7.0, height: 7.0))
        context.setBlendMode(.normal)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 12.4, y: 12.4, width: 4.2, height: 4.2)).fill()
    }
}
