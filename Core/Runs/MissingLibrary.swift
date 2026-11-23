import Foundation

/// A library the Windows loader could not find for a run's executable, from
/// Wine's `err:module:import_dll Library MSVCP140.dll (which is needed by
/// L"C:\\game\\game.exe") not found` line. A program that imports it never
/// starts, and only this line names the file.
nonisolated enum MissingLibrary {
    struct Missing: Equatable, Sendable {
        var library: String
        /// The image that imports it, by file name.
        var importer: String
    }

    /// Every user-mode import the loader could not resolve, in the log's
    /// order. An importer ending in `.sys` is a kernel driver
    /// (``KernelDriverFailure``).
    static func all(in text: String) -> [Missing] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.contains(marker), let match = line.firstMatch(of: pattern) else { return nil }
            let importer = match.output.2.split(separator: "\\").last.map(String.init) ?? String(match.output.2)
            guard !importer.lowercased().hasSuffix(".sys") else { return nil }
            return Missing(library: String(match.output.1), importer: importer)
        }
    }

    /// The library a run of `exe` could not start without: the one its
    /// executable imports, or, when the run ended with `STATUS_DLL_NOT_FOUND`,
    /// the last one the log names. A library that is itself in the log as an
    /// importer leads to the one it lacked.
    static func library(forExecutable exe: String?, endedDLLNotFound: Bool, in text: String) -> String? {
        let missing = all(in: text)
        let own = exe.flatMap { exe in missing.first { $0.importer.lowercased() == exe.lowercased() } }
        guard var found = own ?? (endedDLLNotFound ? missing.last : nil) else { return nil }
        var seen: Set<String> = []
        while seen.insert(found.library.lowercased()).inserted,
              let deeper = missing.first(where: { $0.importer.lowercased() == found.library.lowercased() }) {
            found = deeper
        }
        return found.library
    }

    /// The exit status of a process whose import could not be found.
    static let statusDLLNotFound = "0xc0000135"

    /// The cheap test before the pattern.
    private static let marker = "import_dll"

    private nonisolated(unsafe) static let pattern =
        /import_dll Library (\S+) \(which is needed by L"([^"]*)"\) not found/
}
