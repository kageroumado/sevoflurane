import Foundation

/// A Windows program that tried to load its own kernel driver: kernel
/// anti-cheat, and some DRM. Wine runs no third-party drivers, so the
/// driver's service fails to load. A program that requires it quits or waits
/// with nothing on screen, and Wine's log is the only place that says why; a
/// program that carries on without it draws as usual.
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

    /// What the log says about a launched program.
    enum Outcome: Equatable {
        /// One of the program's processes presented a frame.
        case presented
        /// A driver failed to load and nothing of the program has drawn.
        case driverFailed(String)
        case nothing
    }

    /// What `text`, the log since the program's launch, says about it. The
    /// program's processes are its own executable and any process started
    /// with no Steam app id outside Wine's own: a launcher's game is the
    /// second. A frame presented by any of them answers ``Outcome/presented``
    /// whatever driver failed.
    static func outcome(in text: String, program exe: String) -> Outcome {
        let wanted = exe.lowercased()
        var programPIDs: Set<Substring> = []
        var presentedPIDs: Set<Substring> = []
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("sevo:") {
            if let match = line.firstMatch(of: run) {
                let name = match.output.2.lowercased()
                if name == wanted || (match.output.3 == "none" && !wineOwn.contains(name)) {
                    programPIDs.insert(match.output.1)
                }
            } else if let match = line.firstMatch(of: firstPresent) {
                presentedPIDs.insert(match.output.1)
            }
        }
        if !programPIDs.isDisjoint(with: presentedPIDs) { return .presented }
        return driver(in: text).map(Outcome.driverFailed) ?? .nothing
    }

    /// Reads what Wine's log gained after `offset`, every few seconds for
    /// ``watchFor``, and answers the driver that failed when the program
    /// drew nothing by the end of it. A frame from the program ends the watch
    /// with nothing to say.
    static func watch(from offset: UInt64, program exe: String, log: URL = WineLog.fileURL) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now + watchFor
        var last = Outcome.nothing
        while clock.now < deadline {
            try? await Task.sleep(for: pollEvery)
            guard let handle = try? FileHandle(forReadingFrom: log) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd() else { continue }
            last = outcome(in: String(decoding: data, as: UTF8.self), program: exe)
            if last == .presented { return nil }
        }
        if case let .driverFailed(driver) = last { return driver }
        return nil
    }

    // The executable's name can carry spaces, so it runs to the app id.
    private nonisolated(unsafe) static let run = /sevo:run pid=(\d+) exe=(.+?) appid=(\S+)/
    private nonisolated(unsafe) static let firstPresent = /sevo:gfx pid=(\d+) first present/

    /// The prefix's own processes, which start with no app id and never draw
    /// for a program.
    private static let wineOwn: Set<String> = [
        "conhost.exe", "explorer.exe", "plugplay.exe", "rpcss.exe", "rundll32.exe", "services.exe",
        "start.exe", "svchost.exe", "tabtip.exe", "wineboot.exe", "winedbg.exe", "winedevice.exe",
    ]

    static func size(of url: URL = WineLog.fileURL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
