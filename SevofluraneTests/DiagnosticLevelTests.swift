import Foundation
import Testing
@testable import Sevoflurane

/// What each diagnostic level turns on, what it tells the engine, and the one
/// rule that is easy to get backwards: a level folds onto the bottle's own
/// `wine-debug` string rather than replacing it, and level zero adds nothing
/// at all.
struct DiagnosticLevelTests {
    @Test
    func `the levels are ordered and named by the numbers the plan uses`() {
        #expect(DiagnosticLevel.zero.rawValue == 0)
        #expect(DiagnosticLevel.one.rawValue == 1)
        #expect(DiagnosticLevel.two.rawValue == 2)
        #expect(DiagnosticLevel.zero < .one)
        #expect(DiagnosticLevel.one < .two)
        #expect(DiagnosticLevel.allCases.count == 3)
        #expect(DiagnosticLevel.one.summary == "level 1 (diagnostics)")
    }

    @Test
    func `what each level turns on`() {
        #expect(!DiagnosticLevel.zero.collectsEveryRun)
        #expect(DiagnosticLevel.one.collectsEveryRun)
        #expect(DiagnosticLevel.two.collectsEveryRun)

        #expect(!DiagnosticLevel.zero.samplesPresents)
        #expect(DiagnosticLevel.one.samplesPresents)

        // A dump is the process's memory, so only the level someone set on
        // purpose keeps one, compresses, or samples the machine.
        #expect(!DiagnosticLevel.one.keepsWholeDumps)
        #expect(DiagnosticLevel.two.keepsWholeDumps)
        #expect(!DiagnosticLevel.one.compressesReports)
        #expect(DiagnosticLevel.two.compressesReports)
        #expect(DiagnosticLevel.one.hostSampleInterval == nil)
        #expect(DiagnosticLevel.two.hostSampleInterval == .seconds(10))

        // And only that level takes itself off again.
        #expect(!DiagnosticLevel.zero.isSingleRun)
        #expect(!DiagnosticLevel.one.isSingleRun)
        #expect(DiagnosticLevel.two.isSingleRun)
    }

    // MARK: - What the engine is told

    @Test
    func `level zero leaves the bottle's own channels alone`() {
        #expect(DiagnosticLevel.zero.wineChannels == nil)
        #expect(DiagnosticLevel.zero.channels(over: "-all,+seh") == "-all,+seh")
        #expect(DiagnosticLevel.zero.channels(over: WineLog.levelZero) == WineLog.levelZero)
    }

    @Test
    func `a level adds its channels and the bottle's own token still wins`() {
        let one = DiagnosticLevel.one.channels(over: "-all,+d3d")
        // The bottle asked for `-all`, so that is what `all` is; its `+d3d`
        // survives, and the level's own `+pid` and `+seh` are added.
        #expect(one.contains("-all"))
        #expect(!one.contains("err+all"))
        #expect(one.contains("+pid"))
        #expect(one.contains("+seh"))
        #expect(one.contains("+d3d"))
    }

    @Test
    func `level two adds the library-load channels and level one does not`() {
        let one = DiagnosticLevel.one.channels(over: WineLog.levelZero)
        let two = DiagnosticLevel.two.channels(over: WineLog.levelZero)
        #expect(!one.contains("+loaddll"))
        #expect(!one.contains("+module"))
        #expect(two.contains("+loaddll"))
        #expect(two.contains("+module"))
        #expect(two.contains("+seh"))
    }

    @Test
    func `the renderers are told where to log from level one up`() {
        #expect(DiagnosticLevel.zero.rendererLines.isEmpty)
        let one = DiagnosticLevel.one.rendererLines
        // All three renderers spell it their own way, so all three are named.
        #expect(one.contains { $0.hasPrefix("DXMT_LOG_LEVEL=") })
        #expect(one.contains { $0.hasPrefix("DXMT_LOG_PATH=") })
        #expect(one.contains("DXVK_LOG_LEVEL=info"))
        #expect(one.contains("D3DM_LOG=1"))
        // The path is the one the report already knows how to collect.
        #expect(one.contains("DXMT_LOG_PATH=\(DebugMode.rendererLogWindowsPath)"))

        let two = DiagnosticLevel.two.rendererLines
        #expect(two.contains("SEVO_PRESENTATION_LOG=1"))
        #expect(two.contains("SEVO_GFX_LOG=1"))
    }

