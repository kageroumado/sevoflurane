import Foundation
import Observation

/// What "How did it go?" knows and does for one run: the verdict and note a
/// person picks, the configuration attached from the record, and the send
/// that queues the report. Testable without a window: the send is injected,
/// and the ledger it writes is a URL.
@MainActor
@Observable
final class RunReportModel {
    let record: RunRecord
    /// Whether sharing is on; a report goes nowhere without it.
    let sharing: Bool
    var verdict: SharedReport.Verdict?
    var note = ""
    /// The run's standing once reported: from the ledger when the run was
    /// reported before, from this session's send after it.
    private(set) var reported: StatsStore.Reported?
    private let ledger: URL
    private let submit: (SharedReport, String) -> Void

    /// - Parameters:
    ///   - sharing: ``Preferences/sharesRunStats``, as the app reads it.
    ///   - ledger: Where a run's standing is read from and written to.
    ///   - submit: What sending means; the app queues the report for ``StatsUploader``.
    init(
        record: RunRecord,
        sharing: Bool = Preferences.sharesRunStats == true,
        ledger: URL = StatsStore.reportedURL,
        submit: @escaping (SharedReport, String) -> Void = StatsUploader.submit,
    ) {
        self.record = record
        self.sharing = sharing
        self.ledger = ledger
        self.submit = submit
        reported = StatsStore.reported(forRun: record.id, in: ledger)
    }

    /// The run's configuration as the game's page will show it.
    var chips: [String] {
        SharedReport.chips(for: record)
    }

    var noteLength: Int {
        note.unicodeScalars.count
    }

    var counter: String {
        "\(noteLength)/\(SharedReport.noteLimit)"
    }

    /// Why the note as typed would be refused, once a verdict is picked.
    var problem: SharedReport.NoteProblem? {
        verdict.flatMap { SharedReport.noteProblem(note, verdict: $0) }
    }

    var canSend: Bool {
        sharing && reported == nil && verdict != nil && problem == nil
    }

    /// Queues the report and marks the run reported. Answers whether it did:
    /// a second press, a missing verdict or a refused note send nothing.
    @discardableResult
    func send() -> Bool {
        guard canSend, let verdict else { return false }
        let report = SharedReport(record: record, verdict: verdict, note: note)
        let standing = StatsStore.Reported(runID: record.id, verdict: verdict, queued: .now)
        StatsStore.noteReported(standing, in: ledger)
        reported = standing
        submit(report, record.id)
        return true
    }
}
