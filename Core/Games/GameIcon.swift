import CoreGraphics
import Foundation
import ImageIO

/// The picture a game's own bundle shows on a Dock tile, as an `.icns`.
nonisolated enum GameIcon {
    /// The best picture of this game as an `.icns`. The dock shim's cached
    /// icon comes first: written per title at the game's first run from the
    /// raster winemac.drv hands the Dock, it is the shipped artwork (256 px for
    /// RPG Maker, where Steam's is 32).
    static func icns(appID: Int, title: String) -> URL? {
        let manager = FileManager.default
        if let program = AdoptedPrograms.program(appID) {
            return shapedICNS(forProgramAt: program.url, named: "\(appID)")
        }
        let cached = AppIdentity.cachesFolder.appendingPathComponent(
            "DockIcons/\(fileSafe(title)).app/Contents/Resources/icon.icns",
        )
        if manager.fileExists(atPath: cached.path) { return cached }
        guard let artwork = bestArtwork(appID: appID) else { return nil }
        return icns(from: artwork, named: "\(appID)")
    }

    /// The sharpest square picture before a first run: a Retina-sized exe
    /// icon, else the library capsule's middle square, else a smaller exe icon,
    /// else Steam's 32 px client icon.
    private static func bestArtwork(appID: Int) -> CGImage? {
        let exeIcon = executableIcon(appID: appID)
        if let exeIcon, exeIcon.width >= retinaTile { return exeIcon }
        if let capsule = capsuleSquare(appID: appID) { return capsule }
        if let exeIcon, exeIcon.width >= 64 { return exeIcon }
        if let raster = steamIcon(appID: appID) ?? packageIcon(appID: appID) {
            return image(at: raster)
        }
        return exeIcon
    }

    /// A tile is 128 points; this is its Retina size.
    private static let retinaTile = 256

    /// The icon of the game's recorded executables.
    private static func executableIcon(appID: Int) -> CGImage? {
        guard let exes = GameConfig.game(appID).exes, !exes.isEmpty,
              let directory = SharedGames.installDirectory(appID: appID) else { return nil }
        let wanted = Set(exes.map { $0.lowercased() })
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
        ) else { return nil }
        var found: [String: URL] = [:]
        for case let file as URL in enumerator {
            if enumerator.level > 3 { enumerator.skipDescendants() }
            let name = file.lastPathComponent.lowercased()
            if wanted.contains(name), found[name] == nil { found[name] = file }
            if found.count == wanted.count { break }
        }
        for exe in exes {
            if let url = found[exe.lowercased()], let icon = PEResources.icon(at: url) { return icon }
        }
        return nil
    }

    /// The middle square of `library_600x900.jpg`.
    private static func capsuleSquare(appID: Int) -> CGImage? {
        let capsule = SteamBottle.libraryCache.appendingPathComponent("\(appID)/library_600x900.jpg")
        guard let image = image(at: capsule) else { return nil }
        let side = min(image.width, image.height)
        return image.cropping(to: CGRect(
            x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side,
        ))
    }

    private static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// An adopted program's PE icon on the macOS platter (``IconShaping``), as
    /// Quick Look shows it. Rebuilt whenever the executable is newer.
    static func shapedICNS(forProgramAt exe: URL, named name: String) -> URL? {
        let manager = FileManager.default
        let cache = iconCache
        let stem = "\(name)-program-\(IconShaping.version)"
        let icns = cache.appendingPathComponent("\(stem).icns")
        if isFresh(icns, against: exe) { return icns }
        try? manager.removeItem(at: cache.appendingPathComponent("\(name)-program.icns"))
        let artwork = PEResources.icon(at: exe)
        let iconset = cache.appendingPathComponent("\(stem).iconset")
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
        AppIdentity.cachesFolder
            .appendingPathComponent("GameIcons")
    }

    /// Steam's square icon from the client's art cache, flat
    /// (`<appid>_icon.jpg`) or per-app directory.
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

    /// The NW.js package's `window.icon`.
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

    /// Bumped to re-render every cached icon once.
    private static let version = 2

    /// A cached `.icns` of RGBA bitmaps: LaunchServices shapes only an icon
    /// with an alpha channel and shows an opaque one square.
    private static func icns(from image: CGImage, named name: String) -> URL? {
        let manager = FileManager.default
        let cache = iconCache
        let icns = cache.appendingPathComponent("\(name)-rgba-\(version).icns")
        if manager.fileExists(atPath: icns.path) { return icns }
        try? manager.removeItem(at: cache.appendingPathComponent("\(name)-rgba.icns"))
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

    /// A title as the dock shim's cache names it.
    private static func fileSafe(_ title: String) -> String {
        let cleaned = title.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }
}
