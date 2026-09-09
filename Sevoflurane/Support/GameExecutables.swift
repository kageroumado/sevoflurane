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
    /// Where the scan's outcome is narrated. The default reaches `sevo`'s
    /// caller; the app points it at its own event log.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }

    /// How deep the scan looks: `Game.exe` at the top, `bin/Game.exe`, and
    /// Unreal's `<Project>/Binaries/Win64/Game-Win64-Shipping.exe`.
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
        return record(appID: appID, name: game.name, directory: game.directory)
    }

    /// Records every installed game's executables — what the app runs at
    /// every client start, so a game's env file and its launcher bundle exist
    /// before Steam starts it. A link or an unlink is followed by a client
    /// restart, and a game Steam downloads mid-session is read by
    /// ``recordFromInstall(appID:)`` when it launches, so this is the whole
    /// library's supply. Returns whether any game gained an exe, so one
    /// materialize covers them all.
    ///
    /// A directory listing per game to ``maxDepth`` levels: a 29-game library
    /// walks in under 10 ms, which is why it needs no cache.
    @discardableResult
    static func recordLibrary() -> Bool {
        var recorded = false
        for game in SharedGames.installedGames() {
            if record(appID: game.appID, name: game.name, directory: game.directory) {
                recorded = true
            }
        }
        return recorded
    }

    private static func record(appID: Int, name: String, directory: URL) -> Bool {
        let known = Set(GameConfig.game(appID).exes ?? [])
        let found = executables(in: directory)
        guard !found.isEmpty else {
            log("app \(appID): no executables under \(directory.path)")
            return false
        }
        let new = found.filter { !known.contains($0) }
        guard !new.isEmpty else { return false }
        for exe in new {
            GameConfig.noteExecutable(exe, forApp: appID, named: name)
        }
        log("app \(appID): recorded \(new.count) exes (\(new.joined(separator: ", ")))")
        return true
    }

    /// Lowercased exe names, shallowest first, tools left out.
    static func executables(in directory: URL) -> [String] {
        var found: [(depth: Int, name: String)] = []
        var queue: [(URL, Int)] = [(directory, 0)]
        while let (folder, depth) = queue.first {
            queue.removeFirst()
            for entry in InstallDirectory.entries(in: folder) {
                if entry.isDirectory {
                    if depth + 1 <= maxDepth { queue.append((entry.url, depth + 1)) }
                    continue
                }
                let name = entry.name.lowercased()
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
