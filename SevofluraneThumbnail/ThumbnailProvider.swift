import CoreGraphics
import Foundation
import QuickLookThumbnailing

/// Draws a Windows executable's Quick Look thumbnail: its own icon, read by
/// `PEResources` and drawn bare across the thumbnail (the Dock tile's platter
/// belongs to apps). The sandboxed extension needs only the file it is handed.
final nonisolated class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void,
    ) {
        // A program with no icon keeps the icon macOS gives its kind.
        guard let artwork = PEResources.icon(at: request.fileURL) else {
            handler(nil, CocoaError(.featureUnsupported))
            return
        }
        // Square: a Windows icon is a square, and a reply narrower than the
        // request is centered by Quick Look itself.
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let reply = QLThumbnailReply(contextSize: CGSize(width: side, height: side)) { context in
            // The context's own bounds, not the size above: at a request scale
            // of 2 the canvas is twice as wide in the space this draws in.
            context.interpolationQuality = .high
            context.draw(artwork, in: context.boundingBoxOfClipPath)
            return true
        }
        reply.drawsBare()
        handler(reply, nil)
    }
}

private nonisolated extension QLThumbnailReply {
    /// Asks Finder to draw the thumbnail without its white document frame.
    /// `iconFlavor` is private (`kQLThumbnailPropertyIconFlavorKey`; 0 is the
    /// unframed flavor, unset is framed), so it is checked first: a rename
    /// costs the frame, never the thumbnail.
    func drawsBare() {
        guard responds(to: NSSelectorFromString("setIconFlavor:")) else { return }
        setValue(0, forKey: "iconFlavor")
    }
}
