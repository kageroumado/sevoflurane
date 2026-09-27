import CoreGraphics
import Foundation
import QuickLookThumbnailing

/// Draws the Quick Look thumbnail of a Windows executable: its own icon, across
/// the whole thumbnail.
///
/// Finder shows a `.exe` as a generic document, which makes a folder of games
/// unreadable. The picture is already in the file — `PEResources` reads the
/// icon group without running anything. Finder frames a file's thumbnail
/// itself, so the icon is drawn bare, the way a document's preview is; the
/// platter an adopted program's Dock tile carries belongs to apps.
///
/// The extension is sandboxed and is handed the file it may read, which is
/// all this needs: no bottle, no Wine, no network.
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
        handler(reply, nil)
    }
}
