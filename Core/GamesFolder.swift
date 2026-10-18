import Foundation

/// A folder of every game's bundle, for the Dock: kept there as a directory
/// tile, it opens as a stack or a grid with each game under its own icon,
/// and a click starts one.
///
/// The bundles stay where they are — `Launchers/<id>/<Title>.app`, where the
/// loader reads the id off its own path — so the folder holds a symlink per
/// bundle under the game's title. The Dock sorts by the symlink's own date,
/// so a launch touches it and the last played game comes first and on top.
nonisolated enum GamesFolder {
    static let root = AppIdentity.supportFolder.appendingPathComponent("Games")
    /// The tile's label in the Dock.
    static let label = "Games"

    /// Rebuilds the folder: one symlink per bundle a Dock tile could start,
    /// nothing else. A symlink already pointing right keeps its date.
    static func sync(appIDs: some Sequence<Int>) {
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        // Two games sharing a title: the lower id keeps the plain name, so the
        // app's pass and the daemon's agree on who gets it.
        var wanted: [String: URL] = [:]
        for id in appIDs.sorted() {
            guard let bundle = GameLaunchers.dockableBundle(appID: id) else { continue }
            wanted[linkName(for: bundle, appID: id, taken: wanted)] = bundle
        }
        let entries = (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        )) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            if let bundle = wanted[name],
               (try? manager.destinationOfSymbolicLink(atPath: entry.path)) == bundle.path {
                wanted[name] = nil
                continue
            }
            try? manager.removeItem(at: entry)
        }
        for (name, bundle) in wanted {
            try? manager.createSymbolicLink(
                at: root.appendingPathComponent(name), withDestinationURL: bundle,
            )
        }
    }

    /// The bundle's name, or the name with the id when another game's link
    /// holds it already.
    private static func linkName(for bundle: URL, appID: Int, taken: [String: URL]) -> String {
        let plain = bundle.lastPathComponent
        guard let other = taken[plain], other != bundle else { return plain }
        return "\(bundle.deletingPathExtension().lastPathComponent) (\(appID)).app"
    }

    /// The link that points at the game's bundle, whichever name it got.
    private static func link(appID: Int) -> URL? {
        guard let bundle = GameLaunchers.dockableBundle(appID: appID) else { return nil }
        let manager = FileManager.default
        let plain = root.appendingPathComponent(bundle.lastPathComponent)
        if (try? manager.destinationOfSymbolicLink(atPath: plain.path)) == bundle.path { return plain }
        let numbered = root.appendingPathComponent(
            "\(bundle.deletingPathExtension().lastPathComponent) (\(appID)).app",
        )
        if (try? manager.destinationOfSymbolicLink(atPath: numbered.path)) == bundle.path { return numbered }
        return nil
    }

    /// Puts the game first in the folder's order: its symlink's date is now.
    static func markPlayed(appID: Int) {
        guard let link = link(appID: appID) else { return }
        let now = timeval(tv_sec: time(nil), tv_usec: 0)
        let times = [now, now]
        _ = times.withUnsafeBufferPointer { lutimes(link.path, $0.baseAddress) }
    }
}
