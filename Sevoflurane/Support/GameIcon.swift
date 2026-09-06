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
        let cached = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Caches/Sevoflurane/DockIcons/\(fileSafe(title)).app/Contents/Resources/icon.icns",
        )
        if manager.fileExists(atPath: cached.path) { return cached }
        guard let raster = steamIcon(appID: appID) ?? packageIcon(appID: appID) else { return nil }
        return icns(from: raster, named: "\(appID)")
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

    /// Turns a raster into an `.icns` through the system's own tools, cached
    /// so that rebuilding a bundle does not rebuild the icon. macOS 26 shapes what it is given, so a square picture is all
    /// this has to produce.
    private static func icns(from raster: URL, named name: String) -> URL? {
        let manager = FileManager.default
        let cache = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/Sevoflurane/GameIcons")
        let icns = cache.appendingPathComponent("\(name).icns")
        if manager.fileExists(atPath: icns.path) { return icns }
        let iconset = cache.appendingPathComponent("\(name).iconset")
        try? manager.removeItem(at: iconset)
        guard (try? manager.createDirectory(at: iconset, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? manager.removeItem(at: iconset) }
        for size in [16, 32, 128, 256, 512] {
            for (scale, suffix) in [(1, ""), (2, "@2x")] {
                let pixels = size * scale
                let file = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                guard run("/usr/bin/sips", [
                    "-s", "format", "png", "-z", String(pixels), String(pixels),
                    raster.path, "--out", file.path,
                ]) else { return nil }
            }
        }
        guard run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path]),
              manager.fileExists(atPath: icns.path)
        else { return nil }
        return icns
    }

    /// A tool run to completion, for the two the icon pipeline needs.
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
