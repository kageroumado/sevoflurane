import AppKit

/// The menu-bar glyph: a vaporizer's dial that flows into its outlet — a ring
/// with its pointer at the top right, its rim sweeping down and left into a
/// hose that ends in a rounded foot. One continuous shape, so it reads at
/// menu-bar size, and it resembles nothing else in a menu bar: the shape is
/// learned once and then owned. Drawn programmatically as a template image so
/// it stays sharp at any backing scale and follows the menu bar's tinting.
///
/// The badged variant carries a corner dot — punched out with a cleared disc
/// so it reads at menu-bar size — for health states that need the user
/// (degraded, gave up) and for waiting conversations. A Debug build adds a
/// hammer in the empty top-left corner, so its menu-bar item is told apart
/// from the installed app's beside it.
@MainActor
enum MenuBarIcon {
    static func image(badged: Bool) -> NSImage {
        badged ? badgedImage : plainImage
    }

    private static let plainImage = draw(badged: false)
    private static let badgedImage = draw(badged: true)

    /// The glyph on its 24-unit design grid, y downward; ``draw(badged:)``
    /// scales it to the 18-point image.
    private enum Geometry {
        static let size = NSSize(width: 18, height: 18)
        static let grid: CGFloat = 24
        static let dialCenter = CGPoint(x: 15, y: 8.5)
        static let dialOuterRadius: CGFloat = 6.5
        static let dialInnerRadius: CGFloat = 4.5
        /// Where the hose's upper edge meets the dial's rim, and where the rim
        /// hands over to the hose's lower edge.
        static let rimStart = CGPoint(x: 8.8, y: 10.45)
        static let rimEnd = CGPoint(x: 15, y: 15)
        /// The hose's rounded foot.
        static let footCenter = CGPoint(x: 2.9, y: 20.35)
        static let footRadius: CGFloat = 1.65
        static let pointer = (from: CGPoint(x: 15, y: 6.1), to: CGPoint(x: 15, y: 10.9))
        static let pointerStroke: CGFloat = 2.05
    }

    private static func draw(badged: Bool) -> NSImage {
        let image = NSImage(size: Geometry.size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.scaleBy(x: Geometry.size.width / Geometry.grid, y: Geometry.size.height / Geometry.grid)
            context.setFillColor(.black)
            context.setStrokeColor(.black)
            context.addPath(body)
            context.fillPath(using: .evenOdd)
            context.setLineWidth(Geometry.pointerStroke)
            context.setLineCap(.round)
            context.move(to: Geometry.pointer.from)
            context.addLine(to: Geometry.pointer.to)
            context.strokePath()
            context.restoreGState()
            if badged { drawBadge() }
            #if DEBUG
                drawDebugMark()
            #endif
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The dial's rim and the hose as one outline, with the dial's opening as
    /// a second subpath for the even-odd fill to leave clear.
    private static var body: CGPath {
        let path = CGMutablePath()
        let top = Geometry.footCenter.y - Geometry.footRadius
        let bottom = Geometry.footCenter.y + Geometry.footRadius
        path.move(to: CGPoint(x: Geometry.footCenter.x, y: top))
        path.addLine(to: CGPoint(x: 5.3, y: top))
        path.addCurve(
            to: CGPoint(x: 7.8, y: 14),
            control1: CGPoint(x: 6.8, y: top), control2: CGPoint(x: 7.2, y: 16.5),
        )
        path.addLine(to: Geometry.rimStart)
        // The long way round the dial, from the hose's upper edge to its lower one.
        path.addArc(
            center: Geometry.dialCenter, radius: Geometry.dialOuterRadius,
            startAngle: angle(of: Geometry.rimStart), endAngle: angle(of: Geometry.rimEnd),
            clockwise: false,
        )
        path.addCurve(
            to: CGPoint(x: 10.7, y: 19.1),
            control1: CGPoint(x: 12.7, y: 15.4), control2: CGPoint(x: 11.4, y: 17),
        )
        path.addCurve(
            to: CGPoint(x: 5.8, y: bottom),
            control1: CGPoint(x: 10.1, y: 21.2), control2: CGPoint(x: 8.5, y: bottom),
        )
        path.addLine(to: CGPoint(x: Geometry.footCenter.x, y: bottom))
        path.addArc(
            center: Geometry.footCenter, radius: Geometry.footRadius,
            startAngle: .pi / 2, endAngle: .pi * 3 / 2, clockwise: false,
        )
        path.closeSubpath()
        path.addEllipse(in: CGRect(
            x: Geometry.dialCenter.x - Geometry.dialInnerRadius,
            y: Geometry.dialCenter.y - Geometry.dialInnerRadius,
            width: Geometry.dialInnerRadius * 2, height: Geometry.dialInnerRadius * 2,
        ))
        return path
    }

    private static func angle(of point: CGPoint) -> CGFloat {
        atan2(point.y - Geometry.dialCenter.y, point.x - Geometry.dialCenter.x)
    }

    private static func drawBadge() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: 12.2, y: 12.2, width: 6.4, height: 6.4))
        context.setBlendMode(.normal)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 13.4, y: 13.4, width: 4.0, height: 4.0)).fill()
    }

    #if DEBUG
        /// Clear of the glyph without a halo: the dial's rim starts at x 6.4.
        private static func drawDebugMark() {
            let configuration = NSImage.SymbolConfiguration(pointSize: 5, weight: .bold)
            guard let hammer = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            hammer.draw(
                in: NSRect(origin: CGPoint(x: 0.2, y: 0.2), size: hammer.size),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil,
            )
        }
    #endif
}
