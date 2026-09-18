import Foundation
import Testing
@testable import Sevoflurane

/// What the report window puts in front of a person, and what it hands over.
///
/// The view is checked through the model it reads: an issue's title and body,
/// the manifest that goes on the clipboard beside the zip, and the findings
/// read back out of a report on disk.
@MainActor
struct ReportWindowTests {
    private let manager = FileManager.default

    // MARK: - The issue

    @Test
    func `a crashed run's title names the module, the engine and the renderer`() {
        var record = Self.record()
        record.crash = RunRecord.Crash(
            code: "0xc0000005", flags: "0x0", address: "0xd7691", module: "opengl32.dll",
        )
        let title = ReportStore.title(for: record)
        #expect(title == "Demons Roots: crashed in opengl32.dll + 0xd7691 on dormison-r2/dxmt")
    }

    @Test
    func `a crash with no module falls back to the address, then to the code`() {
        var record = Self.record()
        record.crash = RunRecord.Crash(
            code: "0xc0000005", flags: nil, address: "0x43a1c0", module: nil,
        )
        #expect(ReportStore.title(for: record).contains("crashed in 0x43a1c0"))

        record.crash = RunRecord.Crash(code: "0xc0000005", flags: nil, address: nil, module: nil)
        #expect(ReportStore.title(for: record).contains("crashed in 0xc0000005"))
    }

    @Test
    func `a run that did not crash is titled by how it ended`() {
        var record = Self.record()
        record.exit = RunRecord.Exit(kind: .watchdog, code: nil)
        #expect(ReportStore.title(for: record) == "Demons Roots: ended watchdog on dormison-r2/dxmt")

        record.name = nil
        record.exit = nil
        #expect(ReportStore.title(for: record).hasPrefix("App 1933660: did not finish"))
    }

    @Test
    func `an issue url carries the title and the level-0 lines`() throws {
        var record = Self.record()
        record.crash = RunRecord.Crash(
            code: "0xc0000005", flags: nil, address: "0xd7691", module: "opengl32.dll",
        )
        record.stalls = [RunRecord.Stall(at: 120, duration: 3.2, unwedged: "sigcont")]
        record.notes = ["Not supported feature: X ×3"]
        record.exit = RunRecord.Exit(kind: .crash, code: 1)

        let url = try #require(ReportStore.issueURL(for: record))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com")
        #expect(components.path == "/kageroumado/sevoflurane/issues/new")

        let items = try #require(components.queryItems)
        let title = try #require(items.first { $0.name == "title" }?.value)
        #expect(title == ReportStore.title(for: record))
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body.contains("dormison-r2"))
        #expect(body.contains("exception 0xc0000005 in opengl32.dll at 0xd7691"))
        #expect(body.contains("stall at 120.0 s for 3.2 s — sigcont"))
        #expect(body.contains("renderer: Not supported feature: X ×3"))
        #expect(body.contains(ReportStore.contentsSentence))
    }

    @Test
    func `a run with no window says so rather than leaving the line out`() {
        let body = ReportStore.body(for: Self.record())
        #expect(body.contains("no window ever appeared"))
        #expect(!body.contains("fps:"))
    }

    // MARK: - The manifest

    @Test
    func `the manifest names the zip and everything that was taken out`() {
        let store = ReportStore()
        let text = store.manifest(zip: URL(filePath: "/Users/someone/Desktop/report.zip"))
        #expect(text.hasPrefix("Sevoflurane report"))
        // The path a person pastes into an issue is redacted like everything
        // else that leaves this Mac.
        #expect(text.contains("~/Desktop/report.zip"))
        #expect(!text.contains("/Users/someone"))
        for removal in ReportStripper.removed { #expect(text.contains(removal)) }
    }

    @Test
    func `the sentence before either button says what the zip holds`() {
        #expect(ReportStore.contentsSentence.contains("Steam ids"))
        #expect(ReportStore.contentsSentence.contains("account names"))
        #expect(ReportStore.contentsSentence.contains("taken out"))
    }

    // MARK: - What a report says

    @Test
    func `the findings are the exceptions and the crash reports in a report`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let report = root.appendingPathComponent("1933660-2026-09-11T172309Z")
        try manager.createDirectory(
            at: report.appendingPathComponent("crashes"), withIntermediateDirectories: true,
        )
        try Data("""
        err:seh:NtRaiseException Unhandled exception code c0000005 flags 0 addr 0x43a1c0
        Backtrace:
        =>0 0x000000000043a1c0 in opengl32.dll
        """.utf8).write(to: report.appendingPathComponent("wine-seh.txt"))
        try Data("""
        # wine64-2026-09-18.ips
        process: wine64
        type: EXC_BAD_ACCESS
        signal: SIGSEGV
        """.utf8).write(
            to: report.appendingPathComponent("crashes/wine64-2026-09-18.txt"),
        )

        let findings = CrashCollector.findings(in: report)
        #expect(findings.contains { $0.contains("Unhandled exception code c0000005") })
        #expect(findings.contains { $0.contains("EXC_BAD_ACCESS") && $0.contains("SIGSEGV") })
        // The backtrace rows are in the report; they are not findings.
        #expect(!findings.contains { $0.contains("Backtrace:") })
    }

    @Test
    func `a run with no report has no findings and no path`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        #expect(CrashCollector.report(for: Self.record(), in: root) == nil)
        #expect(CrashCollector.findings(in: root.appendingPathComponent("nowhere")).isEmpty)
    }

    @Test
    func `a compressed report is found where level two left it`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let archives = CrashCollector.archives(in: root)
        try manager.createDirectory(at: archives, withIntermediateDirectories: true)
        let name = CrashCollector.name(for: Self.record())
        let archive = archives.appendingPathComponent("\(name).tar.xz")
        try Data("not really an archive".utf8).write(to: archive)
        #expect(CrashCollector.report(for: Self.record(), in: root) == archive)
    }

    // MARK: - The list

    @Test
    func `a run's identity is its app and the moment it began`() {
        let first = Self.record()
        var second = Self.record()
        second.t = "2026-09-11T18:00:00Z"
        #expect(first.id != second.id)
        #expect(first.id == Self.record().id)
    }

    // MARK: - Scratch

    private func scratch() throws -> URL {
        let url = manager.temporaryDirectory
            .appendingPathComponent("report-window-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func record() -> RunRecord {
        RunRecord(
            t: "2026-09-11T17:23:09Z", appid: 1_933_660, name: "Demons Roots",
            exe: "game.exe", engine: "dormison-r2", renderer: "dxmt", runner: "wine",
            windows: "fixed", msync: true, macos: "27.0.0", durationSeconds: 842,
            host: RunRecord.Host(thermal: "nominal", load: 3.1),
        )
    }
}
