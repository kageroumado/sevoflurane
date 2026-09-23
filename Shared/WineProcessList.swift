import Foundation

/// The Windows programs running on this Mac, read from `pgrep -lf '\.exe'`.
///
/// Each line of that output is a pid, a space, and the process's full
/// argument list. A Wine process's first argument is its Windows path —
/// `C:\Program Files (x86)\Steam\Steam.exe` — which can hold spaces, so the
/// program is everything up to the first `.exe`, and its name is that path's
/// last component.
nonisolated enum WineProcessList {
    struct Entry: Equatable {
        let pid: pid_t
        /// The executable's file name, lowercased: `steam.exe`.
        let name: String
    }

    /// The arguments that produce the output ``entries(fromPgrepLong:)``
    /// reads.
    static let pgrepArguments = ["-lf", "\\.exe"]

    static func entries(fromPgrepLong output: String) -> [Entry] {
        output.split(whereSeparator: \.isNewline).compactMap(entry)
    }

    /// The pids of the Windows programs named exactly `name`, compared
    /// without case: `game.exe` never matches `mygame.exe`.
    static func pids(named name: String, inPgrepLong output: String) -> [pid_t] {
        let wanted = name.lowercased()
        return entries(fromPgrepLong: output).filter { $0.name == wanted }.map(\.pid)
    }

    private static func entry(_ line: Substring) -> Entry? {
        let trimmed = line.drop { $0 == " " }
        guard let space = trimmed.firstIndex(of: " "),
              let pid = pid_t(trimmed[..<space]) else { return nil }
        let command = trimmed[trimmed.index(after: space)...]
        guard let exe = command.range(of: ".exe", options: .caseInsensitive) else { return nil }
        let path = command[..<exe.upperBound]
        let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? String(path)
        return Entry(pid: pid, name: name.lowercased())
    }
}
