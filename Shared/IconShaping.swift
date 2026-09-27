import CoreGraphics
import Foundation
import ImageIO

/// Draws a Windows program's icon the way macOS draws an app's: a neutral
/// platter in the system icon shape, with the program's own artwork resting
/// on top of it.
///
/// A Windows icon is a bare square raster, and a bare square beside the
/// rounded tiles of every other app reads as a broken image rather than a
/// different platform. So the square is inset onto a platter cut to the icon
/// grid's corner — 185.4 units of radius on an 824-unit side — and the result
/// carries an alpha channel, which is what makes LaunchServices treat it as
/// an icon it may shape rather than a picture it must show whole.
nonisolated enum IconShaping {
    /// The corner radius as a fraction of the side, from Apple's icon grid.
    static let cornerRatio = 185.4 / 824.0
    /// How much of the platter the program's own artwork covers.
    static let artworkRatio = 0.8

    /// The platter's gray. One look, light, because a rendered icon is one
    /// image shown in both appearances.
    private static let platter = (red: 0xE9 / 255.0, green: 0xE9 / 255.0, blue: 0xEB / 255.0)

    /// One corner of the outline: where it sits, which way the platter lies
    /// from it, and whether the perimeter meets its horizontal edge first.
    private struct Corner {
        let point: CGPoint
        let inward: CGVector
        let fromHorizontalEdge: Bool
    }

    /// The macOS icon outline for a square of this size: straight edges
    /// joined by continuous corners, as a closed path.
    static func shape(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let radius = min(rect.width, rect.height) * cornerRatio
        // Counterclockwise from the bottom edge, so each corner's arc ends
        // where the next one's begins.
        let corners = [
            Corner(
                point: CGPoint(x: rect.maxX, y: rect.minY),
                inward: CGVector(dx: -1, dy: 1), fromHorizontalEdge: true,
            ),
            Corner(
                point: CGPoint(x: rect.maxX, y: rect.maxY),
                inward: CGVector(dx: -1, dy: -1), fromHorizontalEdge: false,
            ),
            Corner(
                point: CGPoint(x: rect.minX, y: rect.maxY),
                inward: CGVector(dx: 1, dy: -1), fromHorizontalEdge: true,
            ),
            Corner(
                point: CGPoint(x: rect.minX, y: rect.minY),
                inward: CGVector(dx: 1, dy: 1), fromHorizontalEdge: false,
            ),
        ]
        for (index, corner) in corners.enumerated() {
            for (step, point) in cornerPoints(of: corner, radius: radius).enumerated() {
                if index == 0, step == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
        path.closeSubpath()
        return path
    }

    /// The arc of one corner, walked from the edge the perimeter arrives on
    /// to the edge it leaves by.
    ///
    /// Each corner is a quarter of a superellipse rather than a quarter
    /// circle: the curvature enters the straight edge gradually, and the
    /// abrupt entry is what a plain rounded rectangle shows as a seam.
    private static func cornerPoints(of corner: Corner, radius: CGFloat) -> [CGPoint] {
        let exponent = 5.0
        let steps = 24
        // At angle zero the arc sits on the vertical edge and at a quarter
        // turn on the horizontal one.
        let arc = (0 ... steps).map { step -> CGPoint in
            let angle = Double(step) / Double(steps) * .pi / 2
            let alongX = pow(cos(angle), 2 / exponent)
            let alongY = pow(sin(angle), 2 / exponent)
            return CGPoint(
                x: corner.point.x + corner.inward.dx * radius * (1 - alongX),
                y: corner.point.y + corner.inward.dy * radius * (1 - alongY),
            )
        }
        return corner.fromHorizontalEdge ? Array(arc.reversed()) : arc
    }

    /// Draws the platter and the artwork into a context whose coordinate
    /// space is `rect`.
    private static func draw(_ artwork: CGImage?, into context: CGContext, in rect: CGRect) {
        context.saveGState()
        context.addPath(shape(in: rect))
        context.clip()
        context.setFillColor(
            red: platter.red, green: platter.green, blue: platter.blue, alpha: 1,
        )
        context.fill(rect)
        if let artwork {
            context.interpolationQuality = .high
            context.draw(artwork, in: artworkRect(in: rect))
        }
        context.restoreGState()
    }

    /// Where the program's artwork sits: centered, square, and short of the
    /// platter's edge by the inset the icon grid gives an app's glyph.
    static func artworkRect(in rect: CGRect) -> CGRect {
        let side = min(rect.width, rect.height) * artworkRatio
        return CGRect(
            x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side,
        )
    }

    /// The shaped icon as its own image, `pixels` on a side.
    static func rendered(_ artwork: CGImage?, pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
              ) else { return nil }
        draw(
            artwork, into: context,
            in: CGRect(x: 0, y: 0, width: pixels, height: pixels),
        )
        return context.makeImage()
    }

    /// The shaped icon as PNG bytes, which is what an `.iconset` is made of.
    static func png(_ artwork: CGImage?, pixels: Int) -> Data? {
        guard let image = rendered(artwork, pixels: pixels) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil,
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
