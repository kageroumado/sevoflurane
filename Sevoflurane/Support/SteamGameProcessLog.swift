import Foundation

/// Steam's own record of the processes it started for a game
/// (`<Steam>/logs/gameprocess_log.txt`). It is where a game's exit status
/// exists: games are `CreateProcess`ed by `Steam.exe` inside the bottle, so
/// the app has no pid to wait on.
///
/// The pids in it are the bottle's Windows pids, which nothing on the macOS
/// side shares, so a process is identified by the executable of the command
/// line it was added with.
nonisolated enum SteamGameProcessLog {
    struct Exit: Equatable, Sendable {
        let pid: Int
        let code: Int
        /// The executable Steam started, lower case, when the line named one.
        let executable: String?
    }

    /// Crash handlers and reporters Steam tracks beside the game. They exit 0
    /// after the game they were watching has already died, so an exit taken
    /// from one of them says nothing about the run.
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

    /// Whether the log has this app in it at all. Steam rewrites the file at
    /// each client start, so an app with no line of its own belongs to a
    /// client session that is over.
    static func tracks(app appID: Int, in text: String) -> Bool {
        text.split(whereSeparator: \.isNewline)
            .contains { body(of: $0, forApp: appID) != nil }
    }

    /// Every process Steam stopped tracking for this app, in order, named by
    /// the command line it was added with.
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

    /// What the game is built on, told by the processes Steam tracked for it
    /// and by the game's own executable.
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

    /// The executable of a tracked process's command line, which Steam wraps
    /// in quotes it also doubles.
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
