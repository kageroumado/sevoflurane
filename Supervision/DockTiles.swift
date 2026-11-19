import Foundation

/// Keeps game bundles and the Games folder in the Dock. The Dock has no API:
/// tiles go in its `persistent-apps` and `persistent-others` preferences,
/// which it reads at restart, filling in everything but the file URL.
nonisolated enum DockTiles {
    private static let domain = "com.apple.dock"
    private static let key = "persistent-apps"
    /// The right-hand side, where folders go.
    private static let othersKey = "persistent-others"

    /// Whether a tile for the bundle is already kept.
    static func isKept(_ bundle: URL) -> Bool {
        let wanted = bundle.standardizedFileURL.path
        return keptApps().contains { path(of: $0) == wanted }
    }

    /// Adds the bundle after the last kept app and restarts the Dock so it
    /// reads it. A bundle already kept is left where the user put it.
    static func keep(_ bundle: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !isKept(bundle) else { return }
        write(keptApps() + [make(bundle)])
    }

    /// Takes the bundle's tile out, if one is kept, and restarts the Dock.
    static func remove(_ bundle: URL) {
        lock.lock()
        defer { lock.unlock() }
        let wanted = bundle.standardizedFileURL.path
        let remaining = keptApps().filter { path(of: $0) != wanted }
        guard remaining.count != keptApps().count else { return }
        write(remaining)
    }

    /// Points a kept tile at a renamed game's new bundle, or it shows a
    /// question mark.
    static func replace(_ old: URL, with new: URL) {
        lock.lock()
        defer { lock.unlock() }
        let wanted = old.standardizedFileURL.path
        var changed = false
        let tiles = keptApps().map { tile -> [String: Any] in
            guard path(of: tile) == wanted else { return tile }
            changed = true
            return make(new)
        }
        if changed { write(tiles) }
    }

    /// Whether a tile for the folder is kept on the Dock's right-hand side.
    static func isFolderKept(_ folder: URL) -> Bool {
        let wanted = folder.standardizedFileURL.path
        return tiles(othersKey).contains { path(of: $0) == wanted }
    }

    /// Keeps the folder as a grid stack, newest first, so the last played game
    /// is on top; one already kept is left as the user set it.
    static func keepFolder(_ folder: URL, label: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFolderKept(folder) else { return }
        let tile: [String: Any] = [
            "tile-type": "directory-tile",
            "tile-data": [
                "file-data": [
                    "_CFURLString": folder.standardizedFileURL.absoluteString.hasSuffix("/")
                        ? folder.standardizedFileURL.absoluteString
                        : folder.standardizedFileURL.absoluteString + "/",
                    "_CFURLStringType": 15,
                ],
                "file-label": label,
                "file-type": 2,
                "arrangement": 3,
                "displayas": 0,
                "showas": 0,
            ],
        ]
        write(tiles(othersKey) + [tile], to: othersKey)
    }

    /// Takes the folder's tile out, if one is kept, and restarts the Dock.
    static func removeFolder(_ folder: URL) {
        lock.lock()
        defer { lock.unlock() }
        let wanted = folder.standardizedFileURL.path
        let kept = tiles(othersKey)
        let remaining = kept.filter { path(of: $0) != wanted }
        guard remaining.count != kept.count else { return }
        write(remaining, to: othersKey)
    }

    /// The tile as the Dock records one it was given by a drag. `dock-extra`
    /// is the Dock's own mark for an app with a tile plug-in; without it
    /// the plug-in is never loaded for the tile.
    private static func make(_ bundle: URL) -> [String: Any] {
        let plugIn = bundle.appendingPathComponent("Contents/PlugIns/\(GameLaunchers.dockTilePlugInName)")
        return [
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": [
                    "_CFURLString": bundle.standardizedFileURL.absoluteString,
                    "_CFURLStringType": 15,
                ],
                "file-label": bundle.deletingPathExtension().lastPathComponent,
                "dock-extra": FileManager.default.fileExists(atPath: plugIn.path),
            ],
        ]
    }

    private static func path(of tile: [String: Any]) -> String? {
        guard let data = tile["tile-data"] as? [String: Any],
              let file = data["file-data"] as? [String: Any],
              let string = file["_CFURLString"] as? String,
              let url = URL(string: string)
        else { return nil }
        return url.standardizedFileURL.path
    }

    /// One read-modify-write at a time: two switches flipped quickly each
    /// read the Dock's list, and the second would drop the first's change.
    private static let lock = NSLock()

    private static func write(_ tiles: [[String: Any]], to key: String = key) {
        CFPreferencesSetAppValue(key as CFString, tiles as CFArray, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Dock"]
        try? restart.run()
    }

    private static func keptApps() -> [[String: Any]] {
        tiles(key)
    }

    private static func tiles(_ key: String) -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [[String: Any]] ?? []
    }
}
