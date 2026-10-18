import AppKit

/// A game that is already running, for a press on its Dock tile.
///
/// A game started through its own bundle is that bundle to macOS, and a
/// second press on its tile reaches the app rather than the game only
/// because the tile's loader hands every open to `sevoflurane://play`. A
/// game started some other way — a script, an older engine — runs as a bare
/// Windows process, found by the name of its executable.
@MainActor
enum RunningGame {
    /// Brings the game's windows forward. `false` when nothing of it runs,
    /// or what runs has no windows to bring yet.
    ///
    /// By executable name alone `game.exe` is every RPG Maker title at
    /// once, so a process also has to carry the game's own folder in its
    /// command line.
    static func activate(appID: Int, exes: [String], folder: String?) async -> Bool {
        let bundleID = "\(AppIdentity.identifierStem).game.\(appID)"
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return bring(app)
        }
        guard !exes.isEmpty, let folder, !folder.isEmpty else { return false }
        let listing = await Subprocess.run("/usr/bin/pgrep", WineProcessList.pgrepArguments).output
        let wanted = Set(exes.map { $0.lowercased() })
        let folderToken = folder.lowercased()
        for line in listing.split(whereSeparator: \.isNewline) {
            let lowered = line.lowercased()
            guard lowered.contains("\\\(folderToken)\\") || lowered.contains("/\(folderToken)/"),
                  let entry = WineProcessList.entries(fromPgrepLong: String(line)).first,
                  wanted.contains(entry.name),
                  let app = NSRunningApplication(processIdentifier: entry.pid), bring(app)
            else { continue }
            return true
        }
        return false
    }

    private static func bring(_ app: NSRunningApplication) -> Bool {
        NSApp.yieldActivation(to: app)
        return app.activate()
    }
}
