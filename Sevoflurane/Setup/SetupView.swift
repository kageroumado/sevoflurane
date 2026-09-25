import Propofol
import SwiftUI

/// The first-run assistant. Zero questions on the happy path: every step has
/// a detected default, and
/// the user only chooses when the choice costs money (CrossOver) or is
/// genuinely ambiguous.
struct SetupView: View {
    let provisioner: Provisioner
    let onFinished: () -> Void
    /// Which of Steam's windows the finish button would show, and whether it
    /// exists yet: the button waits for it, so pressing it swaps the assistant
    /// for that window at once. A simulated run has no Steam and says library.
    var steamWindow: () -> SetupSteamWindow = { .library }
    /// Rebuilds the background helper when it will not start.
    var onRepairHelper: (() -> Void)?
    /// Fired once when provisioning completes, so the app can start the
    /// client behind the wizard — by the last page the window is already
    /// loaded and the finish button shows it instantly.
    var onProvisioned: () -> Void = {}
    /// The finish that leaves Steam signed out: the app then runs Windows
    /// programs from Quick Launch, and Steam's sign-in waits until asked for.
    var onSkipSignIn: (() -> Void)?
    /// Where the graphics step's store comes from. A simulated run supplies
    /// one with no engine behind it, which is what lets that step be walked
    /// at all: without it a dry run has to skip past it.
    var makeGraphics: (() -> GraphicsStore)?

