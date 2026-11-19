import Foundation

/// The executables a game ships, read from its install directory so its env
/// files and `SEVO_LOADER` bundle, keyed on exe name, exist before its first
/// launch.
nonisolated enum GameExecutables {
    /// Stderr, or the app's event log.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }

    /// Deep enough for Unreal's `<Project>/Binaries/Win64/Game-Win64-Shipping.exe`.
    private static let maxDepth = 3
    /// Games ship their tools beside the game; the tools are not the game.
    private static let excludedFragments = [
        "unins", "crash", "report", "redist", "vc_redist", "vcredist", "dxsetup",
        "directx", "dotnet", "setup", "install", "uninstall", "cleanup", "updater",
        "ue4prereq", "ueprereq", "easyanticheat", "eac", "battleye",
    ]

    /// Records the install directory's new executables; answers whether any.
    @discardableResult
    static func recordFromInstall(appID: Int) -> Bool {
        guard let game = SharedGames.installed(appID: appID) else { return false }
        return record(appID: appID, name: game.name, directory: game.directory)
    }

    /// Records every installed game's executables at each client start;
    /// mid-session downloads go through ``recordFromInstall(appID:)``. A
    /// 29-game library walks in under 10 ms, so there is no cache.
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
            // A macOS build installed through Steam Play holds an .app and no exe.
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if !entries.contains(where: { $0.hasSuffix(".app") }) {
                log("app \(appID): no executables under \(directory.path)")
            }
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
        executableURLs(in: directory).map { $0.lastPathComponent.lowercased() }
    }

    /// The same executables as files.
    static func executableURLs(in directory: URL) -> [URL] {
        var found: [(depth: Int, url: URL)] = []
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
                found.append((depth, entry.url))
            }
        }
        return found.sorted { $0.depth < $1.depth }.map(\.url)
    }

    /// Windows tools a game's install script or launcher runs (`regsvr32`,
    /// `msiexec`, HoYoPlay's `iexplore.exe`). Taken for the game, its exit
    /// would end the launch halfway and rerun the script next time.
    static let windowsTools: Set<String> = [
        "regsvr32.exe", "msiexec.exe", "cmd.exe", "reg.exe", "regedit.exe", "dllhost.exe",
        "wscript.exe", "cscript.exe", "powershell.exe", "oalinst.exe", "dxwsetup.exe",
        "iexplore.exe", "winebrowser.exe", "mshta.exe", "hh.exe", "dxdiag.exe", "winecfg.exe",
        "control.exe", "taskmgr.exe", "uninstaller.exe", "wmic.exe", "tasklist.exe", "taskkill.exe",
        "schtasks.exe", "sc.exe", "net.exe", "netsh.exe", "ipconfig.exe", "xcopy.exe",
        "icacls.exe", "attrib.exe", "expand.exe", "wusa.exe", "notepad.exe", "wordpad.exe",
    ]

    /// Whether a running executable can be recorded as a game's own.
    static func isRecordable(_ name: String) -> Bool {
        !windowsTools.contains(name.lowercased())
    }

    static func isGameLike(_ name: String) -> Bool {
        !excludedFragments.contains { name.contains($0) }
    }
}
