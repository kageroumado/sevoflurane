import Propofol
import SwiftUI

/// The first-run assistant: one page per ``SetupStep`` over a footer whose
/// buttons move the store on.
struct SetupView: View {
    let store: SetupStore
    let onFinished: () -> Void
    /// Which of Steam's windows the finish button would show; the button
    /// waits until it exists. A simulated run says library.
    var steamWindow: () -> SetupSteamWindow = { .library }
    /// Rebuilds the background helper when it will not start.
    var onRepairHelper: (() -> Void)?
    /// Fired once when provisioning completes, so the client starts behind
    /// the wizard and is loaded by the last page.
    var onProvisioned: () -> Void = {}
    /// The finish that leaves Steam signed out: the app then runs Windows
    /// programs from Quick Launch, and Steam's sign-in waits until asked for.
    var onSkipSignIn: (() -> Void)?
    /// Asks the window for its tall height (`true`) or its usual one, set by
    /// ``SetupWindow``.
    var resizeWindow: (_ tall: Bool) -> Void = { _ in }

    private var provisioner: Provisioner {
        store.provisioner
    }

    var body: some View {
        VStack(spacing: 0) {
            page
                .animation(.smooth, value: wantsTallWindow)
            footer
        }
        .frame(width: SetupMetrics.windowSize.width)
        .frame(maxHeight: .infinity)
        // The page fills the titlebar too and its top inset clears the traffic
        // lights; inside the safe area the footer would be cut off.
        .ignoresSafeArea()
        .onChange(of: wantsTallWindow, initial: true) { _, tall in resizeWindow(tall) }
        .task { await store.detect() }
        .onChange(of: provisioner.activity) { _, activity in
            if activity == .done { onProvisioned() }
        }
        .overlay(alignment: .topTrailing) {
            if provisioner.isDryRun { demoBadge }
        }
    }

    /// Marks a simulated run (`SetupDryRun.swift`).
    private var demoBadge: some View {
        Text("DEMO")
            .font(.caption2.bold())
            .foregroundStyle(.orange)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.15), in: Capsule())
            .padding(Theme.Space.md)
            .help("Simulated setup. Nothing on this Mac changes.")
    }

    @ViewBuilder private var page: some View {
        @Bindable var store = store
        switch store.step {
        case .welcome:
            SetupWelcomeStep()
        case .engine:
            SetupEngineStep(provisioner: provisioner, choice: $store.engineChoice, bundledEngine: store.bundledEngine)
        case .bottle:
            SetupBottleStep(
                candidates: store.bottleCandidates,
                choice: $store.bottleChoice,
                newName: $store.newBottleName,
                newNameObjection: store.newBottleObjection,
                downloadEverything: $store.downloadEverything,
            )
        case .steam:
            SetupInstallStep(provisioner: provisioner, isAdoptingSteam: store.adoptsSteam)
        case .graphics:
            SetupGraphicsStep(download: store.gptk, store: store.graphicsStore, isSimulated: provisioner.isDryRun)
        case .options:
            SetupOptionsStep(openAtLogin: $store.openAtLogin, installsCommand: $store.connectAgents)
        case .sharing:
            SetupSharingStep()
        case .done:
            SetupDoneStep(window: steamWindow())
        }
    }

    // MARK: - Footer

    private var footer: some View {
        SetupFooter {
            secondaryActions
        } primary: {
            primaryAction
        }
    }

    @ViewBuilder private var secondaryActions: some View {
        switch store.step {
        case .engine where store.engineChoice == .builtIn:
            Button(provisioner.engineTarball == nil ? "Choose an Engine File…" : "Change the Engine File…") {
                chooseEngineFile()
            }
        case .engine:
            Link("Get CrossOver", destination: URL(string: "https://www.codeweavers.com/crossover")!)
            Button("Check Again") { store.detectAgain() }
        case .steam where store.hasFailed:
            if provisioner.engineInstallPending {
                Button("Use a Downloaded Engine…") {
                    guard chooseEngineFile() else { return }
                    store.retry()
                }
            }
            Button("Try Again") { store.tryAgain() }
        case .sharing:
            Button("Not Now") { store.answerSharing(false) }
        case .done where steamWindow().isHelperDown:
            if let onRepairHelper {
                Button("Repair Background Helper", action: onRepairHelper)
            }
        case .done where steamWindow() == .signIn:
            if let onSkipSignIn {
                Button("Skip Sign-In", action: onSkipSignIn)
                    .help("Run Windows programs from Quick Launch. You can sign in to Steam later from the menu bar.")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch store.step {
        case .welcome:
            Button("Get Started") { store.advanceFromWelcome() }
        case .engine:
            Button("Continue") { store.advanceFromEngine() }
                .disabled(store.engineChoice == .crossover && provisioner.detection?.usableCrossOver == nil)
        case .bottle:
            Button("Continue") { store.advanceFromBottle() }
                .disabled(store.bottleChoice == nil && store.newBottleObjection != nil)
        case .steam:
            Button("Continue") { store.advanceFromSteam() }
                .disabled(provisioner.activity != .done)
        case .graphics:
            Button(store.graphicsStore?.d3dMetalVersions.isEmpty == false ? "Continue" : "Skip for Now") {
                store.advanceFromGraphics()
            }
            .disabled(store.gptk.isBusy)
        case .options:
            Button("Continue") { store.advanceFromOptions() }
        case .sharing:
            Button("Share Run Statistics") { store.answerSharing(true) }
        case .done:
            switch steamWindow() {
            case .signIn:
                Button("Log In to Steam") { onFinished() }
            case .library:
                Button("Open My Library") { onFinished() }
            case .starting, .helperDown:
                Button("Starting Steam…") {}
                    .disabled(true)
            }
        }
    }

    private var wantsTallWindow: Bool {
        store.step == .graphics && SetupGraphicsStep.hostsSignIn(store.gptk, isSimulated: provisioner.isDryRun)
    }

    @discardableResult
    private func chooseEngineFile() -> Bool {
        guard let tarball = EngineFilePanel.choose() else { return false }
        store.useEngineFile(tarball)
        return true
    }
}

/// What the assistant's finish button would put on screen.
enum SetupSteamWindow: Equatable {
    /// Steam is still coming up; neither of its windows exists yet.
    case starting
    /// The background helper that starts Steam will not run; the reason, as
    /// the supervisor words it.
    case helperDown(String)
    /// Steam's login window exists.
    case signIn
    /// Steam's library window exists.
    case library

    var isHelperDown: Bool {
        if case .helperDown = self { true } else { false }
    }
}
