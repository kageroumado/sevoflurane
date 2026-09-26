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
    static func renderer(forApp appID: Int, exe: String?, in text: String) -> String? {
        var pidsByExe: [(pid: Substring, exe: String)] = []
        var renderers: [Substring: Substring] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if let match = line.firstMatch(of: run), Int(match.output.3) == appID {
                pidsByExe.append((match.output.1, match.output.2.lowercased()))
            } else if let match = line.firstMatch(of: gfx) {
                renderers[match.output.1] = match.output.2
            }
        }
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
