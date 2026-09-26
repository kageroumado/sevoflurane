import Foundation

/// A game's own bundle kept in the Dock, beside the apps the user keeps there.
///
/// The Dock has no API for adding a tile; its kept apps are the
/// `persistent-apps` array in its preferences, read when it starts. A tile
/// written there needs only its file URL, and the Dock fills in the rest
/// (label, bookmark, bundle id) on the restart that makes it read the array.
nonisolated enum DockTiles {
    private static let domain = "com.apple.dock"
    private static let key = "persistent-apps"

    /// Whether a tile for the bundle is already kept.
    static func isKept(_ bundle: URL) -> Bool {
        let wanted = bundle.standardizedFileURL.path
        return keptApps().contains { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String,
                  let url = URL(string: string)
            else { return false }
            return url.standardizedFileURL.path == wanted
        }
    }

    /// Adds the bundle after the last kept app and restarts the Dock so it
    /// reads it. A bundle already kept is left where the user put it.
    static func keep(_ bundle: URL) {
        guard !isKept(bundle) else { return }
        let tile: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": [
                    "_CFURLString": bundle.standardizedFileURL.absoluteString,
                    "_CFURLStringType": 15,
                ],
                "file-label": bundle.deletingPathExtension().lastPathComponent,
            ],
        ]
        CFPreferencesSetAppValue(key as CFString, (keptApps() + [tile]) as CFArray, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Dock"]
        try? restart.run()
    }

    private static func keptApps() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [[String: Any]] ?? []
    }
}