    enum Step: String, CaseIterable {
        case welcome
        case engine
        case bottle
        case steam
        case graphics
        case options
        case sharing
        case done

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .engine: "Choose an engine"
            case .bottle: "Choose a Steam"
            case .steam: "Installing Steam"
            case .graphics: "DirectX 12 games"
            case .options: "Preferences"
            case .sharing: "Community"
            case .done: "Ready to play"
            }
        }
    }

    @State private var step: Step
    @State private var openAtLogin = true
    @State private var connectAgents = false
    @State private var engineChoice: SetupEngineChoice = .builtIn
    /// The engine tarball this copy of the app ships with, when it does.
    @State private var bundledEngine: URL?
    /// The bottle to adopt, or `nil` to build a fresh one.
    @State private var bottleChoice: String?
    @State private var newBottleName = SteamBottle.defaultName
    @State private var downloadEverything = BottleDependencies.installsEverything
    @State private var graphicsStore: GraphicsStore?
    /// Whether this run found Steam already in its bottle when it began.
    @State private var adoptsSteam = false
    @State private var gptk = GPTkDownload()

    /// A real run always opens on the welcome. The gallery draws every step at
    /// once, and each tile starts on the one it is there to show.
    init(
        provisioner: Provisioner,
        startingAt step: Step = .welcome,
        steamWindow: @escaping () -> SetupSteamWindow = { .library },
        onRepairHelper: (() -> Void)? = nil,
        onProvisioned: @escaping () -> Void = {},
        onSkipSignIn: (() -> Void)? = nil,
        makeGraphics: (() -> GraphicsStore)? = nil,
        onFinished: @escaping () -> Void,
    ) {
        self.provisioner = provisioner
        self.steamWindow = steamWindow
        self.onRepairHelper = onRepairHelper
        self.onProvisioned = onProvisioned
        self.onSkipSignIn = onSkipSignIn
        self.makeGraphics = makeGraphics
        self.onFinished = onFinished
        _step = State(initialValue: step)
        // Opening straight onto the graphics step skips the transition that
        // would otherwise build the store, so build it here instead.
        _graphicsStore = State(initialValue: step == .graphics ? makeGraphics?() : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            page
            footer
        }
        .frame(width: SetupMetrics.windowSize.width, height: SetupMetrics.windowSize.height)
        // The page is the whole window, titlebar included: its own top inset
        // clears the traffic lights. Inside the titlebar's safe area the fixed
        // frame is pushed down by the titlebar's height and the footer is cut
        // off at the bottom.
        .ignoresSafeArea()
        .task {
            if !provisioner.isDryRun {
                bundledEngine = EngineInstaller.bundledTarball()
            }
            await provisioner.refreshDetection()
        }
        .onChange(of: provisioner.activity) { _, activity in
            if activity == .done { onProvisioned() }
        }
        .overlay(alignment: .topTrailing) {
            if provisioner.isDryRun { demoBadge }
        }
    }

    /// Marks a simulated run (`SetupDryRun.swift`) so a screenshot can never
    /// be mistaken for a real provisioning pass.
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
        switch step {
        case .welcome:
            SetupWelcomeStep()
        case .engine:
            SetupEngineStep(provisioner: provisioner, choice: $engineChoice, bundledEngine: bundledEngine)
        case .bottle:
            SetupBottleStep(
                candidates: bottleCandidates,
                choice: $bottleChoice,
                newName: $newBottleName,
                newNameObjection: newBottleObjection,
                downloadEverything: $downloadEverything,
            )
        case .steam:
            SetupInstallStep(provisioner: provisioner, isAdoptingSteam: adoptsSteam)
        case .graphics:
            SetupGraphicsStep(download: gptk, store: graphicsStore, isSimulated: provisioner.isDryRun)
        case .options:
            SetupOptionsStep(openAtLogin: $openAtLogin, installsCommand: $connectAgents)
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
        switch step {
        case .engine where engineChoice == .builtIn:
            Button(provisioner.engineTarball == nil ? "Choose an Engine File…" : "Change the Engine File…") {
                chooseEngineFile()
            }
        case .engine:
            Link("Get CrossOver", destination: URL(string: "https://www.codeweavers.com/crossover")!)
            Button("Check Again") {
                Task { await provisioner.refreshDetection() }
            }
        case .steam where hasFailed:
            if provisioner.engineInstallPending {
                Button("Use a Downloaded Engine…") {
                    guard chooseEngineFile() else { return }
                    Task { await provisioner.retry() }
                }
            }
            Button("Try Again") {
                Task { await provisioner.retry() }
            }
        case .sharing:
            Button("Not Now") { answerSharing(false) }
        case .done where steamWindow().isHelperDown:
            if let onRepairHelper {
                Button("Repair Background Helper", action: onRepairHelper)
            }
        case .done where steamWindow() == .signIn:
            if let onSkipSignIn {
                Button("Skip Sign-In", action: onSkipSignIn)
                    .help("Run your own Windows programs from Quick Launch now, and sign in to Steam later from the menu bar")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch step {
        case .welcome:
            Button("Get Started") { advanceFromWelcome() }
        case .engine:
            Button("Continue") { advanceFromEngine() }
                .disabled(engineChoice == .crossover && provisioner.detection?.usableCrossOver == nil)
        case .bottle:
            Button("Continue") { advanceFromBottle() }
                .disabled(bottleChoice == nil && newBottleObjection != nil)
        case .steam:
            Button("Continue") { advanceFromSteam() }
                .disabled(provisioner.activity != .done)
        case .graphics:
            Button(graphicsStore?.d3dMetalVersions.isEmpty == false ? "Continue" : "Skip for Now") {
                step = .options
            }
            .disabled(gptk.isBusy)
        case .options:
            Button("Continue") { advanceFromOptions() }
        case .sharing:
            Button("Share Run Statistics") { answerSharing(true) }
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

    // MARK: - What the steps ask

    private var usesManagedEngine: Bool {
        if case .managed = Engine.active { true } else { false }
    }

    @discardableResult
    private func chooseEngineFile() -> Bool {
        guard let tarball = EngineFilePanel.choose() else { return false }
        provisioner.engineTarball = tarball
        return true
    }

    /// The Steam installations already on the machine. Only ever shown when
    /// the answer is genuinely ambiguous — one bottle named the way we would
    /// name it needs no question.
    private var bottleCandidates: [SetupDetection.Bottle] {
        provisioner.ownBottles.filter(\.hasSteam)
    }

    private var needsBottleChoice: Bool {
        bottleCandidates.count > 1
            || (bottleCandidates.first.map { $0.name != SteamBottle.defaultName } ?? false)
    }

    /// Why the typed name cannot be used, if it cannot. A bottle is a
    /// directory, and one that already exists belongs to whatever put it
    /// there — installing Steam into it is not ours to decide.
    private var newBottleObjection: String? {
        let name = newBottleName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give the bottle a name." }
        if name.contains("/") || name.contains(":") {
            return "Use a name without / or : in it."
        }
        if provisioner.ownBottles.contains(where: { $0.name == name }) {
            return "A bottle named “\(name)” already exists."
        }
        return nil
    }

    /// Whether the bottle being set up already carries a Steam install —
    /// adoption checks and updates a client instead of downloading one, and
    /// telling someone their installed Steam is being downloaded is a lie
    /// they will watch for minutes.
    private var isAdoptingSteam: Bool {
        bottleCandidates.contains { $0.name == SteamBottle.name }
    }

    private var hasFailed: Bool {
        if case .failed = provisioner.activity { true } else { false }
    }

    // MARK: - Moving on

    private func advanceFromWelcome() {
        guard provisioner.detection?.usableCrossOver != nil else {
            step = .engine
            return
        }
        advanceFromEngine()
    }

    private func advanceFromEngine() {
        guard needsBottleChoice else {
            beginProvisioning()
            return
        }
        // The bottle this Mac is set to drive, and when it does not exist yet, a new one by
        // that name: adopting a different bottle under it is never the default.
        let stored = SteamBottle.name
        if bottleCandidates.contains(where: { $0.name == stored }) {
            bottleChoice = stored
        } else {
            bottleChoice = nil
            newBottleName = stored
        }
        step = .bottle
    }

    private func advanceFromBottle() {
        let name = bottleChoice ?? newBottleName.trimmingCharacters(in: .whitespaces)
        EventLog.shared.log(
            .setup, bottleChoice == nil ? "setup: creating bottle \(name)" : "setup: adopting bottle \(name)",
        )
        provisioner.chooseBottle(named: name)
        // Before the stage that reads it: provisioning starts on this press
        // and installs the catalog it names.
        if !provisioner.isDryRun {
            BottleDependencies.installsEverything = downloadEverything
        }
        beginProvisioning()
    }

    private func beginProvisioning() {
        // Read before the first stage runs: a bottle that gets its Steam from
        // this run has one by the end of it, and would read as adopted.
        adoptsSteam = isAdoptingSteam
        step = .steam
        if provisioner.activity == .idle {
            Task { await provisioner.provisionAndConfigure() }
        }
    }

    /// After provisioning: the managed engine needs D3DMetal added for DX12,
    /// so offer it; CrossOver brings its own, so go straight to preferences.
    private func advanceFromSteam() {
        guard usesManagedEngine, makeGraphics != nil || !provisioner.isDryRun else {
            step = .options
            return
        }
        if graphicsStore == nil {
            graphicsStore = makeGraphics?() ?? GraphicsStore()
        }
        step = .graphics
    }

    private func advanceFromOptions() {
        provisioner.setOpenAtLogin(openAtLogin)
        if connectAgents, !provisioner.isDryRun {
            Task {
                if let failure = await AgentIntegration.install() {
                    EventLog.shared.log(.app, "sevo CLI install: \(failure)")
                }
            }
        }
        step = Preferences.sharesRunStats == nil ? .sharing : .done
    }

    /// Asked once: an answer from an earlier setup stands.
    private func answerSharing(_ shares: Bool) {
        if !provisioner.isDryRun {
            Preferences.sharesRunStats = shares
            EventLog.shared.log(.app, shares ? "run statistics: sharing" : "run statistics: not sharing")
        }
        step = .done
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
