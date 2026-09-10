import CoreGraphics
import Foundation
import QuickLookThumbnailing

/// Draws the Quick Look thumbnail of a Windows executable: its own icon, on
/// the macOS icon platter.
///
/// Finder shows a `.exe` as a generic document, which makes a folder of games
/// unreadable. The picture is already in the file — `PEResources` reads the
/// icon group without running anything — and `IconShaping` puts it on the
/// same platter the Dock tile of an adopted program carries, so one program
/// looks like one thing wherever it appears.
///
/// The extension is sandboxed and is handed the file it may read, which is
/// all this needs: no bottle, no Wine, no network.
final nonisolated class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void,
    ) {
        let artwork = PEResources.icon(at: request.fileURL)
        // Square: the icon shape is a square, and a reply narrower than the
        // request is centered by Quick Look itself.
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let size = CGSize(width: side, height: side)
        let reply = QLThumbnailReply(contextSize: size) { context in
            IconShaping.draw(
                artwork, into: context, in: CGRect(origin: .zero, size: size),
            )
            return true
        }
        handler(reply, nil)
    }
}
