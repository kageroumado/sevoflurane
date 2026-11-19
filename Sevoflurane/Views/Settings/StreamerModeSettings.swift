import AppKit
import Propofol
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Streamer Mode

/// The Streamer Mode switch, and the name and picture Steam's windows show in
/// the account's place while it is on.
struct StreamerModeSection: View {
    let steam: SteamActions?
    let highlighted: SettingsAnchor?
    @AppStorage(StreamerMode.isOnKey, store: Preferences.shared) private var isOn = false
    @State private var name = ""
    /// Bumped when the picture changes, so the preview reads the file again.
    @State private var pictureRevision = 0
    @State private var pictureFailure: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Streamer Mode", isOn: Binding(
                    get: { isOn },
                    set: { enabled in
                        StreamerMode.isOn = enabled
                        steam?.applyStreamerMode()
                    },
                ))
                .toggleStyle(.switch)
                Text("Hides your Steam name, picture, wallet balance and friends in every Steam window, for recording and streaming.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Friends appear as AI models such as Claude, ChatGPT and Gemini.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .highlightable(.generalStreamerMode, highlighted: highlighted)
            TextField("Display name", text: $name, prompt: Text(verbatim: StreamerMode.defaultDisplayName))
                .onSubmit(commitName)
                .onChange(of: name) { _, value in StreamerMode.displayName = value }
            pictureRow
        }
        .onAppear { name = Preferences.shared.string(forKey: StreamerMode.displayNameKey) ?? "" }
    }

    private var pictureRow: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Avatar")
                Text(hasPicture ? "Shown in place of your Steam avatar." : "A monogram of the display name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let pictureFailure {
                    Text(pictureFailure).font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer()
            StreamerPicturePreview(name: StreamerMode.resolvedName(name), revision: pictureRevision)
            if hasPicture {
                Button("Use Monogram") { removePicture() }
            }
            Button("Choose…") { choosePicture() }
        }
    }

    private var hasPicture: Bool {
        _ = pictureRevision
        return FileManager.default.fileExists(atPath: StreamerMode.avatarURL.path)
    }

    /// The name reaches Steam's pages with the next reload; with the mode on,
    /// that is now.
    private func commitName() {
        StreamerMode.displayName = name
        if isOn { steam?.applyStreamerMode() }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try StreamerPicture.store(from: url)
                pictureFailure = nil
            } catch {
                pictureFailure = String(localized: "That file is not a picture Sevoflurane can read.")
            }
            pictureChanged()
        }
    }

    private func removePicture() {
        try? FileManager.default.removeItem(at: StreamerMode.avatarURL)
        pictureFailure = nil
        pictureChanged()
    }

    private func pictureChanged() {
        pictureRevision += 1
        if isOn { steam?.applyStreamerMode() }
    }
}

/// The picture as Steam's pages will show it: the stored image, or the
/// monogram drawn with the page's letters and color.
private struct StreamerPicturePreview: View {
    let name: String
    let revision: Int

    /// The preview's edge in points.
    private static let edge: CGFloat = 32

    var body: some View {
        Group {
            if let image = storedImage {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Monogram.swiftUIColor(of: name)
                    Text(verbatim: Monogram.letters(of: name))
                        .font(.system(size: Self.edge * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: Self.edge, height: Self.edge)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .id(revision)
    }

    private var storedImage: NSImage? {
        NSImage(contentsOf: StreamerMode.avatarURL)
    }
}

extension Monogram {
    /// ``color(of:)`` for SwiftUI: the same HSL color, restated as HSB.
    static func swiftUIColor(of name: String) -> Color {
        let saturation = Double(Self.saturation) / 100, lightness = Double(Self.lightness) / 100
        let brightness = lightness + saturation * min(lightness, 1 - lightness)
        let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
        return Color(hue: Double(hue(of: name)) / 360, saturation: hsbSaturation, brightness: brightness)
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
