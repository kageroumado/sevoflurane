import Propofol
import SwiftUI

/// What happened to one run: the first finding's sentence and evidence, the
/// other findings as rows, then either the first finding's action or the
/// question of sending the report.
struct RunDiagnosisView: View {
    @Bindable var model: RunDiagnosisModel

    static let width: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            FindingHeader(finding: model.headline)
            if !model.others.isEmpty {
                OtherFindings(model: model)
            }
            switch model.face {
            case .findings: FindingsFace(model: model)
            case .report: ReportFace(model: model, report: model.report)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The cause first: its sentence, then the one line that shows it.
private struct FindingHeader: View {
    let finding: RunDiagnosis.Finding

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: finding.cause.symbol)
                .font(.system(size: 26))
                .foregroundStyle(finding.cause == .unexplained ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(finding.sentence)
                    .font(SettingsType.heading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.evidence)
                    .font(SettingsType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The findings under the first, each with its own action as a plain button.
private struct OtherFindings: View {
    let model: RunDiagnosisModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            ForEach(model.others) { finding in
                if finding.id != model.others.first?.id { Divider() }
                OtherFinding(
                    finding: finding, isTaken: model.taken.contains(finding.cause), isWorking: model.isWorking,
                ) { model.perform(finding) }
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: Theme.innerShape)
    }
}

/// One further finding: its sentence with the game as "it", its evidence, and
/// its action under them.
private struct OtherFinding: View {
    let finding: RunDiagnosis.Finding
    let isTaken: Bool
    let isWorking: Bool
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.captionGap) {
            Text(finding.brief)
                .font(SettingsType.title)
                .fixedSize(horizontal: false, vertical: true)
            Text(finding.evidence)
                .font(SettingsType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isTaken {
                SettingsStatus(.done, String(localized: "Done"))
                    .padding(.top, SettingsMetrics.captionGap)
            } else if let label = finding.action?.label {
                Button(label, action: perform)
                    .controlSize(.small)
                    .disabled(isWorking)
                    .padding(.top, SettingsMetrics.captionGap)
            }
        }
    }
}

/// The first finding's action, the report as the way past it, and the mute.
private struct FindingsFace: View {
    @Bindable var model: RunDiagnosisModel

    var body: some View {
        switch model.progress {
        case let .working(text): SettingsStatus(.working, text)
        case let .failed(text): SettingsStatus(.failure, text)
        case nil: EmptyView()
        }
        if model.headline.action?.changesTheGame == true {
            Text("Applies the next time the game starts. Settings \u{203A} Games can undo it.")
                .font(SettingsType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.canStopAsking {
            Toggle("Don\u{2019}t show this again for this game", isOn: $model.stopsAsking)
        }
        HStack(spacing: Theme.Space.sm) {
            Button("Send Report\u{2026}") { model.showReport() }
            Spacer()
            if let label = model.headline.action?.label {
                Button("Not Now") { model.notNow() }
                    .keyboardShortcut(.cancelAction)
                Button(label) { model.perform(model.headline) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking)
            } else {
                Button("OK") { model.notNow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Whether to send the run's report: what it contains, the community verdict
/// beside it, and the three answers.
private struct ReportFace: View {
    let model: RunDiagnosisModel
    @Bindable var report: ReportSendModel

    var body: some View {
        switch report.stage {
        case .asking:
            Text(InterfaceCopy.localized(ReportSendModel.offer))
                .font(SettingsType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HowDidItGo(report: report.report)
            if model.opensOnReport {
                Toggle("Never ask again", isOn: $report.neverAskAgain)
            }
            HStack(spacing: Theme.Space.sm) {
                Button(report.zip == nil ? "Show What Will Be Sent" : "Show in Finder") { report.show() }
                Spacer()
                Button("Don\u{2019}t Send") { report.decline() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { report.send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .preparing:
            SettingsStatus(.working, String(localized: "Gathering the logs…"))
        case .sending:
            SettingsStatus(.working, String(localized: "Sending the report…"))
        case .sent:
            SettingsStatus(.done, String(localized: "Sent. Thank you."))
            closing
        case .kept:
            SettingsStatus(.warning, report.keptSentence)
            HStack {
                Button("Show in Finder") { report.show() }
                Spacer()
                Button("Close") { report.finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case let .failed(reason):
            SettingsStatus(.failure, reason)
            closing
        }
    }

    private var closing: some View {
        HStack {
            Spacer()
            Button("Close") { report.finish() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The community report's fields, its standing once sent, or the one line
/// saying where sharing is turned on.
private struct HowDidItGo: View {
    let report: RunReportModel

    var body: some View {
        if let reported = report.reported {
            ReportedLine(reported: reported)
        } else if report.sharing {
            Text("How did it go? Sending also tells other Mac players, with the configuration below.")
                .font(SettingsType.title.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            RunReportFields(model: report)
        } else {
            Text(RunReportCard.sharingOffHint)
                .font(SettingsType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension RunDiagnosis.Action {
    /// Whether taking it changes how the game starts next time.
    var changesTheGame: Bool {
        switch self {
        case .apply, .install: true
        case .open, .sendReport: false
        }
    }
}

private extension RunDiagnosis.Cause {
    /// The symbol beside the first finding.
    var symbol: String {
        switch self {
        case .kernelDriver: "lock.shield"
        case .missingLibrary: "shippingbox"
        case .videoDecodedNothing: "film"
        case .suggestedFix: "person.2"
        case .unityStartup, .unrealException, .crashed, .quitWhileStarting: "exclamationmark.triangle.fill"
        case .stalled: "hourglass"
        case .notAnswering: "hand.raised"
        case .threadSpin: "cpu"
        case .droppedShader: "square.dashed"
        case .unexplained: "questionmark.circle"
        }
    }
}
