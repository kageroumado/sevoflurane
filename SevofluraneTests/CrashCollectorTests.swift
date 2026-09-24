import Foundation
import Testing
@testable import Sevoflurane

/// What a collected report keeps, what it takes out, and what it never copies.
///
/// The fixtures are the real shapes: a Wine exception trail as `ntdll` prints
/// it, an `.ips` as macOS writes it, a `loginusers.vdf` as the client keeps it,
/// and a minidump built byte by byte from the format's own header.
struct CrashCollectorTests {
    private let manager = FileManager.default

    // MARK: - Stripping

    @Test
    func `a line of nothing but addresses is dropped`() {
        #expect(ReportStripper.isAddressesOnly("0x00007ffe 0x0000000a 0x0000dead"))
        #expect(ReportStripper.isAddressesOnly("  0x1004a2c00:  0x00000000 0x00000000"))
        #expect(ReportStripper.isAddressesOnly("deadbeef cafe"))
        #expect(!ReportStripper.isAddressesOnly("0x0043a1c0 opengl32.dll"))
        #expect(!ReportStripper.isAddressesOnly("err:seh:call_stack_handlers unwinding"))
        // Nothing to drop is not the same as nothing but addresses.
        #expect(!ReportStripper.isAddressesOnly(""))
        #expect(!ReportStripper.isAddressesOnly("   "))
    }

