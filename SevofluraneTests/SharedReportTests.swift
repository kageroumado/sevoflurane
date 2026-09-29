import Foundation
import Testing
@testable import Sevoflurane

/// What a report sends to the community database, how it is queued, and
/// what the uploader does with the server's answers.
struct SharedReportTests {
    @Test
    func `a report on a Steam game sends exactly the wire keys and nothing that names anyone`() throws {
        let report = SharedReport(record: Self.fullRecord(), verdict: .playsWithFixes, note: "Pin the renderer to DXMT.")
        let data = try JSONEncoder.stats.encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "v", "appid", "engine", "renderer", "runner", "settings", "macos", "chip", "verdict", "note", "run_ref",
        ])
        #expect(object["v"] as? Int == 1)
        #expect(object["appid"] as? Int == 1_962_700)
        #expect(object["verdict"] as? String == "plays-with-fixes")
        #expect(object["run_ref"] as? String == "2026-09-25T14:12:06Z")
        #expect(object["settings"] as? [String: AnyHashable] == [
            "windows": "fixed", "tuning": "standard", "upscaler": "lanczos", "msync": true, "d3dmetal": "4.0 beta 2",
        ])
        let text = String(decoding: data, as: UTF8.self)
        for private_ in ["Secret Game Title", "/Users/", "C:\\\\", "0xdeadbeef", "a renderer note", "Game-Win64"] {
            #expect(!text.contains(private_))
        }
    }

    @Test
    func `a report on a program Steam does not know names its executable and product in place of an appid`() throws {
        var record = Self.fullRecord()
        record.appid = AdoptedPrograms.firstID + 3
        record.exe = "GenshinImpact.exe"
        let report = SharedReport(record: record, verdict: .plays, note: "")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.stats.encode(report)) as? [String: Any])
        #expect(Set(object.keys) == [
            "v", "exe", "product", "engine", "renderer", "runner", "settings", "macos", "chip", "verdict", "note", "run_ref",
        ])
        #expect(object["exe"] as? String == "GenshinImpact.exe")
        #expect(object["product"] as? String == "Genshin Impact")
    }

    @Test
    func `every report encodes under the server's 4 KB item cap, a full note of four-byte characters on the longest configuration included`() throws {
        var record = Self.fullRecord()
        record.engine = String(repeating: "e", count: 48)
        record.renderer = String(repeating: "r", count: 32)
        record.upscaler = String(repeating: "u", count: 64)
        record.d3dmetal = String(repeating: "d", count: 32)
        record.chip = String(repeating: "c", count: 64)
        record.macos = "27.100.100"
        record.appid = AdoptedPrograms.firstID
        record.exe = String(repeating: "x", count: 255)
        record.product = String(repeating: "p", count: 255)
        let note = String(repeating: "\u{1F600}", count: SharedReport.noteLimit)
        let report = SharedReport(record: record, verdict: .plays, note: note)
        #expect(report.note.unicodeScalars.count == SharedReport.noteLimit)
        let bytes = try JSONEncoder.stats.encode(report).count
        #expect(bytes < SharedReport.itemLimit)
        let quoted = SharedReport(record: record, verdict: .plays, note: String(repeating: "\"\\", count: SharedReport.noteLimit / 2))
        #expect(try JSONEncoder.stats.encode(quoted).count < SharedReport.itemLimit)
    }

    @Test
    func `a note is tidied as the server tidies it and cut to its length`() {
        #expect(SharedReport.tidy("  Pin   the\trenderer. \r\n\n\n\nThen play.  \n\n") == "Pin the renderer.\n\nThen play.")
        #expect(SharedReport.tidy("\n\n") == "")
        let long = String(repeating: "é", count: 700)
        let report = SharedReport(record: Self.fullRecord(), verdict: .plays, note: long)
        #expect(report.note.unicodeScalars.count == SharedReport.noteLimit)
    }

    @Test
    func `the note checks are the server's: length, plain text, an e-mail address, a file path, and a fix that goes unnamed`() {
        let check = { SharedReport.noteProblem($0, verdict: .plays) }
        #expect(check("Runs fine at 60 fps.") == nil)
        #expect(check(String(repeating: "a", count: 601)) == .tooLong)
        #expect(check("fine\u{07}") == .notPlainText)
        #expect(check("mail me at someone@example.com") == .namesEmail)
        #expect(check("crashes reading /Users/me/Library/foo") == .namesPath)
        #expect(check("see ~/Library/Logs") == .namesPath)
        #expect(check("C:\\Games\\thing.exe fails") == .namesPath)
        #expect(check("look in Users/someone/Desktop") == .namesPath)
        #expect(check("the path is ／Users／me") == .namesPath)
        #expect(check("a/b/c is two segments") == .namesPath)
        #expect(check("see https://kagerou.glass/sevoflurane/games/ for more") == nil)
        #expect(check("60/120 fps") == nil)
        #expect(SharedReport.noteProblem("", verdict: .playsWithFixes) == .fixesUnnamed)
        #expect(SharedReport.noteProblem("  \n ", verdict: .playsWithFixes) == .fixesUnnamed)
        #expect(SharedReport.noteProblem("", verdict: .fails) == nil)
        #expect(SharedReport.noteProblem("Pin DXMT.", verdict: .playsWithFixes) == nil)
    }

    @Test
    func `the configuration chips are the page's: engine, renderer with its toolkit, then what was on, macOS and the chip`() {
        var record = Self.fullRecord()
        #expect(SharedReport.chips(for: record) == [
            "dormison-r16", "d3dmetal 4.0 beta 2", "lanczos", "msync+", "macOS 27.0.0", "Apple M4 Max",
        ])
        record.renderer = "dxmt"
        record.upscaler = "off"
        record.msync = false
        record.tuning = "experimental"
        record.runner = "nwjs"
        record.chip = nil
        #expect(SharedReport.chips(for: record) == ["dormison-r16", "dxmt", "NW.js runner", "experimental tuning", "macOS 27.0.0"])
    }

    @Test
    func `the verdicts are the server's four words`() {
        #expect(SharedReport.Verdict.allCases.map(\.rawValue) == ["plays", "plays-with-fixes", "launches", "fails"])
    }

    // MARK: - The queue and the ledger

    @Test
    func `the report queue survives a round trip through its file`() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let record = Self.fullRecord()
        let report = SharedReport(record: record, verdict: .launches, note: "Menu, then black.")
        let queued = StatsStore.QueuedReport(queued: Date(timeIntervalSince1970: 1_790_000_000), runID: record.id, report: report)
        StatsStore.writeReportQueue([queued, queued], to: url)
        #expect(StatsStore.readReportQueue(from: url) == [queued, queued])
        #expect(record.id == "1962700-2026-09-25T14:12:06Z")
    }

    @Test
    func `the ledger keeps one standing per run and replaces it when the server answers`() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reported-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let queued = Date(timeIntervalSince1970: 1_790_000_000)
        StatsStore.noteReported(StatsStore.Reported(runID: "1-t", verdict: .plays, queued: queued), in: url)
        StatsStore.noteReported(StatsStore.Reported(runID: "2-t", verdict: .fails, queued: queued), in: url)
        StatsStore.noteReported(StatsStore.Reported(runID: "1-t", verdict: .plays, queued: queued, sent: queued), in: url)
        #expect(StatsStore.readReported(from: url).map(\.runID) == ["2-t", "1-t"])
        #expect(StatsStore.reported(forRun: "1-t", in: url)?.sent == queued)
        #expect(StatsStore.reported(forRun: "3-t", in: url) == nil)
    }

    @Test
    func `a state written before reports existed still reads, and counts no sent reports`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"registered":"abc","seq":41,"sentRuns":3}"#.utf8).write(to: url)
        let state = StatsStore.readState(from: url)
        #expect(state.seq == 41)
        #expect(state.sentReports == nil)
    }

    // MARK: - The uploader's rules

    @Test
    func `the server's 202 names the refused items and why`() {
        let reply = Data(#"{"accepted":1,"rejected":[{"i":0,"why":"over 4 KB"},{"i":2,"why":"game not in the database"},{"i":3}]}"#.utf8)
        #expect(StatsUploader.rejections(in: reply) == [
            StatsUploader.Rejection(index: 0, why: "over 4 KB"),
            StatsUploader.Rejection(index: 2, why: "game not in the database"),
            StatsUploader.Rejection(index: 3, why: "no reason given"),
        ])
        #expect(StatsUploader.rejections(in: Data(#"{"accepted":2,"rejected":[]}"#.utf8)).isEmpty)
        #expect(StatsUploader.rejections(in: Data()).isEmpty)
    }

    @Test
    func `the registration cap is its own failure, waited out for a day rather than retried on the short backoff`() {
        let capped = StatsUploader.Failure.registrationCapped(reason: "too many new installs from this address today")
        #expect(StatsUploader.failureClass(of: capped) == .registrationCapped)
        #expect(StatsUploader.failureClass(of: StatsUploader.Failure.refused(status: 429, reason: "too many requests")) == .refused)
        #expect(StatsUploader.failureClass(of: StatsUploader.Failure.refused(status: 413, reason: nil)) == .refused)
        #expect(StatsUploader.registrationCapWait == .seconds(86400))
        #expect(StatsUploader.registrationCapWait > StatsUploader.backoff.last!)
        #expect(StatsUploader.reportBatchSize == 10)
    }

    static func fullRecord() -> RunRecord {
        RunRecord(
            t: "2026-09-25T14:12:06Z", appid: 1_962_700, name: "Secret Game Title",
            exe: "Game-Win64-Shipping.exe", engine: "dormison-r16", renderer: "d3dmetal", runner: "wine",
            arch: 64, windows: "fixed", tuning: "standard", upscaler: "lanczos", msync: true,
            d3dmetal: "4.0 beta 2", runtime: "unreal", macos: "27.0.0", chip: "Apple M4 Max", mac: "Mac16,5",
            gpuCores: 40, memoryGB: 64, product: "Genshin Impact", windowAfterSeconds: 6.2, durationSeconds: 900,
            fps: RunRecord.FrameRate(avg: 60, low1: 42, samples: 880, trace: "/Users/someone/Library/trace.csv"),
            resolution: RunRecord.Resolution(window: RunRecord.Pixels(width: 3456, height: 2234)),
            display: RunRecord.Display(refreshHz: 120, variable: true, virtual: false),
            exit: RunRecord.Exit(kind: .crash, code: -1),
            crash: RunRecord.Crash(code: "0xc0000005", flags: nil, address: "0xdeadbeef", module: "C:\\\\game.exe"),
            notes: ["a renderer note"], gameMode: true,
            host: RunRecord.Host(thermal: "nominal", load: 2),
        )
    }
}
