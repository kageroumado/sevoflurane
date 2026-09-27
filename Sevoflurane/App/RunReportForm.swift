import Propofol
import SwiftUI

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

// MARK: - The views

/// The card under a run in the Reports window: the question, or the answer
/// once it was given.
struct RunReportCard: View {
    @Bindable var model: RunReportModel
    /// Called once a report was queued, so the list's row can say so.
    var onSent: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("How did it go?")
                .font(.headline)
            if let reported = model.reported {
                ReportedLine(reported: reported)
            } else if model.sharing {
                Text("Tell other Mac players how this game ran on this configuration. The verdict, the note and the configuration below go to the public game database; the note is the only part you write.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                RunReportFields(model: model)
                HStack {
                    Spacer()
                    Button("Send") {
                        if model.send() { onSent?() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSend)
                }
            } else {
                Text(RunReportCard.sharingOffHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.lg)
        .glassCard()
    }

    static let sharingOffHint: LocalizedStringKey =
        "Turn on Share run statistics in Settings \u{203A} General \u{203A} Community to send a report about this run."
}

/// The verdict, the note with its counter, and the configuration as chips.
/// The Reports window and the crash prompt share it.
struct RunReportFields: View {
    @Bindable var model: RunReportModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(SharedReport.Verdict.allCases, id: \.self) { verdict in
                    VerdictButton(verdict: verdict, isSelected: model.verdict == verdict) {
                        model.verdict = verdict
                    }
                }
            }
            .controlSize(.small)
            TextEditor(text: $model.note)
                .font(.system(size: 12))
                .frame(minHeight: 54, maxHeight: 96)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.xs)
                .background(.quaternary.opacity(0.6), in: Theme.innerShape)
                .accessibilityLabel(Text("Note"))
            HStack(alignment: .firstTextBaseline) {
                if let problem = model.problem {
                    Text(problem.sentence)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Optional. Plain text, no paths or e-mail addresses; it is public.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.counter)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.noteLength > SharedReport.noteLimit ? .orange : .secondary)
            }
            WrappingLayout(spacing: Theme.Space.xs, lineSpacing: Theme.Space.xs) {
                ForEach(model.chips, id: \.self) { chip in
                    StateChip(text: chip)
                }
            }
        }
    }
}

/// One of the four verdicts; the picked one is filled.
private struct VerdictButton: View {
    let verdict: SharedReport.Verdict
    let isSelected: Bool
    let pick: () -> Void

    var body: some View {
        if isSelected {
            Button(verdict.displayName, action: pick)
                .buttonStyle(.borderedProminent)
        } else {
            Button(verdict.displayName, action: pick)
                .buttonStyle(.bordered)
        }
    }
}

/// A reported run's standing in one line.
struct ReportedLine: View {
    let reported: StatsStore.Reported

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            StateChip(
                text: String(localized: "Reported: \(reported.verdict.displayName)"),
                systemImage: reported.refused == nil ? "checkmark" : "exclamationmark.triangle",
                tint: reported.refused == nil ? .accentColor : .orange,
            )
            Text(standing)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var standing: String {
        if let refused = reported.refused {
            return String(localized: "The database refused it: \(refused)")
        }
        return reported.sent == nil
            ? String(localized: "Waiting to be sent.")
            : String(localized: "Sent. Thank you.")
    }
}