    // MARK: - What a run's ending gets

    @Test
    func `a run that ended well is collected only from level one up`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(collect(Self.record(ending: .user), at: .zero, in: root) == nil)
        #expect(collect(Self.record(ending: .user), at: .one, in: root) != nil)
    }

    @Test
    func `a crash and a watchdog kill are collected at every level`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(collect(Self.record(ending: .crash), at: .zero, in: root) != nil)
        #expect(collect(Self.record(ending: .watchdog), at: .zero, in: root) != nil)
        #expect(collect(Self.record(ending: .crashAtExit), at: .zero, in: root) != nil)
    }

    @Test
    func `an error exit is collected at every level, for the game's own log`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(collect(Self.record(ending: .exitError), at: .zero, in: root) != nil)
        #expect(collect(Self.record(ending: .stopped), at: .zero, in: root) == nil)
    }

    @Test
    func `level two leaves a compressed report and no loose directory`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let reports = root.appendingPathComponent("Reports")

        let report = try #require(collect(Self.record(ending: .crash), at: .two, in: root))
        let manager = FileManager.default
        #expect(!manager.fileExists(atPath: report.directory.path))
        let archive = CrashCollector.archives(in: reports)
            .appendingPathComponent("\(report.directory.lastPathComponent).tar.xz")
        #expect(manager.fileExists(atPath: archive.path))
        // And the archive really is one: its table of contents names the run.
        #expect(try contents(of: archive).contains(report.directory.lastPathComponent))
    }

    @Test
    func `the oldest archives go when they are over their budget`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let archives = CrashCollector.archives(in: root)
        let manager = FileManager.default
        try manager.createDirectory(at: archives, withIntermediateDirectories: true)
        var made: [URL] = []
        for index in 0 ..< 3 {
            let url = archives.appendingPathComponent("480-\(index).tar.xz")
            try Data(repeating: 0, count: 40_000).write(to: url)
            try manager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(1_700_000_000 + index))],
                ofItemAtPath: url.path,
            )
            made.append(url)
        }
        CrashCollector.groomArchives(in: root, budget: 100_000)
        #expect(!manager.fileExists(atPath: made[0].path))
        #expect(manager.fileExists(atPath: made[2].path))
    }

    // MARK: - Scratch

    private func collect(
        _ record: RunRecord, at level: DiagnosticLevel, in root: URL,
    ) -> CrashCollector.Report? {
        var places = CrashCollector.Places()
        places.reports = root.appendingPathComponent("Reports")
        places.steamLogs = root.appendingPathComponent("logs")
        places.bottle = root.appendingPathComponent("bottle")
        places.diagnosticReports = root.appendingPathComponent("DiagnosticReports")
        places.personas = []
        places.installDirectory = { _ in nil }
        places.gameLogs = { _ in [] }
        return CrashCollector.collectIfWanted(
            for: record, wineTail: "err:seh:x Unhandled exception code c0000005 flags 0 addr 0x1",
            level: level, places: places,
        )
    }

    /// What a `.tar.xz` holds, asked of the same tar that wrote it.
    private func contents(of archive: URL) throws -> String {
        let pipe = Pipe()
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-tJf", archive.path]
        tar.standardOutput = pipe
        try tar.run()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        tar.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-level-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func record(ending: RunRecord.Exit.Kind) -> RunRecord {
        RunRecord(
            t: "2026-09-18T01:02:03Z", appid: 480, engine: "dormison-r11", renderer: "dxmt",
            runner: "wine", windows: "fixed", msync: true, macos: "27.0.0",
            durationSeconds: 12, exit: RunRecord.Exit(kind: ending, code: nil),
            host: RunRecord.Host(thermal: "nominal", load: 1),
        )
    }
}
