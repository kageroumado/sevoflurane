import Foundation

/// Everything a run left behind, gathered into one directory it can be shared
/// from.
///
/// Wine's exception trail is in the app's own log, macOS writes `.ips` files
/// for the processes that took a signal, Unreal keeps `Saved/Crashes`, Unity
/// keeps `Player.log` under a company and a product that do not name the app
/// id, NW.js keeps a Crashpad database, and Steam keeps five logs of its own.
/// A report is all of them, read once, stripped by ``Redaction`` and
/// ``ReportStripper``, and written under one directory named for the run, to
/// be attached to an issue as it is.
nonisolated enum CrashCollector {
    /// Where reports live, one directory per run.
    static let root = AppIdentity.supportFolder
        .appendingPathComponent("Reports")

    /// The whole directory's budget, spent oldest first.
    static let maximumBytes = 200_000_000

    /// The compressed reports' own budget, beside the loose ones.
    static let maximumArchiveBytes = 500_000_000

    /// How much of one log is kept: the end, where the failure is.
    static let maximumBytesPerFile = 2_000_000

    /// A game's last write can land after the run record closed.
    static let graceAfterRun: TimeInterval = 300

    /// Where the collector reads and writes, injectable for tests.
    struct Places: Sendable {
        var reports = root
        var bottle = SteamBottle.root
        var steamLogs = SteamBottle.steamRoot.appendingPathComponent("logs")
        var diagnosticReports = UserHome.url
            .appending(path: "Library/Logs/DiagnosticReports")
        /// Account names to redact, which no rule can derive from the text.
        var personas: [String] = SteamAccounts.names()
        var ourImageMarkers = CrashCollector.ourImageMarkers
        var installDirectory: @Sendable (Int) -> URL? = {
            SharedGames.installed(appID: $0)?.directory
        }

        var gameLogs: @Sendable (RunRecord) -> [GameLogs.Collected] = {
            GameLogs.collect(for: [$0])
        }

        /// Whether a minidump, the process's memory, is copied whole
        /// (``DiagnosticLevel/keepsWholeDumps``).
        var keepsWholeDumps = DiagnosticLevel.current.keepsWholeDumps

        init() {}
    }

    /// `manifest.json`: what a report holds and what was taken out.
    struct Manifest: Codable, Equatable, Sendable {
        /// When the report was collected.
        var t: String
        var appid: Int
        /// The run's level-0 summary.
        var run: String
        var sources: [Source]
        var removed: [String]

        struct Source: Codable, Equatable, Sendable {
            var kind: String
            /// The path inside the report.
            var file: String
            /// Where it was read from, redacted.
            var from: String
            var bytes: Int
        }
    }

    struct Report: Sendable {
        let directory: URL
        let manifest: Manifest
    }

    /// Gathers everything this closed run left behind; its window decides
    /// which files belong to it. `wineTail` is what the Wine log gained
    /// during the run. Answers `nil` when nothing could be written.
    @discardableResult
    static func collect(
        for record: RunRecord, wineTail: String = "", places: Places = Places(),
    ) -> Report? {
        let manager = FileManager.default
        let directory = places.reports.appendingPathComponent(name(for: record))
        guard (try? manager.createDirectory(at: directory, withIntermediateDirectories: true))
            != nil else { return nil }
        var writer = Writer(directory: directory, personas: places.personas)
        // A run record names no one, and stays byte-exact for decoding.
        writer.write(
            runRecord(record), as: "run.json", kind: "run record", from: "the run log",
            stripped: true,
        )
        collectWineTrail(wineTail, into: &writer)
        collectCrashReports(for: record, places: places, into: &writer)
        collectGameLogs(for: record, places: places, into: &writer)
        collectUnity(for: record, places: places, into: &writer)
        collectNWJS(for: record, places: places, into: &writer)
        collectSteamLogs(for: record, places: places, into: &writer)
        collectDumps(for: record, places: places, into: &writer)
        let manifest = Manifest(
            t: runRecordStamp.string(from: .now),
            appid: record.appid,
            run: record.summary,
            sources: writer.sources,
            removed: ReportStripper.removed,
        )
        writer.writeManifest(manifest)
        groom(in: places.reports)
        return Report(directory: directory, manifest: manifest)
    }

    /// A report for a run that ended badly, or for every run where the level
    /// asks, compressed where it says so. `beforeCompressing` can add files
    /// (the app's doctor report) while it is still a directory.
    @discardableResult
    static func collectIfWanted(
        for record: RunRecord, wineTail: String,
        level: DiagnosticLevel = .current, places: Places = Places(),
        beforeCompressing: (Report) -> Void = { _ in },
    ) -> Report? {
        let ended = record.exit?.kind
        guard level.collectsEveryRun || collectedEndings.contains(where: { $0 == ended }) else { return nil }
        var places = places
        places.keepsWholeDumps = level.keepsWholeDumps
        guard let report = collect(for: record, wineTail: wineTail, places: places) else {
            return nil
        }
        beforeCompressing(report)
        if level.compressesReports { compress(report.directory, in: places.reports) }
        return report
    }

    /// The endings every level collects; an error exit is one because the
    /// next launch overwrites the game's log of why.
    static let collectedEndings: Set<RunRecord.Exit.Kind> = [.crash, .crashAtExit, .watchdog, .exitError]

    /// Puts `sevo doctor --json` from the bundled CLI in a report. Blocking;
    /// a pass past ``doctorTimeout`` is killed and left out. Answers `false`
    /// outside the app, which alone carries the helper.
    @discardableResult
    static func addDoctorReport(to report: Report) -> Bool {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return false }
        let url = report.directory.appendingPathComponent("doctor.json")
        guard runBounded(helper, ["doctor", "--json"], into: url, timeout: doctorTimeout) else { return false }
        // The doctor names paths and bottles; a report is shared.
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            try? Redaction.apply(to: text).write(to: url, atomically: true, encoding: .utf8)
        }
        return true
    }

    static let doctorTimeout: TimeInterval = 30

    /// Runs `tool` into the file `url` (a pipe could fill and block), killing
    /// it after `timeout`. Answers whether it exited cleanly with output;
    /// otherwise the file is removed.
    static func runBounded(_ tool: URL, _ arguments: [String], into url: URL, timeout: TimeInterval) -> Bool {
        let manager = FileManager.default
        guard manager.createFile(atPath: url.path, contents: nil),
              let output = try? FileHandle(forWritingTo: url) else { return false }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else {
            try? output.close()
            try? manager.removeItem(at: url)
            return false
        }
        let finished = exited.wait(timeout: .now() + timeout) == .success
        if !finished {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        try? output.close()
        let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard finished, process.terminationStatus == 0, size > 0 else {
            try? manager.removeItem(at: url)
            return false
        }
        return true
    }

    /// `<appid>-<start>`, sorting by app, then time.
    static func name(for record: RunRecord) -> String {
        let moment = record.t.replacingOccurrences(of: ":", with: "")
        return "\(record.appid)-\(moment)"
    }

    /// The run's own record, pretty enough to read in the report.
    private static func runRecord(_ record: RunRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Wine's exception trail

    /// The `+seh` records and the backtrace under them.
    private static func collectWineTrail(_ tail: String, into writer: inout Writer) {
        let lines = exceptionLines(in: tail)
        guard !lines.isEmpty else { return }
        writer.write(
            lines.joined(separator: "\n") + "\n", as: "wine-seh.txt",
            kind: "wine exception trail", from: "Sevoflurane-wine.log",
        )
    }

    /// Wine's exception lines: the `seh` channel, `ntdll`'s fatal sentence,
    /// and the backtrace and register dump rows.
    ///
    /// The rows go straight to stderr with no channel mark, so they are
    /// recognized by the heading they follow.
    static func exceptionLines(in text: String) -> [String] {
        var kept: [String] = []
        var inDump = false
        for line in text.split(whereSeparator: \.isNewline) {
            if exceptionMarkers.contains(where: { line.contains($0) }) {
                inDump = dumpHeadings.contains { line.contains($0) }
                kept.append(String(line))
            } else if inDump, isDumpRow(line) {
                kept.append(String(line))
            } else {
                inDump = false
            }
        }
        return kept
    }

    /// A frame number and an address, or a row of addresses alone.
    private static func isDumpRow(_ line: some StringProtocol) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.firstMatch(of: frameRow) != nil
            || ReportStripper.isAddressesOnly(trimmed)
    }

    private static let exceptionMarkers = [
        ":seh:", "sevo:crash", "Unhandled exception", "wine: Unhandled", "wine: Call from", "Backtrace:", "Register dump:",
        "stack overflow", "assertion failed",
    ]

    /// The markers that open a block whose following rows belong to it.
    private static let dumpHeadings = ["Backtrace:", "Register dump:"]

    // `nonisolated(unsafe)`: a `Regex` built from a literal holds no state.
    private nonisolated(unsafe) static let frameRow = /^(?:=>)?\s*\d+ 0x[0-9a-fA-F]+/

    // MARK: - macOS crash reports

    /// The `.ips` files macOS wrote for our processes during the run.
    private static func collectCrashReports(
        for record: RunRecord, places: Places, into writer: inout Writer,
    ) {
        guard let window = window(of: record) else { return }
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: places.diagnosticReports.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".ips") {
            let url = places.diagnosticReports.appendingPathComponent(name)
            guard CrashReportIPS.isOurs(
                url, prefixes: ourCrashReportPrefixes, pathMarkers: places.ourImageMarkers,
            ),
                let written = modified(url), window.contains(written),
                let text = CrashReportIPS.render(url, ours: { path in
                    places.ourImageMarkers.contains { path.contains($0) }
                }) else { continue }
            writer.write(
                text, as: "crashes/\((name as NSString).deletingPathExtension).txt",
                kind: "macOS crash report", from: "DiagnosticReports/\(name)",
            )
        }
    }

    /// Report file-name prefixes of our processes; a launcher-bundle game is
    /// matched by path instead
    /// (``CrashReportIPS/isOurs(_:prefixes:pathMarkers:)``).
    static let ourCrashReportPrefixes = [
        "wine", "wine64", "wine-preloader", "wineserver", "nwjs", "Sevoflurane", "steam",
        "sevo-", "winedevice", "services", "explorer", "start", "ExcUserFault_",
    ]

    /// Path fragments that mark an executable or image as ours.
    static let ourImageMarkers = ["Sevoflurane", "/Engines/", "D3DMetal", "/Renderers/"]

    // MARK: - The game's own logs

    /// ``GameLogs``'s files, stripped again for persona names a game prints.
    private static func collectGameLogs(
        for record: RunRecord, places: Places, into writer: inout Writer,
    ) {
        for log in places.gameLogs(record) {
            writer.write(log.text, as: log.path, kind: kind(ofGameLog: log.path), from: log.path)
        }
    }

    /// A game log's kind, from where it sits.
    private static func kind(ofGameLog path: String) -> String {
        let name = path.lowercased()
        if name.contains("crashcontext") || name.contains("/crashes/") { return "unreal crash" }
        if name.contains("player.log") || name.contains("output_log") { return "unity log" }
        if name.contains("_d3d11.log") || name.contains(".env") { return "renderer log" }
        return "game log"
    }

    /// Unity's older player writes beside the game, where ``GameLogs`` does
    /// not look.
    private static func collectUnity(
        for record: RunRecord, places: Places, into writer: inout Writer,
    ) {
        guard let install = places.installDirectory(record.appid) else { return }
        for entry in InstallDirectory.entries(in: install)
            where entry.isDirectory && entry.name.hasSuffix("_Data") {
            let log = entry.url.appendingPathComponent("output_log.txt")
            guard let text = ReportStripper.tail(
                of: log, limit: maximumBytesPerFile, personas: places.personas,
            ) else { continue }
            writer.write(
                text, as: "games/\(record.appid)/\(entry.name)-output_log.txt",
                kind: "unity log", from: "\(entry.name)/output_log.txt", stripped: true,
            )
        }
    }

    // MARK: - NW.js

    /// A NW.js game's own log, and what its Crashpad database holds.
    private static func collectNWJS(
        for record: RunRecord, places: Places, into writer: inout Writer,
    ) {
        guard let install = places.installDirectory(record.appid) else { return }
        let log = install.appendingPathComponent("debug.log")
        if let text = ReportStripper.tail(
            of: log, limit: maximumBytesPerFile, personas: places.personas,
        ) {
            writer.write(
                text, as: "games/\(record.appid)/debug.log", kind: "nw.js log",
                from: "debug.log", stripped: true,
            )
        }
        let crashpad = install.appendingPathComponent("User Data/Crashpad/reports")
        if let window = window(of: record) {
            writer.writeDumps(in: crashpad, as: "nwjs-dumps.txt", kind: "nw.js crashpad", within: window)
        }
    }

    // MARK: - Steam's own logs

    /// The lines Steam's logs gained during the run, picked by timestamp.
    private static func collectSteamLogs(
        for record: RunRecord, places: Places, into writer: inout Writer,
    ) {
        guard let window = window(of: record) else { return }
        for name in steamLogNames {
            let url = places.steamLogs.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { steamLogMoment(of: $0).map(window.contains) ?? false }
            guard !lines.isEmpty else { continue }
            writer.write(
                lines.joined(separator: "\n") + "\n", as: "steam/\(name)",
                kind: "steam log", from: "Steam/logs/\(name)",
            )
        }
    }

    static let steamLogNames = [
        "console_log.txt", "connection_log.txt", "bootstrap_log.txt", "gameprocess_log.txt",
    ]

    /// The moment at the head of a Steam log line, `[2026-09-11 17:23:09]`;
    /// lines without one are left out.
    static func steamLogMoment(of line: some StringProtocol) -> Date? {
        guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
        return steamLogStamp.date(from: String(line[line.index(after: line.startIndex) ..< end]))
    }

    // MARK: - Minidumps

    /// The run's minidumps, summarized, or copied whole where the level asks.
    private static func collectDumps(
        for record: RunRecord, places: Places, into writer: inout Writer,
    ) {
        guard let window = window(of: record) else { return }
        for user in InstallDirectory.entries(
            in: places.bottle.appendingPathComponent("drive_c/users"),
        ) where user.isDirectory {
            writer.writeDumps(
                in: user.url.appendingPathComponent("AppData/Local/CrashDumps"),
                as: "wine-dumps.txt", kind: "wine minidump", within: window,
                whole: places.keepsWholeDumps,
            )
        }
        guard let install = places.installDirectory(record.appid) else { return }
        writer.writeDumps(
            in: install, as: "game-dumps.txt", kind: "game minidump", within: window,
            whole: places.keepsWholeDumps,
        )
    }

    // MARK: - Compression

    /// Compresses a finished report into `archives/` and removes the loose
    /// directory. `tar -J`: the system `tar` carries liblzma, and `xz` is
    /// absent without Homebrew.
    @discardableResult
    static func compress(_ directory: URL, in root: URL = root) -> URL? {
        let manager = FileManager.default
        let archives = archives(in: root)
        try? manager.createDirectory(at: archives, withIntermediateDirectories: true)
        let archive = archives
            .appendingPathComponent("\(directory.lastPathComponent).tar.xz")
        try? manager.removeItem(at: archive)
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = [
            "--options=compression-level=9", "-cJf", archive.path,
            "-C", directory.deletingLastPathComponent().path, directory.lastPathComponent,
        ]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        guard (try? tar.run()) != nil else { return nil }
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, manager.fileExists(atPath: archive.path) else {
            try? manager.removeItem(at: archive)
            return nil
        }
        try? manager.removeItem(at: directory)
        groomArchives(in: root)
        return archive
    }

    /// Compressed reports, under a budget of their own.
    static func archives(in root: URL = root) -> URL {
        root.appendingPathComponent(archivesName)
    }

    private static let archivesName = "archives"

    /// Drops compressed reports, oldest first, until within budget.
    static func groomArchives(in root: URL = root, budget: Int = maximumArchiveBytes) {
        let directory = archives(in: root)
        let manager = FileManager.default
        var entries = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .map { name -> Entry in
                let url = directory.appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                return Entry(
                    url: url, bytes: values?.fileSize ?? 0, modified: modified(url) ?? .distantPast,
                )
            }
            .sorted { $0.modified < $1.modified }
        var total = entries.reduce(0) { $0 + $1.bytes }
        // The newest stays even alone over budget: it is the one just written.
        while total > budget, entries.count > 1 {
            let oldest = entries.removeFirst()
            try? manager.removeItem(at: oldest.url)
            total -= oldest.bytes
        }
    }

    // MARK: - The cap

    /// Drops whole reports, oldest first, until within budget.
    static func groom(in root: URL = root, budget: Int = maximumBytes) {
        var reports = self.reports(in: root)
        var total = reports.reduce(0) { $0 + $1.bytes }
        guard total > budget else { return }
        // The newest stays even alone over budget: it is the report being collected.
        while total > budget, reports.count > 1 {
            let oldest = reports.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.bytes
        }
    }

    /// One report on disk.
    struct Entry: Sendable {
        let url: URL
        let bytes: Int
        let modified: Date
    }

    /// Every report, oldest first.
    static func reports(in root: URL = root) -> [Entry] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> Entry? in
            guard name != archivesName else { return nil }
            let url = root.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { return nil }
            return Entry(
                url: url, bytes: bytes(of: url), modified: modified(url) ?? .distantPast,
            )
        }
        .sorted { $0.modified < $1.modified }
    }

    /// The report this run left, loose or compressed.
    static func report(for record: RunRecord, in root: URL = root) -> URL? {
        let manager = FileManager.default
        let directory = root.appendingPathComponent(name(for: record))
        if manager.fileExists(atPath: directory.path) { return directory }
        let archive = archives(in: root)
            .appendingPathComponent("\(name(for: record)).tar.xz")
        return manager.fileExists(atPath: archive.path) ? archive : nil
    }

    /// A loose report's exception lines and crash report headings.
    static func findings(in directory: URL, limit: Int = 12) -> [String] {
        var found: [String] = []
        if let trail = try? String(
            contentsOf: directory.appendingPathComponent("wine-seh.txt"), encoding: .utf8,
        ) {
            found += trail.split(whereSeparator: \.isNewline)
                .filter { $0.contains("Unhandled exception") || $0.contains("stack overflow") }
                .map(String.init)
        }
        let crashes = directory.appendingPathComponent("crashes")
        for entry in InstallDirectory.entries(in: crashes) where !entry.isDirectory {
            guard let text = try? String(contentsOf: entry.url, encoding: .utf8) else { continue }
            let heading = text.split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("type:") || $0.hasPrefix("signal:") }
                .joined(separator: " ")
            found.append("\(entry.name): \(heading.isEmpty ? "a crash report" : heading)")
        }
        return Array(found.prefix(limit))
    }

    /// The manifest of a report on disk, for the window that lists them.
    static func manifest(of directory: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func bytes(of directory: URL) -> Int {
        let manager = FileManager.default
        guard let walk = manager.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey],
        ) else { return 0 }
        var total = 0
        for case let url as URL in walk {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return total
    }

    // MARK: - Shared

    /// The stretch of time a run's own files were written in.
    static func window(of record: RunRecord) -> ClosedRange<Date>? {
        guard let start = runRecordStamp.date(from: record.t) else { return nil }
        return start ... start.addingTimeInterval((record.durationSeconds ?? 0) + graceAfterRun)
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Writes a report's files and lists them for the manifest.
    private struct Writer {
        let directory: URL
        let personas: [String]
        var sources: [Manifest.Source] = []

        /// One file, stripped unless the caller already did it.
        mutating func write(
            _ text: String?, as file: String, kind: String, from: String,
            stripped: Bool = false,
        ) {
            guard let text, !text.isEmpty else { return }
            let body = stripped ? text : ReportStripper.strip(text, personas: personas)
            let url = directory.appendingPathComponent(file)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            guard (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil else {
                return
            }
            sources.append(
                Manifest.Source(
                    kind: kind, file: file, from: Redaction.apply(to: from),
                    bytes: body.utf8.count,
                ),
            )
        }

        /// Summarizes the minidumps written during `window`, copying them
        /// when `whole`.
        mutating func writeDumps(
            in directory: URL, as file: String, kind: String, within window: ClosedRange<Date>,
            whole: Bool = false,
        ) {
            var lines: [String] = []
            for entry in InstallDirectory.entries(in: directory)
                where !entry.isDirectory && entry.name.lowercased().hasSuffix(".dmp") {
                guard let written = CrashCollector.modified(entry.url), window.contains(written) else {
                    continue
                }
                guard let dump = MinidumpMetadata.read(entry.url) else { continue }
                lines.append("\(entry.name): \(dump.summary)")
                if whole { copy(entry.url, as: "dumps/\(entry.name)", kind: kind) }
            }
            guard !lines.isEmpty else { return }
            write(
                lines.joined(separator: "\n") + "\n", as: file, kind: kind,
                from: Redaction.apply(to: directory),
            )
        }

        /// A file copied as it is, for the bytes no stripper can read.
        private mutating func copy(_ source: URL, as file: String, kind: String) {
            let target = directory.appendingPathComponent(file)
            let manager = FileManager.default
            try? manager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            guard (try? manager.copyItem(at: source, to: target)) != nil else { return }
            let size = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            sources.append(
                Manifest.Source(
                    kind: kind, file: file, from: Redaction.apply(to: source), bytes: size,
                ),
            )
        }

        func writeManifest(_ manifest: Manifest) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(manifest) else { return }
            try? data.write(to: directory.appendingPathComponent("manifest.json"))
        }
    }
}

/// Steam's own log moment: local time, seconds, in square brackets.
private nonisolated let steamLogStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()
