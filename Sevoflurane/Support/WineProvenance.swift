import Foundation

/// The engine's own account of each process, written by `winemac.drv` to the
/// Wine log: `sevo:run pid=<unix pid> exe=<name> appid=<steam id> …` when a
/// process reaches the Mac driver, and `sevo:gfx pid=<unix pid>
/// renderer=<name> …` once its Direct3D modules are loaded. The renderer named
/// there is the one that answered the game — `wined3d-gl` for a D3D9 title
/// under a D3DMetal bottle, which the staged selection cannot know.
nonisolated enum WineProvenance {
    /// The renderer that answered this app's own executable, or, failing that,
    /// any process the engine attributed to the app id.
    ///
    /// `pid` is the game's own process when the app knows it. A program
    /// Steam did not start carries no app id (`appid=none`), so its process
    /// is the only thing that names its `sevo:gfx` line.
    static func renderer(forApp appID: Int, exe: String?, pid: pid_t? = nil, in text: String) -> String? {
        var pidsByExe: [(pid: Substring, exe: String)] = []
        var renderers: [Substring: Substring] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if let match = line.firstMatch(of: run), Int(match.output.3) == appID {
                pidsByExe.append((match.output.1, match.output.2.lowercased()))
            } else if let match = line.firstMatch(of: gfx) {
                renderers[match.output.1] = match.output.2
            }
        }
        if let pid, let renderer = renderers[Substring(String(pid))] { return String(renderer) }
        let wanted = exe?.lowercased()
        let own = pidsByExe.last { $0.exe == wanted }
        let candidates = [own].compactMap(\.self) + pidsByExe.reversed()
        for candidate in candidates {
            if let renderer = renderers[candidate.pid] { return String(renderer) }
        }
        return nil
    }

    /// The unix pids of every process the engine attributed to the app id.
    static func processes(forApp appID: Int, in text: String) -> Set<Int> {
        var pids: Set<Int> = []
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("sevo:run") {
            if let match = line.firstMatch(of: run), Int(match.output.3) == appID, let pid = Int(match.output.1) {
                pids.insert(pid)
            }
        }
        return pids
    }

    // The executable's name can carry spaces (`exe=Aka Manto.exe`), so it runs
    // to the app id rather than to the next blank.
    private nonisolated(unsafe) static let run = /sevo:run pid=(\d+) exe=(.+?) appid=(\d+)/
    private nonisolated(unsafe) static let gfx = /sevo:gfx pid=(\d+) renderer=(\S+)/
}

/// The exit of a program the helper started outside Steam, written to the
/// Wine log by the helper when the program's launcher ends:
/// `sevo:program-exit appid=<id> exe=<name> status=<code>`. Steam's process
/// log has no line for such a program, so this is the only place its exit
/// code exists. Written only where the launcher's status is the program's own
/// — the `steam.exe` parent (SteamParent) exits with its child's code — since
/// `start /unix` returns 0 the moment the program is spawned.
nonisolated enum ProgramExit {
    /// The program whose exit a launcher's status is.
    struct Program: Sendable {
        let appID: Int
        /// The executable's file name, as the launch named it.
        let exe: String
    }

    /// The line for `program`, whose launcher ended with `status`.
    static func line(_ program: Program, status: Int32) -> String {
        "sevo:program-exit appid=\(program.appID) exe=\(program.exe) status=\(status)"
    }

    /// The exit code the last line about `appID` in `text` gives. The
    /// `steam.exe` parent's own line carries the program's full 32-bit code
    /// (`sevo:steam-parent exit … appid=<id> code=<n>`), so it is preferred;
    /// the helper's line has the loader's unix status, which keeps only the
    /// low 8 bits (`STATUS_CONTROL_C_EXIT`, 0xC000013A, would read as 58).
    static func status(forApp appID: Int, in text: String) -> Int? {
        var parent: Int?, launcher: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.contains("sevo:steam-parent exit"),
               let match = line.firstMatch(of: parentExit), Int(match.output.1) == appID {
                parent = UInt32(match.output.2).map(Int.init)
            } else if line.contains("sevo:program-exit"),
                      let match = line.firstMatch(of: exit), Int(match.output.1) == appID {
                launcher = Int(match.output.2)
            }
        }
        return parent ?? launcher
    }

    /// The executable's name can carry spaces, so it runs to the status.
    private nonisolated(unsafe) static let exit = /sevo:program-exit appid=(\d+) exe=.+? status=(-?\d+)/
    private nonisolated(unsafe) static let parentExit = /sevo:steam-parent exit pid=\d+ appid=(\d+) code=(\d+)/
}
