import Propofol
import SwiftUI

/// The work: one bar for the whole pass with the stage it is in, the stages
/// behind a disclosure, and under them the question being asked while it
/// runs. The buttons at the bottom belong to that question, or to a pass
/// that stopped.
struct SetupProgressStep: View {
    let store: SetupStore

    var body: some View {
        // A pass that stopped takes the screen's buttons: the question waits
        // until the work runs again.
        let card = store.hasFailed ? nil : store.card
        SetupScreenLayout(hasButtons: card != nil || store.hasFailed) {
            SetupPage(title: title, subtitle: subtitle) {
                // Once Steam is in, the screen is the question's alone.
                if !store.workIsDone {
                    SetupPassSummary(store: store)
                }
                if !store.toolkit.items.isEmpty, store.toolkit.failedItems.isEmpty {
                    SetupToolkitStatus(download: store.toolkit)
                }
                switch card {
                case .sharing: SetupSharingCard()
                case .toolkit: SetupToolkitCard(store: store)
                case nil: EmptyView()
                }
            }
        } secondary: {
            switch card {
            case .sharing: Button("Don\u{2019}t Share") { store.answerSharing(false) }
            case .toolkit: Button("Not Now") { store.declineToolkit() }
            case nil: EmptyView()
            }
        } primary: {
            switch card {
            case .sharing:
                Button("Share") { store.answerSharing(true) }
            case .toolkit:
                if !store.toolkit.failedItems.isEmpty {
                    Button("Try Again") { store.retryToolkit() }
                } else if !store.toolkitIsOpen {
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
        if store.hasFailed { return "Setup stopped" }
        if store.workIsDone { return "Steam is installed" }
        return store.isAdopting ? "Getting Steam ready" : "Setting up Steam"
    }

    private var subtitle: LocalizedStringResource? {
        if store.hasFailed { return nil }
        if store.workIsDone { return "One question before it opens." }
        return "You can close this window. Setup continues in the menu bar."
    }
}

/// How far the pass is: the stage under way in words, one bar across every
/// stage with its fraction in digits, the time a download of known size
/// still takes, and a failure where it stopped.
struct SetupPassSummary: View {
    let store: SetupStore

    private var provisioner: Provisioner {
        store.provisioner
    }

    var body: some View {
        @Bindable var store = store
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
                ProgressView(value: provisioner.passFraction)
                    .accessibilityLabel(Text(status))
            }
            if let failure = provisioner.failure {
                SetupFailureNote(store: store, failure: failure)
            }
            SetupDisclosureRow(title: store.showsDetails ? "Hide details" : "Show details", isOpen: $store.showsDetails)
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

    /// How far the whole pass is, in digits: the number the bar draws. A
    /// download of known size adds the time it still takes.
    private var amount: String? {
        guard provisioner.isWorking else { return nil }
        let percent = provisioner.passFraction.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .towardZero))
        guard let seconds = provisioner.stageSecondsLeft else { return percent }
        return "\(percent) · \(Self.timeLeft(seconds))"
    }

    /// "about 4 minutes left", in whole minutes; under one, "less than a minute left".
    static func timeLeft(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        guard minutes >= 1 else { return String(localized: "less than a minute left") }
        return minutes == 1 ? String(localized: "about 1 minute left") : String(localized: "about \(minutes) minutes left")
    }
}

/// Why a pass stopped, under the sentence that names the stage: the cause
/// with the failure's mark, then what a second try does, in plain type.
private struct SetupFailureNote: View {
    let store: SetupStore
    let failure: SetupFailure

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.captionGap) {
            if !failure.cause.isEmpty {
                SettingsStatus(.failure, failure.cause)
            }
            if let advice = failure.advice {
                Text(advice)
                    .font(SettingsType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.offersEngineFile {
                Button("Downloaded it on another Mac? Choose the File…") {
                    if let file = EngineFilePanel.choose() { store.tryAgain(withEngineFile: file) }
                }
                .buttonStyle(.link)
                .font(SettingsType.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The toolkit's downloads once they run: one row that says how far they
/// are, while the screen goes on to its next question.
struct SetupToolkitStatus: View {
    let download: GPTkDownload

    var body: some View {
        SetupList {
            SettingsRow(
                title: "Game Porting Toolkit",
                caption: download.items.count > 1 ? String(localized: "Two versions. Some games need the newer one.") : "",
            ) {
                Text(state)
                    .font(SettingsType.value)
                    .foregroundStyle(.secondary)
            } accessory: {
                if !download.isBusy { SettingsStateMark(kind: .done) }
            }
        }
    }

    private var state: String {
        if let fraction = download.downloadFraction {
            let percent = fraction.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .towardZero))
            return String(localized: "downloading, \(percent)")
        }
        return download.isBusy ? String(localized: "installing") : String(localized: "installed")
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
        case .steamStop: String(localized: "Closing Steam…")
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
        case .steamStop: String(localized: "Steam is still running and did not quit.")
        case .rosetta: String(localized: "Apple\u{2019}s Rosetta could not be installed.")
        case .engine: String(localized: "Windows support could not be downloaded.")
        case .bottle: String(localized: "Steam\u{2019}s folder could not be prepared.")
        case .installer: String(localized: "Steam\u{2019}s installer stopped before it finished.")
        case .client: String(localized: "Steam could not be downloaded.")
        case .dependencies: String(localized: "Fonts and extras could not be installed.")
        }
    }
}
