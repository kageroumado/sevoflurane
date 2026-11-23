import Propofol
import SwiftUI

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
/// The Reports window and the panel about a run share it.
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
