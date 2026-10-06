import Foundation

/// Where store games may be written, started from and taken away.
///
/// Folder names, install paths and play tasks all come from a store or from
/// a client's files, which Sevoflurane does not control, so every path built
/// or read from them is checked here first: a name becomes one path
/// component, and a folder is touched only when it resolves, symlinks
/// followed, strictly inside an install root Sevoflurane manages.
nonisolated enum StorePaths {
    /// The install roots in use: each store's default folder and every
    /// folder a game was installed into, recorded in `Stores/roots.json`.
    static func managedRoots() -> [URL] {
        let recorded = (try? Data(contentsOf: rootsFile))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return GameStore.allCases.map(\.defaultInstallBase) + recorded.map { URL(fileURLWithPath: $0) }
    }

    /// Records a folder games are installed into, after ``acceptsRoot(_:)``.
    static func rememberRoot(_ root: URL) throws {
        let path = resolved(root).path
        let recorded = managedRoots().dropFirst(GameStore.allCases.count).map(\.path)
        guard !recorded.contains(path) else { return }
        try FileManager.default.createDirectory(at: rootsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(recorded + [path]).write(to: rootsFile, options: .atomic)
    }

    private static var rootsFile: URL {
        AppIdentity.supportFolder.appending(path: "Stores/roots.json")
    }

    /// Folders that hold more than games, which no root may be or contain.
    static var protectedFolders: [URL] {
        [UserHome.url, AppIdentity.supportFolder, SteamBottle.root, SteamBottle.root.appending(path: "drive_c")]
    }

    // MARK: - Names

    /// `raw` as one path component, or `fallback` made into one, or nil when
    /// neither can be.
    static func folderName(_ raw: String?, fallback: String) -> String? {
        if let raw, isComponent(raw) { return raw }
        return isComponent(fallback) ? fallback : nil
    }

    /// Whether `name` names exactly one entry in a folder: no separator, no
    /// `.` or `..`, no leading dot, no control character.
    static func isComponent(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed == name, !name.hasPrefix("."),
              !name.contains("/"), !name.contains(#"\"#), !name.contains(":") else { return false }
        return !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    // MARK: - Containment

    /// The path with every symlink followed and `.` and `..` folded away.
    static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Whether `path` lies strictly inside `root`, both resolved.
    static func isStrictlyInside(_ path: URL, _ root: URL) -> Bool {
        let inner = resolved(path).path
        let outer = resolved(root).path
        return inner.hasPrefix(outer == "/" ? "/" : outer + "/") && inner != outer
    }

    /// Whether a folder may be an install root: it is not the filesystem's
    /// root, and neither is nor holds a protected folder.
    static func acceptsRoot(_ root: URL, protected: [URL] = protectedFolders) -> Bool {
        let path = resolved(root).path
        guard path != "/" else { return false }
        return !protected.contains { folder in
            let folder = resolved(folder)
            return folder.path == path || isStrictlyInside(folder, root)
        }
    }

    /// The managed root a game folder lies strictly inside, or nil when it
    /// lies in none, is a root itself, or is or holds a protected folder.
    static func root(
        containing folder: URL, roots: [URL] = managedRoots(), protected: [URL] = protectedFolders,
    ) -> URL? {
        let target = resolved(folder)
        guard !protected.contains(where: { resolved($0).path == target.path || isStrictlyInside($0, target) }) else {
            return nil
        }
        return roots.first { isStrictlyInside(target, $0) && acceptsRoot($0, protected: protected) }
    }

    /// Whether a launch plan stays inside its game's folder, and that folder
    /// inside a managed root.
    static func accepts(_ plan: StoreLaunchPlan, roots: [URL] = managedRoots(), protected: [URL] = protectedFolders) -> Bool {
        let folder = URL(fileURLWithPath: plan.folder)
        guard root(containing: folder, roots: roots, protected: protected) != nil,
              isStrictlyInside(URL(fileURLWithPath: plan.executable), folder) else { return false }
        let directory = URL(fileURLWithPath: plan.workingDirectory)
        return resolved(directory).path == resolved(folder).path || isStrictlyInside(directory, folder)
    }

    /// Moves a game's folder to the Trash after ``root(containing:roots:protected:)``
    /// has placed it, refusing anything else.
    static func trash(_ folder: URL, roots: [URL] = managedRoots(), protected: [URL] = protectedFolders) throws {
        guard root(containing: folder, roots: roots, protected: protected) != nil else {
            throw StoreFailure("\(folder.path) is outside the folders store games are installed in, so it was left in place")
        }
        let target = resolved(folder)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }
}
