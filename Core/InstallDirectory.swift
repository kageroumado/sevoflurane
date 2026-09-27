import Foundation

/// Listing a game's install directory, which is often a link into another
/// bottle.
///
/// A game shared from another bottle is a symlink to a directory
/// (``SharedGames/linkGameFiles(_:)``), and Foundation's URL-based directory
/// APIs refuse those: `contentsOfDirectory(at:)` throws `ENOTDIR` on a symlink
/// URL and `URLResourceValues.isDirectory` reads `false` for one. Every scan
/// of a game's files goes through here, so no scan can rediscover that by
/// finding nothing.
nonisolated enum InstallDirectory {
    /// One entry of a listing, with its link followed.
    struct Entry: Sendable {
        /// The entry's own path, symlinks resolved, so opening it works and
        /// its kind is the kind of what it points at.
        let url: URL
        /// The name as the directory spells it, case intact.
        let name: String
        let isDirectory: Bool
    }

    /// The directory's entries, hidden files left out, links followed.
    static func entries(in directory: URL) -> [Entry] {
        let manager = FileManager.default
        let resolved = directory.resolvingSymlinksInPath()
        let names = (try? manager.contentsOfDirectory(atPath: resolved.path)) ?? []
        return names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let url = resolved.appendingPathComponent(name).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
            return Entry(url: url, name: name, isDirectory: isDirectory.boolValue)
        }
    }
}
