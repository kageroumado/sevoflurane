import Foundation

/// A Windows program that needs its own kernel driver: kernel anti-cheat, and
/// some DRM. Wine runs no third-party drivers, so the program's service fails
/// to load and the program quits or waits with nothing on screen. Wine's log
/// is the only place that says so.
nonisolated enum KernelDriverFailure {
    /// The driver named in a failure line of Wine's log, like
    /// `HoYoKProtect.sys`, or `nil` when the text has none.
    ///
    /// Two shapes: the loader missing a kernel import for a `.sys` image
    /// (`import_dll Library WDFLDR.SYS (which is needed by L"…\HoYoKProtect.sys") not found`),
    /// and ntoskrnl failing to start a driver service
    /// (`ZwLoadDriver failed to create driver L"\Driver\HoYoKProtect"`).
    static func driver(in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("import_dll") || line.contains("ZwLoadDriver") {
            if let neededBy = line.range(of: #"needed by L"[^"]*\\([^\\"]+\.sys)""#, options: [.regularExpression, .caseInsensitive]) {
                let quoted = line[neededBy]
                if let name = quoted.split(separator: "\\").last?.split(separator: "\"").first {
                    return String(name)
                }
            }
            if line.contains("ZwLoadDriver"),
               let driver = line.range(of: #"\\+Driver\\+[^"\\]+"#, options: .regularExpression) {
                return String(line[driver].split(separator: "\\").last ?? "") + ".sys"
            }
        }
        return nil
    }

    /// How long after a launch the log is read for a driver failure: an
    /// anti-cheat service starts with its program, well inside this.
    static let watchFor: Duration = .seconds(60)
    static let pollEvery: Duration = .seconds(5)

    /// Reads what Wine's log gained after `offset`, every few seconds for
    /// ``watchFor``, and answers the first driver it names.
    static func watch(from offset: UInt64, log: URL = WineLog.fileURL) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now + watchFor
        while clock.now < deadline {
            try? await Task.sleep(for: pollEvery)
            guard let handle = try? FileHandle(forReadingFrom: log) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd() else { continue }
            if let driver = driver(in: String(decoding: data, as: UTF8.self)) { return driver }
        }
        return nil
    }

    static func size(of url: URL = WineLog.fileURL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
