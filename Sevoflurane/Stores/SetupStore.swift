import Foundation
import Observation

/// The first-run assistant's page.
enum SetupStep: String, CaseIterable {
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

/// What the first-run assistant has chosen so far and the steps that move it
/// on. Every step has a detected default; the user chooses only when the
/// choice costs money (CrossOver) or is ambiguous.
@MainActor
@Observable
final class SetupStore {
    let provisioner: Provisioner
    private(set) var step: SetupStep
    var openAtLogin = true
    var connectAgents = false
    var engineChoice: SetupEngineChoice
    /// The engine tarball this copy of the app ships with, when it does.
    private(set) var bundledEngine: URL?
    /// The bottle to adopt, or `nil` to build a fresh one.
    var bottleChoice: String?
    var newBottleName = SteamBottle.defaultName
    var downloadEverything = BottleDependencies.installsEverything
    private(set) var graphicsStore: GraphicsStore?
    /// Whether this run found Steam already in its bottle when it began.
    private(set) var adoptsSteam = false
    /// Apple's toolkit download, on the graphics step.
    let gptk = GPTkDownload()
    /// The bottle a switch could not move to because Steam would not stop:
    /// Try Again switches again rather than provisioning the old bottle.
    private(set) var unswitchedBottle: String?

    /// Where the graphics step's store comes from. A dry run without one
    /// skips that step.
    @ObservationIgnored private let makeGraphics: (() -> GraphicsStore)?
    /// Stops the running client before the wizard moves to another bottle,
    /// narrating through its argument; answers why it could not stop.
    @ObservationIgnored private let stopClient: (_ narrate: (String) -> Void) async -> String?

    /// `step` is for the gallery; a real run opens on the welcome.
    init(
        provisioner: Provisioner,
        startingAt step: SetupStep = .welcome,
        stopClient: @escaping (_ narrate: (String) -> Void) async -> String? = { _ in nil },
        makeGraphics: (() -> GraphicsStore)? = nil,
    ) {
        self.provisioner = provisioner
        self.step = step
        self.stopClient = stopClient
        self.makeGraphics = makeGraphics
        engineChoice = Engine.setupStartsOnCrossOver ? .crossover : .builtIn
        // Opening on the graphics step skips the transition that builds the store.
        graphicsStore = step == .graphics ? makeGraphics?() : nil
    }

    /// Finds the bundled engine and detects what the machine has.
    func detect() async {
        if !provisioner.isDryRun {
            bundledEngine = EngineInstaller.bundledTarball()
        }
        await provisioner.refreshDetection()
    }

    func detectAgain() {
        Task { await provisioner.refreshDetection() }
    }

    /// Uses an engine file the user chose.
    func useEngineFile(_ tarball: URL) {
        provisioner.engineTarball = tarball
    }

    func retry() {
        Task { await provisioner.retry() }
    }

    /// Switches again to a bottle that could not be reached, or retries the
    /// failed pass.
    func tryAgain() {
        if let unswitchedBottle {
            switchBottle(to: unswitchedBottle)
        } else {
            retry()
        }
    }

    // MARK: - What the steps ask

    var usesManagedEngine: Bool {
        if case .managed = Engine.active { true } else { false }
    }

    /// The Steam installations already on the machine.
    var bottleCandidates: [SetupDetection.Bottle] {
        provisioner.ownBottles.filter(\.hasSteam)
    }

    private var needsBottleChoice: Bool {
        bottleCandidates.count > 1
            || (bottleCandidates.first.map { $0.name != SteamBottle.defaultName } ?? false)
    }

    /// Why the typed name cannot be used. An existing bottle directory
    /// belongs to whatever made it, so its name is refused.
    var newBottleObjection: String? {
        let name = newBottleName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return String(localized: "Give the bottle a name.") }
        if name.contains("/") || name.contains(":") {
            return String(localized: "Use a name without / or : in it.")
        }
        if provisioner.ownBottles.contains(where: { $0.name == name }) {
            return String(localized: "A bottle named “\(name)” already exists.")
        }
        return nil
    }

    /// Whether the bottle being set up already carries a Steam install, which
    /// is checked and updated rather than downloaded.
    private var isAdoptingSteam: Bool {
        bottleCandidates.contains { $0.name == SteamBottle.name }
    }

    var hasFailed: Bool {
        if case .failed = provisioner.activity { true } else { false }
    }

    // MARK: - Moving on

    func advanceFromWelcome() {
        guard provisioner.detection?.usableCrossOver != nil else {
            step = .engine
            return
        }
        advanceFromEngine()
    }

    func advanceFromEngine() {
        // Before anything reads it: the engine stage installs Dormison only
        // when the stored choice asks for it or no CrossOver is usable.
        if !provisioner.isDryRun {
            Engine.chooseAtSetup(managed: engineChoice == .builtIn)
        }
        guard needsBottleChoice else {
            beginProvisioning()
            return
        }
        // Defaults to the stored bottle, or a new one by that name; never another bottle.
        let stored = SteamBottle.name
        if bottleCandidates.contains(where: { $0.name == stored }) {
            bottleChoice = stored
        } else {
            bottleChoice = nil
            newBottleName = stored
        }
        step = .bottle
    }

    func advanceFromBottle() {
        let name = bottleChoice ?? newBottleName.trimmingCharacters(in: .whitespaces)
        EventLog.shared.log(
            .setup, bottleChoice == nil ? "setup: creating bottle \(name)" : "setup: adopting bottle \(name)",
        )
        // Before the stage that reads it: provisioning starts on this press
        // and installs the catalog it names.
        if !provisioner.isDryRun {
            BottleDependencies.installsEverything = downloadEverything
        }
        adoptsSteam = bottleCandidates.contains { $0.name == name }
        switchBottle(to: name)
    }

    /// The step narrates the stop, which a client in another bottle needs
    /// before the choice moves.
    private func switchBottle(to name: String) {
        step = .steam
        Task {
            guard await provisioner.chooseBottle(named: name, stoppingClient: stopClient) else {
                unswitchedBottle = name
                return
            }
            unswitchedBottle = nil
            startProvisioning()
        }
    }

    private func beginProvisioning() {
        // Read before the first stage runs: a bottle that gets its Steam from
        // this run has one by the end of it, and would read as adopted.
        adoptsSteam = isAdoptingSteam
        step = .steam
        startProvisioning()
    }

    private func startProvisioning() {
        if provisioner.activity == .idle {
            Task { await provisioner.provisionAndConfigure() }
        }
    }

    /// Offers D3DMetal for the managed engine on Apple silicon; CrossOver and
    /// Intel Macs go straight to preferences.
    func advanceFromSteam() {
        guard usesManagedEngine, MacHardware.isAppleSilicon, makeGraphics != nil || !provisioner.isDryRun else {
            step = .options
            return
        }
        if graphicsStore == nil {
            graphicsStore = makeGraphics?() ?? GraphicsStore()
        }
        step = .graphics
    }

    func advanceFromGraphics() {
        step = .options
    }

    func advanceFromOptions() {
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
    func answerSharing(_ shares: Bool) {
        if !provisioner.isDryRun {
            Preferences.sharesRunStats = shares
            EventLog.shared.log(.app, shares ? "run statistics: sharing" : "run statistics: not sharing")
        }
        step = .done
    }
}
