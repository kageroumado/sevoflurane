import Foundation

/// Listing a game's install directory, which is often a symlink into another
/// bottle (``SharedGames/linkGameFiles(_:)``).
///
/// Foundation's URL-based directory APIs refuse a symlinked directory:
/// `contentsOfDirectory(at:)` throws `ENOTDIR` and `URLResourceValues.isDirectory`
/// reads `false`. Every scan of a game's files goes through here.
nonisolated enum InstallDirectory {
    /// One entry of a listing, with its link followed.
    struct Entry: Sendable {
        /// The entry's path with symlinks resolved.
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
