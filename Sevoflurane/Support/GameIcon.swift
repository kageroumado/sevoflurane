import CoreGraphics
import Foundation
import ImageIO

/// The picture a game shows on a Dock tile, as an `.icns`.
///
/// Every game Sevoflurane runs gets a bundle of its own — a copy of the wine
/// loader for a bottled game, NW.js for a native one — and macOS reads the
/// icon out of that bundle. This is where the best picture of a game on this
/// machine is found and made into one.
nonisolated enum GameIcon {
    /// The best picture of this game on the machine, as an `.icns`, or `nil`
    /// when there is none worth using.
    ///
    /// The exe's own icon comes first and is already an `.icns`: the dock shim
    /// writes one per title the first time a game runs under wine, taking the
    /// raster winemac.drv hands the Dock, and that is the artwork the game
    /// ships — 256 pixels for an RPG Maker title, where Steam's client icon
    /// and the package's `window.icon` are both 32.
    static func icns(appID: Int, title: String) -> URL? {
        let manager = FileManager.default
        if let program = AdoptedPrograms.program(appID) {
            return shapedICNS(forProgramAt: program.url, named: "\(appID)")
        }
        let cached = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Caches/Sevoflurane/DockIcons/\(fileSafe(title)).app/Contents/Resources/icon.icns",
        )
        if manager.fileExists(atPath: cached.path) { return cached }
        guard let raster = steamIcon(appID: appID) ?? packageIcon(appID: appID) else { return nil }
        return icns(from: raster, named: "\(appID)")
    }

    /// An adopted program's icon: the artwork in its own PE resources, drawn
    /// onto the macOS icon platter (``IconShaping``) so the Dock tile and the
    /// Quick Look thumbnail of the same exe show one picture.
    ///
    /// The result is cached under the program's id and rebuilt whenever the
    /// executable is newer than the icon, which is how a program that updates
    /// itself in place gets its new artwork.
    static func shapedICNS(forProgramAt exe: URL, named name: String) -> URL? {
        let manager = FileManager.default
        let cache = iconCache
        let icns = cache.appendingPathComponent("\(name)-program.icns")
        if isFresh(icns, against: exe) { return icns }
        let artwork = PEResources.icon(at: exe)
        let iconset = cache.appendingPathComponent("\(name)-program.iconset")
        try? manager.removeItem(at: iconset)
        guard (try? manager.createDirectory(at: iconset, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? manager.removeItem(at: iconset) }
        for size in [16, 32, 128, 256, 512] {
            for (scale, suffix) in [(1, ""), (2, "@2x")] {
                let file = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                guard let png = IconShaping.png(artwork, pixels: size * scale),
                      (try? png.write(to: file)) != nil else { return nil }
            }
        }
        try? manager.removeItem(at: icns)
        guard run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path]),
              manager.fileExists(atPath: icns.path)
        else { return nil }
        return icns
    }

    /// Whether a cached icon was made from the executable as it stands now.
    private static func isFresh(_ icns: URL, against exe: URL) -> Bool {
        guard let iconDate = modified(icns) else { return false }
        guard let exeDate = modified(exe) else { return true }
        return iconDate >= exeDate
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static var iconCache: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/Sevoflurane/GameIcons")
    }

    /// Steam's own icon for the app, from the client's art cache: a per-app
    /// directory in current clients, a flat `<appid>_icon.jpg` in older ones.
    /// The square image is the icon; the capsules and the hero art beside it
    /// are wide and would be cropped into nothing.
    private static func steamIcon(appID: Int) -> URL? {
        let cache = SteamBottle.libraryCache
        let flat = cache.appendingPathComponent("\(appID)_icon.jpg")
        if FileManager.default.fileExists(atPath: flat.path) { return flat }
        let directory = cache.appendingPathComponent(String(appID))
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
        )) ?? []
        return entries.filter { entry in
            guard let size = imageSize(of: entry) else { return false }
            return size.width == size.height && size.width >= 32
        }.max { (imageSize(of: $0)?.width ?? 0) < (imageSize(of: $1)?.width ?? 0) }
    }

    /// The icon the game's own package names, which RPG Maker points at
    /// `www/icon/icon.png`.
    private static func packageIcon(appID: Int) -> URL? {
        guard let info = GameConfig.game(appID).nwjs,
              let package = (try? Data(contentsOf: URL(fileURLWithPath: info.dir)
                      .appendingPathComponent("package.json")))
              .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let window = package["window"] as? [String: Any],
              let relative = window["icon"] as? String
        else { return nil }
        let url = URL(fileURLWithPath: info.dir).appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func imageSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
              as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// Turns a raster into an `.icns`, cached so that rebuilding a bundle does
    /// not rebuild the icon. Every representation is drawn into an RGBA
    /// bitmap: LaunchServices applies the macOS icon shape (continuous
    /// corners, platter, glass edge) only to an icon with an alpha channel,
    /// and shows an opaque one as the square it is.
    private static func icns(from raster: URL, named name: String) -> URL? {
        let manager = FileManager.default
        let cache = iconCache
        let icns = cache.appendingPathComponent("\(name)-rgba.icns")
        if manager.fileExists(atPath: icns.path) { return icns }
        guard let source = CGImageSourceCreateWithURL(raster as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let iconset = cache.appendingPathComponent("\(name).iconset")
        try? manager.removeItem(at: iconset)
        guard (try? manager.createDirectory(at: iconset, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? manager.removeItem(at: iconset) }
        for size in [16, 32, 128, 256, 512] {
            for (scale, suffix) in [(1, ""), (2, "@2x")] {
                let file = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                guard let png = rgbaPNG(image, pixels: size * scale),
                      (try? png.write(to: file)) != nil else { return nil }
            }
        }
        guard run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path]),
              manager.fileExists(atPath: icns.path)
        else { return nil }
        return icns
    }

    /// The image scaled to `pixels` square, as a PNG with an alpha channel.
    private static func rgbaPNG(_ image: CGImage, pixels: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let output = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, output, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A tool run to completion, for `iconutil`.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// A title as a file name, matching the name the dock shim's cache uses.
    private static func fileSafe(_ title: String) -> String {
        let cleaned = title.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }
}