    @Test
    func `a runaway line is kept once with its count and the rest stay put`() {
        let spam = Array(repeating: "DXMT: Not supported feature: X", count: 40)
        let text = (["start"] + spam + ["end"]).joined(separator: "\n")
        let stripped = ReportStripper.strip(text)
        let lines = stripped.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines.first == "start")
        #expect(lines.last == "end")
        #expect(lines[1] == "DXMT: Not supported feature: X  ×40")
    }

    /// A backtrace through a recursing frame is the same line several times,
    /// and that repetition is the finding rather than the noise.
    @Test
    func `a frame repeated three times is left alone`() {
        let text = Array(repeating: "mono.dll+0x2b410", count: 3).joined(separator: "\n")
        #expect(ReportStripper.strip(text) == text)
    }

    @Test
    func `the account and a persona are gone from a stripped line`() {
        let text = "LogInit: saving to C:\\users\\crossover\\Saved as Wanderer"
        let stripped = ReportStripper.strip(text, personas: ["Wanderer"])
        #expect(stripped.contains("C:\\users\\~"))
        #expect(stripped.contains(Redaction.persona))
        #expect(!stripped.contains("Wanderer"))
    }

    // MARK: - The Steam accounts a redaction is given

    @Test
    func `the persona and account names are read out of loginusers`() {
        let vdf = """
        "users"
        {
        \t"76561198000000000"
        \t{
        \t\t"AccountName"\t\t"someone_example"
        \t\t"PersonaName"\t\t"Wanderer"
        \t\t"RememberPassword"\t\t"1"
        \t}
        }
        """
        let names = SteamAccounts.names(inLoginUsers: vdf)
        #expect(names.contains("someone_example"))
        #expect(names.contains("Wanderer"))
        // Longest first, so a name that contains another is replaced whole.
        #expect(names.first == "someone_example")
        // Only the two name keys; a flag is not a name.
        #expect(!names.contains("1"))
    }

    @Test
    func `a file that is not a loginusers yields no names`() {
        #expect(SteamAccounts.names(inLoginUsers: "").isEmpty)
        #expect(SteamAccounts.names(inLoginUsers: "not a vdf at all").isEmpty)
    }

    // MARK: - macOS crash reports

    @Test
    func `a crash report renders to its exception, its thread and our images`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let url = root.appendingPathComponent("wine64-2026-09-18-020000.ips")
        try Data(Self.crashReport.utf8).write(to: url)

        let identity = try #require(CrashReportIPS.identity(of: url))
        #expect(identity.process == "wine64")
        #expect(identity.path == "/Users/someone/Library/Application Support/Sevoflurane/Engines/r11/wine64")

        let text = try #require(CrashReportIPS.render(url) { $0.contains("/Engines/") })
        #expect(text.contains("EXC_BAD_ACCESS"))
        #expect(text.contains("SIGSEGV"))
        #expect(text.contains("faulting thread 1"))
        #expect(text.contains("d3d11.dll"))
        #expect(text.contains("DrawIndexed"))
        // A system image can name a frame; what it does not get is a line of
        // its own in the image list, where only ours are named.
        #expect(!text.contains("/usr/lib/system/"))
        #expect(text.contains("1 system images"))
    }

    @Test
    func `a file that is not a crash report renders to nothing`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let url = root.appendingPathComponent("junk.ips")
        try Data("not json\nnot json either\n".utf8).write(to: url)
        #expect(CrashReportIPS.render(url) { _ in true } == nil)
        #expect(CrashReportIPS.identity(of: url) == nil)
    }

    @Test
    func `a report named for an engine process is ours by its prefix`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let url = root.appendingPathComponent("wineserver-2026-09-23-013800.ips")
        try Data(Self.crashReport.utf8).write(to: url)
        #expect(CrashReportIPS.isOurs(url, prefixes: CrashCollector.ourCrashReportPrefixes, pathMarkers: []))
    }

    @Test
    func `a report named for a game's title is ours by the path in its body`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let url = root.appendingPathComponent("Subnautica 2-2026-09-23-013800.ips")
        try Data(Self.launcherCrashReport.utf8).write(to: url)

        let identity = try #require(CrashReportIPS.identity(of: url))
        #expect(identity.process == "Subnautica 2")
        #expect(identity.path == Self.launcherPath)
        #expect(CrashReportIPS.isOurs(
            url, prefixes: CrashCollector.ourCrashReportPrefixes,
            pathMarkers: CrashCollector.ourImageMarkers,
        ))
    }

    @Test
    func `a report for a process outside the project is refused`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let url = root.appendingPathComponent("Terminal-2026-09-23-013800.ips")
        try Data(Self.foreignCrashReport.utf8).write(to: url)
        #expect(CrashReportIPS.identity(of: url)?.path
            == "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        #expect(!CrashReportIPS.isOurs(
            url, prefixes: CrashCollector.ourCrashReportPrefixes,
            pathMarkers: CrashCollector.ourImageMarkers,
        ))
    }

    @Test
    func `a collected report keeps the game's own title-named crash report`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let places = Self.places(in: root)
        try manager.createDirectory(at: places.diagnosticReports, withIntermediateDirectories: true)
        let name = "Subnautica 2-2026-09-11-172400"
        let report = places.diagnosticReports.appendingPathComponent("\(name).ips")
        try Data(Self.launcherCrashReport.utf8).write(to: report)
        let window = try #require(CrashCollector.window(of: Self.record()))
        try manager.setAttributes(
            [.modificationDate: window.lowerBound.addingTimeInterval(60)],
            ofItemAtPath: report.path,
        )

        let collected = try #require(CrashCollector.collect(for: Self.record(), places: places))
        #expect(collected.manifest.sources.contains { $0.file == "crashes/\(name).txt" })
        let text = try String(
            contentsOf: collected.directory.appendingPathComponent("crashes/\(name).txt"),
            encoding: .utf8,
        )
        #expect(text.contains("EXC_BAD_ACCESS"))
    }

    // MARK: - Minidumps

    @Test
    func `a minidump gives up its size and its module names and nothing else`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let url = root.appendingPathComponent("game.exe.1234.dmp")
        try Self.minidump(modules: ["C:\\windows\\system32\\ntdll.dll", "game.exe"])
            .write(to: url)

        let metadata = try #require(MinidumpMetadata.read(url))
        #expect(metadata.modules == ["ntdll.dll", "game.exe"])
        #expect(metadata.bytes > 0)
        #expect(metadata.summary.contains("2 modules"))
        #expect(metadata.summary.contains("ntdll.dll"))
    }

    @Test
    func `a file with no minidump signature is not one`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let url = root.appendingPathComponent("not.dmp")
        try Data(repeating: 0, count: 256).write(to: url)
        #expect(MinidumpMetadata.read(url) == nil)
    }

    // MARK: - Steam's logs

    @Test
    func `a steam log line is placed by the moment at its head`() {
        let moment = CrashCollector.steamLogMoment(of: "[2026-09-11 17:23:09] AppID 480 adding")
        #expect(moment != nil)
        #expect(CrashCollector.steamLogMoment(of: "a continuation line") == nil)
        #expect(CrashCollector.steamLogMoment(of: "[not a date] x") == nil)
    }

    @Test
    func `only the run's own steam lines are collected`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)
        // Steam stamps its logs in local time and the run record is UTC, so
        // the fixture is written from the run's own moments rather than from
        // the same digits.
        let started = try #require(runRecordStamp.date(from: Self.record().t))
        let text = [
            "\(Self.steamStamp(started.addingTimeInterval(-3600))) before the run",
            "\(Self.steamStamp(started.addingTimeInterval(60))) AppID 367520 adding PID 1400",
            "\(Self.steamStamp(started.addingTimeInterval(86_400))) long after",
        ].joined(separator: "\n")
        try Data(text.utf8).write(to: logs.appendingPathComponent("console_log.txt"))

        var places = Self.places(in: root)
        places.steamLogs = logs

        let report = try #require(
            CrashCollector.collect(for: Self.record(), wineTail: "", places: places),
        )
        let steam = report.directory.appendingPathComponent("steam/console_log.txt")
        let collected = try String(contentsOf: steam, encoding: .utf8)
        #expect(collected.contains("AppID 367520 adding PID 1400"))
        #expect(!collected.contains("before the run"))
        #expect(!collected.contains("long after"))
    }

    // MARK: - A whole report

    @Test
    func `a report carries the run, the exception trail and a manifest`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        var places = Self.places(in: root)
        places.personas = ["Wanderer"]

        let report = try #require(
            CrashCollector.collect(for: Self.record(), wineTail: Self.wineTail, places: places),
        )
        #expect(report.directory.lastPathComponent == "367520-2026-09-11T172309Z")

        let trail = try String(
            contentsOf: report.directory.appendingPathComponent("wine-seh.txt"), encoding: .utf8,
        )
        #expect(trail.contains("Unhandled exception code c0000005"))
        #expect(trail.contains("opengl32.dll"))
        // The trail's bare address rows carry no symbol, so they are gone.
        #expect(!trail.contains("0x00000000 0x00000000"))
        // And a line of another channel was never the exception's.
        #expect(!trail.contains("fixme:d3d:"))

        let decoded = try #require(CrashCollector.manifest(of: report.directory))
        #expect(decoded == report.manifest)
        #expect(decoded.appid == 367_520)
        #expect(decoded.run.contains("dormison-r11"))
        #expect(decoded.sources.contains { $0.file == "wine-seh.txt" })
        #expect(decoded.sources.contains { $0.file == "run.json" })
        #expect(decoded.removed.contains { $0.contains("Steam ids") })

        let run = try String(
            contentsOf: report.directory.appendingPathComponent("run.json"), encoding: .utf8,
        )
        #expect(run.contains("\"appid\" : 367520"))
    }

    @Test
    func `a run with nothing behind it still gets a manifest`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let places = Self.places(in: root)

        let report = try #require(
            CrashCollector.collect(for: Self.record(), places: places),
        )
        #expect(report.manifest.sources.map(\.file) == ["run.json"])
        #expect(manager.fileExists(
            atPath: report.directory.appendingPathComponent("manifest.json").path,
        ))
    }

    // MARK: - The cap

    @Test
    func `the oldest reports go when the directory is over its budget`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let reports = root.appendingPathComponent("Reports")
        // Each one is a tenth of the budget, so eleven of them is over it and
        // the oldest has to go. The budget is the test's, not the app's:
        // writing 200 MB to say that a cap holds is a cap nobody can run.
        let budget = 100_000
        let each = budget / 10
        var made: [URL] = []
        for index in 0 ..< 11 {
            let directory = reports.appendingPathComponent("480-\(index)")
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: UInt8(ascii: "x"), count: each)
                .write(to: directory.appendingPathComponent("bulk.txt"))
            try manager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(1_700_000_000 + index))],
                ofItemAtPath: directory.path,
            )
            made.append(directory)
        }
        #expect(CrashCollector.reports(in: reports).count == 11)

        CrashCollector.groom(in: reports, budget: budget)
        let left = CrashCollector.reports(in: reports)
        #expect(left.count == 10)
        #expect(!manager.fileExists(atPath: made[0].path))
        #expect(manager.fileExists(atPath: made[10].path))
    }

    @Test
    func `a directory inside its budget is left alone`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let reports = root.appendingPathComponent("Reports")
        let directory = reports.appendingPathComponent("480-1")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("small".utf8).write(to: directory.appendingPathComponent("a.txt"))
        CrashCollector.groom(in: reports, budget: 100_000)
        #expect(manager.fileExists(atPath: directory.path))
    }

    @Test
    func `dumps written outside the run are left out`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let places = Self.places(in: root)
        let dumps = places.bottle.appendingPathComponent("drive_c/users/crossover/AppData/Local/CrashDumps")
        try manager.createDirectory(at: dumps, withIntermediateDirectories: true)
        let dump = try Self.minidump(modules: ["game.exe"])
        let during = dumps.appendingPathComponent("during.dmp")
        let before = dumps.appendingPathComponent("yesterday.dmp")
        try dump.write(to: during)
        try dump.write(to: before)
        let start = try #require(ISO8601DateFormatter().date(from: "2026-09-11T17:23:09Z"))
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(120)], ofItemAtPath: during.path)
        try manager.setAttributes([.modificationDate: start.addingTimeInterval(-86400)], ofItemAtPath: before.path)

        let report = try #require(CrashCollector.collect(for: Self.record(), places: places))
        let listed = try String(
            contentsOf: report.directory.appendingPathComponent("wine-dumps.txt"), encoding: .utf8,
        )
        #expect(listed.contains("during.dmp"))
        #expect(!listed.contains("yesterday.dmp"))
    }

    @Test
    func `the persona is stripped from a game's own logs`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        var places = Self.places(in: root)
        places.personas = ["Wanderer"]
        places.gameLogs = { _ in
            [GameLogs.Collected(path: "games/367520/Player.log", text: "Signed in as Wanderer\n")]
        }
        let install = root.appendingPathComponent("install")
        let data = install.appendingPathComponent("hollow_knight_Data")
        try manager.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("Welcome, Wanderer\n".utf8).write(to: data.appendingPathComponent("output_log.txt"))
        places.installDirectory = { _ in install }

        let report = try #require(CrashCollector.collect(for: Self.record(), places: places))
        let player = try String(
            contentsOf: report.directory.appendingPathComponent("games/367520/Player.log"), encoding: .utf8,
        )
        #expect(!player.contains("Wanderer"))
        let unity = try String(
            contentsOf: report.directory
                .appendingPathComponent("games/367520/hollow_knight_Data-output_log.txt"),
            encoding: .utf8,
        )
        #expect(!unity.contains("Wanderer"))
    }

    @Test
    func `a long file gives up only its tail and says what was cut`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let url = root.appendingPathComponent("big.log")
        let limit = 2_000_000
        var bytes = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        bytes.append(Data(repeating: UInt8(ascii: "b"), count: limit))
        try bytes.write(to: url)

        let (text, elided) = try #require(ReportStripper.rawTail(of: url, limit: limit))
        #expect(elided == "… the first 1000000 bytes are not in this report\n")
        #expect(text.utf8.count == limit)
        #expect(!text.contains("a"))
    }

    // MARK: - Fixtures

    /// Every path pointed inside `root`, and the two lookups that would
    /// otherwise reach this Mac's own Steam library stubbed out.
    private static func places(in root: URL) -> CrashCollector.Places {
        var places = CrashCollector.Places()
        places.reports = root.appendingPathComponent("Reports")
        places.steamLogs = root.appendingPathComponent("logs")
        places.bottle = root.appendingPathComponent("bottle")
        places.diagnosticReports = root.appendingPathComponent("DiagnosticReports")
        places.personas = []
        places.installDirectory = { _ in nil }
        places.gameLogs = { _ in [] }
        return places
    }

    private func scratch() throws -> URL {
        let url = manager.temporaryDirectory
            .appendingPathComponent("crash-collector-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A moment as Steam heads a log line with it: local time, in brackets.
    private static func steamStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "'['yyyy-MM-dd HH:mm:ss']'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func record() -> RunRecord {
        RunRecord(
            t: "2026-09-11T17:23:09Z", appid: 367_520, name: "Hollow Knight",
            exe: "hollow_knight.exe", engine: "dormison-r11", renderer: "dxmt", runner: "wine",
            windows: "fixed", msync: true, macos: "27.0.0", durationSeconds: 600,
            exit: RunRecord.Exit(kind: .crash, code: nil),
            host: RunRecord.Host(thermal: "nominal", load: 2.0),
        )
    }

    /// What the Wine log holds around an unhandled exception: the `seh`
    /// channel, the sentence before the process dies, the backtrace, and the
    /// rest of the log that is not any of it.
    private static let wineTail = """
    fixme:d3d:wined3d_check_device_format unhandled format
    wine: Unhandled page fault on read access to 0000000000000010
    err:seh:NtRaiseException Unhandled exception code c0000005 flags 0 addr 0x43a1c0
    Backtrace:
    =>0 0x000000000043a1c0 (0x00000000005dfa10) in opengl32.dll
      1 0x00000000004b2110 (0x00000000005dfa90) in hollow_knight.exe
    0x1004a2c00:  0x00000000 0x00000000 0x00000000 0x00000000
    fixme:d3d:something_else afterwards
    """

    /// The two documents of an `.ips`: a header line and the body.
    private static let crashReport = """
    {"app_name":"wine64","timestamp":"2026-09-18 02:00:00.00 +0200","procName":"wine64",\
    "os_version":"macOS 27.0 (26A428)","incident_id":"x","name":"wine64"}
    {
      "procName" : "wine64",
      "procPath" : "/Users/someone/Library/Application Support/Sevoflurane/Engines/r11/wine64",
      "osVersion" : { "train" : "macOS 27.0", "build" : "26A428" },
      "pid" : 4242,
      "faultingThread" : 1,
      "exception" : { "type" : "EXC_BAD_ACCESS", "signal" : "SIGSEGV", "codes" : "0x1, 0x10" },
      "threads" : [
        { "id" : 1, "frames" : [ { "imageOffset" : 16, "imageIndex" : 1 } ] },
        { "id" : 2, "triggered" : true, "frames" : [
            { "imageOffset" : 4386752, "symbol" : "DrawIndexed", "symbolLocation" : 96,
              "imageIndex" : 0 },
            { "imageOffset" : 40, "imageIndex" : 1 }
        ] }
      ],
      "usedImages" : [
        { "name" : "d3d11.dll", "uuid" : "aaaa", "base" : 1,
          "path" : "/Users/someone/Library/Application Support/Sevoflurane/Engines/r11/d3d11.dll" },
        { "name" : "libsystem_kernel.dylib", "uuid" : "bbbb", "base" : 2,
          "path" : "/usr/lib/system/libsystem_kernel.dylib" }
      ]
    }
    """

    /// Where a game run through its launcher bundle is, as the report's body
    /// spells it once its slashes are unescaped.
    private static let launcherPath =
        "/Users/someone/Library/Application Support/Sevoflurane/Launchers/1962700/Subnautica 2.app"
            + "/Contents/MacOS/Subnautica 2"

    /// A report for a game run through its launcher bundle: named for the
    /// game's title, with the path escaped the way the report writes it.
    private static let launcherCrashReport = """
    {"app_name":"Subnautica 2","timestamp":"2026-09-11 19:24:00.00 +0200",\
    "procName":"Subnautica 2","os_version":"macOS 27.0 (26A428)","incident_id":"y",\
    "name":"Subnautica 2"}
    {
      "procName" : "Subnautica 2",
      "procPath" : "\\/Users\\/someone\\/Library\\/Application Support\\/Sevoflurane\\/Launchers\\/1962700\\/Subnautica 2.app\\/Contents\\/MacOS\\/Subnautica 2",
      "pid" : 4243,
      "faultingThread" : 0,
      "exception" : { "type" : "EXC_BAD_ACCESS", "signal" : "SIGSEGV" },
      "threads" : [ { "id" : 1, "frames" : [ { "imageOffset" : 16, "imageIndex" : 0 } ] } ],
      "usedImages" : [
        { "name" : "libsystem_kernel.dylib", "uuid" : "bbbb", "base" : 2,
          "path" : "/usr/lib/system/libsystem_kernel.dylib" }
      ]
    }
    """

    /// A report for a process that is nobody's business here.
    private static let foreignCrashReport = """
    {"app_name":"Terminal","timestamp":"2026-09-11 19:24:00.00 +0200","procName":"Terminal",\
    "os_version":"macOS 27.0 (26A428)","incident_id":"z","name":"Terminal"}
    {
      "procName" : "Terminal",
      "procPath" : "\\/System\\/Applications\\/Utilities\\/Terminal.app\\/Contents\\/MacOS\\/Terminal",
      "pid" : 651,
      "exception" : { "type" : "EXC_CRASH", "signal" : "SIGABRT" },
      "threads" : [],
      "usedImages" : []
    }
    """

    /// A minidump with nothing in it but a module list — the header, one
    /// directory entry, the module records, and the names they point at.
    private static func minidump(modules: [String]) -> Data {
        let headerBytes = 32
        let directoryBytes = 12
        let moduleRecordBytes = 108
        let listStart = headerBytes + directoryBytes
        var data = Data()
        data += Data("MDMP".utf8)
        data += UInt32(42_899).littleEndian.data // version
        data += UInt32(1).littleEndian.data // one stream
        data += UInt32(headerBytes).littleEndian.data // the directory follows the header
        data += Data(repeating: 0, count: headerBytes - data.count)

        data += UInt32(4).littleEndian.data // ModuleListStream
        data += UInt32(0).littleEndian.data // size, which nothing reads
        data += UInt32(listStart).littleEndian.data

        data += UInt32(modules.count).littleEndian.data
        let namesStart = listStart + 4 + modules.count * moduleRecordBytes
        var nameOffset = namesStart
        var names = Data()
        for name in modules {
            var record = Data(repeating: 0, count: moduleRecordBytes)
            let rva = UInt32(nameOffset).littleEndian.data
            record.replaceSubrange(24 ..< 28, with: rva)
            data += record
            let units = Array(name.utf16)
            names += UInt32(units.count * 2).littleEndian.data
            for unit in units {
                names += unit.littleEndian.data
            }
            names += UInt16(0).littleEndian.data
            nameOffset += 4 + units.count * 2 + 2
        }
        return data + names
    }
}

private extension FixedWidthInteger {
    var data: Data {
        withUnsafeBytes(of: self) { Data($0) }
    }
}
