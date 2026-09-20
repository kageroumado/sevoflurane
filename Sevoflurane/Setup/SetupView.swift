import Propofol
import SwiftUI

/// The first-run assistant. Zero questions on the happy path: every step has
/// a detected default, and
/// the user only chooses when the choice costs money (CrossOver) or is
/// genuinely ambiguous.
struct SetupView: View {
    let provisioner: Provisioner
    let onFinished: () -> Void
    /// Reports whether Steam is sitting at its sign-in window, so the final
    /// button can say what clicking it will actually show.
    var signInPending: () -> Bool = { false }
    /// Fired once when provisioning completes, so the app can start the
    /// client behind the wizard — by the last page the window is already
    /// loaded and the finish button shows it instantly.
    var onProvisioned: () -> Void = {}
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
        case done

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .engine: "Choose an engine"
            case .bottle: "Choose a Steam"
            case .steam: "Installing Steam"
            case .graphics: "DirectX 12 games"
            case .options: "Preferences"
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
    @State private var gptk = GPTkDownload()

    /// A real run always opens on the welcome. The gallery draws every step at
    /// once, and each tile starts on the one it is there to show.
    init(
        provisioner: Provisioner,
        startingAt step: Step = .welcome,
        signInPending: @escaping () -> Bool = { false },
        onProvisioned: @escaping () -> Void = {},
        makeGraphics: (() -> GraphicsStore)? = nil,
        onFinished: @escaping () -> Void,
    ) {
        self.provisioner = provisioner
        self.signInPending = signInPending
        self.onProvisioned = onProvisioned
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
            SetupInstallStep(provisioner: provisioner, isAdoptingSteam: isAdoptingSteam)
        case .graphics:
            SetupGraphicsStep(download: gptk, store: graphicsStore, isSimulated: provisioner.isDryRun)
        case .options:
            SetupOptionsStep(openAtLogin: $openAtLogin, installsCommand: $connectAgents)
        case .done:
            SetupDoneStep(signInPending: signInPending())
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
        case .done:
            Button(signInPending() ? "Log In to Steam" : "Open My Library") { onFinished() }
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
        provisioner.detection?.steamBottles ?? []
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
        if provisioner.detection?.bottles.contains(where: { $0.name == name }) == true {
            return "A bottle named “\(name)” already exists."
        }
        return nil
    }

    /// Whether the bottle being set up already carries a Steam install —
    /// adoption checks and updates a client instead of downloading one, and
    /// telling someone their installed Steam is being downloaded is a lie
    /// they will watch for minutes.
    private var isAdoptingSteam: Bool {
        provisioner.detection?.steamBottles.contains { $0.name == SteamBottle.name } == true
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
        bottleChoice = bottleCandidates
            .first { $0.name == SteamBottle.name }?.name ?? bottleCandidates.first?.name
        step = .bottle
    }

    private func advanceFromBottle() {
        provisioner.chooseBottle(
            named: bottleChoice ?? newBottleName.trimmingCharacters(in: .whitespaces),
        )
        // Before the stage that reads it: provisioning starts on this press
        // and installs the catalog it names.
        if !provisioner.isDryRun {
            BottleDependencies.installsEverything = downloadEverything
        }
        beginProvisioning()
    }

    private func beginProvisioning() {
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
        step = .done
    }
}
