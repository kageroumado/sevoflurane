import Foundation
import Testing
@testable import Sevoflurane

/// "How did it go?": what it lets a person send, what it writes, and how a
/// run is named to `sevo report`.
@MainActor
struct RunReportModelTests {
    /// What the model handed to the uploader.
    private final class Sent {
        var reports: [(SharedReport, String)] = []
    }

    private static func model(
        sharing: Bool = true, record: RunRecord = SharedReportTests.fullRecord(),
    ) -> (RunReportModel, Sent, URL) {
        let ledger = FileManager.default.temporaryDirectory.appendingPathComponent("reported-\(UUID().uuidString).json")
        let sent = Sent()
        let model = RunReportModel(record: record, sharing: sharing, ledger: ledger) { sent.reports.append(($0, $1)) }
        return (model, sent, ledger)
    }

    @Test
    func `nothing goes without sharing, a verdict and a note the server would take`() {
        let (off, offSent, _) = Self.model(sharing: false)
        off.verdict = .plays
        #expect(!off.canSend)
        #expect(!off.send())
        #expect(offSent.reports.isEmpty)

        let (model, sent, ledger) = Self.model()
        defer { try? FileManager.default.removeItem(at: ledger) }
        #expect(!model.canSend)
        model.verdict = .playsWithFixes
        #expect(model.problem == .fixesUnnamed)
        #expect(!model.canSend)
        model.note = "see /Users/me/Library"
        #expect(model.problem == .namesPath)
        model.note = "Pin the renderer to DXMT."
        #expect(model.problem == nil)
        #expect(model.canSend)
        #expect(model.counter == "25/600")
        #expect(sent.reports.isEmpty)
    }

    @Test
    func `a send queues the report on the run's configuration, marks the run reported once, and the ledger remembers it`() throws {
        let (model, sent, ledger) = Self.model()
        defer { try? FileManager.default.removeItem(at: ledger) }
        model.verdict = .launches
        model.note = "  Menu,   then black.  "
        #expect(model.send())
        #expect(!model.canSend)
        #expect(!model.send())
        #expect(sent.reports.count == 1)
        let (report, runID) = try #require(sent.reports.first)
        #expect(runID == "1962700-2026-09-25T14:12:06Z")
        #expect(report.verdict == .launches)
        #expect(report.note == "Menu, then black.")
        #expect(report.appid == 1_962_700)
        #expect(report.engine == "dormison-r16")
        #expect(report.settings.d3dmetal == "4.0 beta 2")
        #expect(report.runRef == "2026-09-25T14:12:06Z")
        #expect(model.reported?.verdict == .launches)
        #expect(model.reported?.sent == nil)

        let again = RunReportModel(record: SharedReportTests.fullRecord(), sharing: true, ledger: ledger) { _, _ in }
        #expect(again.reported?.verdict == .launches)
        #expect(!again.canSend)
    }

    @Test
    func `the chips are the record's configuration as the page shows it`() {
        let (model, _, _) = Self.model()
        #expect(model.chips == ["dormison-r16", "d3dmetal 4.0 beta 2", "lanczos", "msync", "macOS 27.0.0", "Apple M4 Max"])
    }

    @Test
    func `the crash prompt carries the same model and queues the report with its send`() {
        let (report, sent, ledger) = Self.model()
        defer { try? FileManager.default.removeItem(at: ledger) }
        let model = CrashPromptModel(
            record: SharedReportTests.fullRecord(),
            bundle: { _ in throw CocoaError(.fileNoSuchFile) },
            upload: ReportUpload(installToken: "t", version: "1+1"),
            report: report,
        )
        model.report.verdict = .fails
        model.send()
        #expect(sent.reports.count == 1)
        #expect(sent.reports.first?.0.verdict == .fails)
        #expect(model.report.reported?.verdict == .fails)
    }

    @Test
    func `an appid names its newest run and a run id names that run`() {
        var first = SharedReportTests.fullRecord()
        first.t = "2026-09-25T10:00:00Z"
        var second = SharedReportTests.fullRecord()
        second.t = "2026-09-25T14:12:06Z"
        var other = SharedReportTests.fullRecord()
        other.appid = 508_440
        other.t = "2026-09-25T16:00:00Z"
        let records = [first, second, other]
        #expect(RunRecord.matching("1962700", in: records) == second)
        #expect(RunRecord.matching("508440", in: records) == other)
        #expect(RunRecord.matching("1962700-2026-09-25T10:00:00Z", in: records) == first)
        #expect(RunRecord.matching("999", in: records) == nil)
        #expect(RunRecord.matching("nonsense", in: records) == nil)
    }
}
