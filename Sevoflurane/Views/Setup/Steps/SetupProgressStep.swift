import Propofol
import SwiftUI

/// The work: one bar for the whole pass with the stage it is in, the stages
/// behind a disclosure, and under them the question being asked while it
/// runs. The buttons at the bottom belong to that question.
struct SetupProgressStep: View {
    let store: SetupStore

    var body: some View {
        // A pass that stopped takes the screen's buttons: the question waits
        // until the work runs again.
        let card = store.hasFailed ? nil : store.card
        SetupScreenLayout(hasButtons: card != nil || store.hasFailed) {
            SetupPage(title: title, subtitle: subtitle) {
                SetupPassSummary(store: store)
                switch card {
                case .sharing: SetupSharingCard()
                case .toolkit: SetupToolkitCard(store: store)
                case nil: EmptyView()
                }
            }
        } secondary: {
            switch card {
            case .sharing:
                Button("Don\u{2019}t Share") { store.answerSharing(false) }
            case .toolkit:
                Button("Not Now") { store.declineToolkit() }
            case nil:
                if store.offersEngineFile {
                    Button("Use a Downloaded File…") {
                        if let file = EngineFilePanel.choose() { store.tryAgain(withEngineFile: file) }
                    }
                    .help("Installs from a dormison-r<N>.tar.xz you downloaded from the Dormison releases, with its .sig beside it.")
                }
            }
        } primary: {
            switch card {
            case .sharing:
                Button("Share") { store.answerSharing(true) }
            case .toolkit:
                if !store.toolkitIsOpen {
                    Button("Sign In to Apple") { store.openToolkitPage() }
                }
            case nil:
                if store.hasFailed {
                    Button("Try Again") { store.tryAgain() }
                }
            }
        }
    }

    private var title: LocalizedStringResource {
        if store.workIsDone { return "Steam is installed" }
        return store.isAdopting ? "Getting Steam ready" : "Setting up Steam"
    }

    private var subtitle: LocalizedStringResource? {
        if store.workIsDone { return "One thing before it opens." }
        if store.hasFailed { return "Try Again takes up where it stopped." }
        return "You can close this window. Setup continues in the menu bar."
    }
}

/// How far the pass is: the stage under way in words, one bar across every
/// stage, the amount where the app knows one, and a failure where it stopped
/// with the way to try again.
struct SetupPassSummary: View {
    let store: SetupStore

    private var provisioner: Provisioner {
        store.provisioner
    }

    var body: some View {
        SetupList {
            VStack(alignment: .leading, spacing: SettingsMetrics.captionGap) {
                HStack(alignment: .firstTextBaseline) {
                    Text(status)
                        .font(SettingsType.title)
                    Spacer(minLength: Theme.Space.sm)
                    if let amount {
                        Text(amount)
                            .font(SettingsType.value)
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: store.workIsDone ? 1 : provisioner.passFraction)
                    .accessibilityLabel(Text(status))
            }
            if let failure = provisioner.failure, !failure.text.isEmpty {
                SettingsNotice(.failure, failure.text)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { store.showsDetails.toggle() }
            } label: {
                SettingsRow(title: store.showsDetails ? "Hide details" : "Show details") {} accessory: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(store.showsDetails ? 90 : 0))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if store.showsDetails {
                ForEach(provisioner.reports) { report in
                    SetupStageRow(report: report, fraction: provisioner.stageFraction)
                }
            }
        }
    }

    /// The stage under way, or what the pass came to. A download whose
    /// total is Steam's to know says how much has arrived.
    private var status: String {
        if store.workIsDone { return String(localized: "Steam is installed.") }
        if let failure = provisioner.failure {
            return failure.stage?.failedSentence ?? String(localized: "Setup stopped.")
        }
        guard let stage = provisioner.stage, provisioner.isWorking else {
            return String(localized: "Starting…")
        }
        let working = stage == .client && store.isAdopting ? String(localized: "Updating Steam…") : stage.workingSentence
        guard let bytes = provisioner.stageBytes else { return working }
        return String(localized: "\(working) \(bytes.formatted(.byteCount(style: .file))) received")
    }

    /// How far the whole pass is, in digits: the number the bar draws.
    private var amount: String? {
        guard provisioner.isWorking else { return nil }
        return provisioner.passFraction.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .towardZero))
    }
}

/// One stage in the details: its name, and a tick, a fraction in digits, a
/// failure mark, or nothing while it waits.
private struct SetupStageRow: View {
    let report: SetupStageReport
    let fraction: Double?

    var body: some View {
        SettingsRow(title: report.stage.title) {
            if case .working = report.state {
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)).rounded(rule: .towardZero))
                        .font(SettingsType.value)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Working…")
                        .font(SettingsType.status)
                        .foregroundStyle(.secondary)
                }
            }
        } accessory: {
            switch report.state {
            case .done: SettingsStateMark(kind: .done)
            case .failed: SettingsStateMark(kind: .failure)
            case .working, .pending: EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: Text {
        switch report.state {
        case .done: Text("Done")
        case .failed: Text("Failed")
        case .working: Text("Working…")
        case .pending: Text("Waiting")
        }
    }
}

extension SetupStage {
    /// The stage as the details list names it.
    var title: LocalizedStringResource {
        switch self {
        case .steamStop: "Closing Steam"
        case .rosetta: "Apple\u{2019}s Rosetta"
        case .engine: "Windows support"
        case .bottle: "Steam\u{2019}s folder"
        case .installer: "Steam\u{2019}s installer"
        case .client: "Steam"
        case .dependencies: "Fonts and extras"
        }
    }

    /// The stage while it is under way.
    var workingSentence: String {
        switch self {
        case .steamStop: String(localized: "Closing the Steam that is running…")
        case .rosetta: String(localized: "Installing Apple\u{2019}s Rosetta…")
        case .engine: String(localized: "Downloading Windows support…")
        case .bottle: String(localized: "Preparing Steam\u{2019}s folder…")
        case .installer: String(localized: "Installing Steam…")
        case .client: String(localized: "Downloading Steam…")
        case .dependencies: String(localized: "Installing fonts and extras…")
        }
    }

    /// The stage as the one that failed.
    var failedSentence: String {
        switch self {
        case .steamStop: String(localized: "The Steam that is running could not be closed.")
        case .rosetta: String(localized: "Apple\u{2019}s Rosetta could not be installed.")
        case .engine: String(localized: "Windows support could not be downloaded.")
        case .bottle: String(localized: "Steam\u{2019}s folder could not be prepared.")
        case .installer: String(localized: "Steam\u{2019}s installer did not finish.")
        case .client: String(localized: "Steam could not be downloaded.")
        case .dependencies: String(localized: "Fonts and extras could not be installed.")
        }
    }
}
