import Foundation

/// Steam's record of the processes it started for a game
/// (`<Steam>/logs/gameprocess_log.txt`), the only place a game's exit status
/// exists: `Steam.exe` starts games inside the bottle, so the app has no pid
/// to wait on. Its pids are Windows pids, so a process is identified by the
/// executable of its command line.
nonisolated enum SteamGameProcessLog {
    struct Exit: Equatable, Sendable {
        let pid: Int
        let code: Int
        /// Lower case.
        let executable: String?
    }

    /// Crash handlers Steam tracks beside the game. They exit 0 after the
    /// game died, so their exit says nothing about the run.
    static let helperExecutables = [
        "unitycrashhandler64.exe", "unitycrashhandler32.exe",
        "steamerrorreporter64.exe", "steamerrorreporter.exe",
    ]

    /// The exit that describes the run: the recorded executable's if it is
    /// there, otherwise the last that is not a crash handler's, otherwise the
    /// last of any.
    static func exit(forApp appID: Int, running exe: String?, in text: String) -> Exit? {
        let exits = exits(forApp: appID, in: text)
        if let exe = exe?.lowercased(),
           let match = exits.last(where: { $0.executable == exe }) { return match }
        if let match = exits.last(where: {
            $0.executable.map { !helperExecutables.contains($0) } ?? false
        }) { return match }
        return exits.last
    }

    /// Whether the log mentions this app. Steam rewrites the file at each
    /// client start, so an absent app belongs to an ended session.
    static func tracks(app appID: Int, in text: String) -> Bool {
        text.split(whereSeparator: \.isNewline)
            .contains { body(of: $0, forApp: appID) != nil }
    }

    /// Every process Steam stopped tracking for this app, in order.
    static func exits(forApp appID: Int, in text: String) -> [Exit] {
        var executables: [Int: String] = [:]
        var exits: [Exit] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let rest = body(of: line, forApp: appID) else { continue }
            if let match = rest.firstMatch(of: added) {
                executables[Int(match.output.1) ?? 0] = executable(fromCommandLine: match.output.2)
            } else if let match = rest.firstMatch(of: removed) {
                let pid = Int(match.output.1) ?? 0
                exits.append(
                    Exit(pid: pid, code: Int(match.output.2) ?? 0, executable: executables[pid]),
                )
            }
        }
        return exits
    }

    /// The game's engine (`unity`, `unreal`), from its tracked executables.
    static func runtime(forApp appID: Int, in text: String, exe: String?) -> String? {
        var names = exits(forApp: appID, in: text).compactMap(\.executable)
        if let exe { names.append(exe.lowercased()) }
        if names.contains(where: { $0.contains("unitycrashhandler") }) { return "unity" }
        if names.contains(where: { $0.contains("-win64-shipping") || $0.contains("-win32-shipping") }) {
            return "unreal"
        }
        return nil
    }

    /// The part of an `AppID <id> …` line after the app id, for this app.
    private static func body(of line: Substring, forApp appID: Int) -> Substring? {
        guard let start = line.range(of: "AppID \(appID) ") else { return nil }
        return line[start.upperBound...]
    }

    /// The executable of a command line, which Steam wraps in doubled quotes.
    private static func executable(fromCommandLine command: Substring) -> String? {
        let unquoted = command.drop { $0 == "\"" }
        guard let end = unquoted.range(of: ".exe", options: .caseInsensitive) else { return nil }
        let path = unquoted[..<end.upperBound]
        let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last
        return name.map { $0.lowercased() }
    }

    // `nonisolated(unsafe)`: `Regex` is not `Sendable`, and a regex built from
    // a literal carries no transform that could hold state.
    private nonisolated(unsafe) static let added = /adding PID (\d+) as a tracked process (.*)/
    private nonisolated(unsafe) static let removed = /no longer tracking PID (\d+), exit code (-?\d+)/
}
