import Foundation

/// The executables a game ships, read from its install directory before its
/// first launch.
///
/// A game's per-program env file (and with it `SEVO_LOADER`, the bundle that
/// gives the game its own name, icon and Game Mode) is keyed on the exe name.
/// Waiting for the first window to learn that name means the first run of
/// every game is an anonymous `wine` in the Dock. The install directory says
/// which exes exist before anything runs, so every candidate is recorded at
/// launch time and the env files are in place when the process starts.
nonisolated enum GameExecutables {
    /// How deep the scan looks: `Game.exe` at the top, `bin/Game.exe`, and
    /// Unreal's `Binaries/Win64/Game-Win64-Shipping.exe`.
    private static let maxDepth = 3
    /// Games ship their tools beside the game; the tools are not the game.
    private static let excludedFragments = [
        "unins", "crash", "report", "redist", "vc_redist", "vcredist", "dxsetup",
        "directx", "dotnet", "setup", "install", "uninstall", "cleanup", "updater",
        "ue4prereq", "ueprereq", "easyanticheat", "eac", "battleye",
    ]

    /// Records every plausible executable of the app's install directory that
    /// is not already on record. Returns whether anything new was added, so
    /// the caller knows whether the env files need rewriting.
    @discardableResult
    static func recordFromInstall(appID: Int) -> Bool {
        guard let game = SharedGames.installed(appID: appID) else { return false }
        let known = Set(GameConfig.game(appID).exes ?? [])
        let found = executables(in: game.directory)
        let new = found.filter { !known.contains($0) }
        guard !new.isEmpty else { return false }
        for exe in new {
            GameConfig.noteExecutable(exe, forApp: appID, named: game.name)
        }
        return true
    }

    /// Lowercased exe names, shallowest first, tools left out.
    static func executables(in directory: URL) -> [String] {
        var found: [(depth: Int, name: String)] = []
        var queue: [(URL, Int)] = [(directory, 0)]
        let manager = FileManager.default
        while let (folder, depth) = queue.first {
            queue.removeFirst()
            let entries = (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
            )) ?? []
            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    if depth + 1 < maxDepth { queue.append((entry, depth + 1)) }
                    continue
                }
                let name = entry.lastPathComponent.lowercased()
                guard name.hasSuffix(".exe"), isGameLike(name) else { continue }
                found.append((depth, name))
            }
        }
        return found.sorted { $0.depth < $1.depth }.map(\.name)
    }

    static func isGameLike(_ name: String) -> Bool {
        !excludedFragments.contains { name.contains($0) }
    }
}
