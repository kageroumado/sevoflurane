import AppKit
import Foundation
import Observation

/// The name and picture Streamer Mode shows in the account's place, as
/// Settings › General edits them.
@MainActor
@Observable
final class StreamerModeStore {
    /// The display name field's text; empty shows the default name.
    var name = ""
    /// Whether a picture of the user's is stored.
    private(set) var hasPicture = false
    /// The stored picture, when it decodes.
    private(set) var picture: NSImage?
    /// Why the last chosen file was refused.
    private(set) var pictureFailure: String?

    /// Reads the stored name and picture.
    func load() {
        name = Preferences.shared.string(forKey: StreamerMode.displayNameKey) ?? ""
        readPicture()
    }

    /// Stores the field's text as the display name.
    func storeName() {
        StreamerMode.displayName = name
    }

    /// Crops and stores a picture the user chose.
    func choosePicture(from url: URL) {
        do {
            try StreamerPicture.store(from: url)
            pictureFailure = nil
        } catch {
            pictureFailure = String(localized: "That file is not a picture Sevoflurane can read.")
        }
        readPicture()
    }

    /// Goes back to the monogram.
    func removePicture() {
        try? FileManager.default.removeItem(at: StreamerMode.avatarURL)
        pictureFailure = nil
        readPicture()
    }

    private func readPicture() {
        hasPicture = FileManager.default.fileExists(atPath: StreamerMode.avatarURL.path)
        picture = NSImage(contentsOf: StreamerMode.avatarURL)
    }
}

/// The picture the user chose, cropped to a square and stored small.
enum StreamerPicture {
    enum Failure: Error {
        case unreadable
    }

    /// Reads any image macOS can decode, fills a ``StreamerMode/avatarPixels``
    /// square with its center, and writes it as a PNG to
    /// ``StreamerMode/avatarURL``.
    static func store(from source: URL) throws {
        guard let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0,
              let data = squarePNG(of: image, pixels: StreamerMode.avatarPixels) else {
            throw Failure.unreadable
        }
        let destination = StreamerMode.avatarURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try data.write(to: destination, options: .atomic)
    }

    static func squarePNG(of image: NSImage, pixels: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ) else { return nil }
        bitmap.size = NSSize(width: pixels, height: pixels)
        let side = min(image.size.width, image.size.height)
        let crop = NSRect(
            x: (image.size.width - side) / 2, y: (image.size.height - side) / 2,
            width: side, height: side,
        )
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: crop, operation: .copy, fraction: 1,
        )
        return bitmap.representation(using: .png, properties: [:])
    }
}
