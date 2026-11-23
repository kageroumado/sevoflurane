import Foundation
import Observation

/// The engine a new Steam is set up on.
enum SetupEngineChoice {
    case builtIn
    case crossover
}

/// What Steam's windows are doing behind the assistant's last screen.
enum SetupSteamWindow: Equatable {
    /// Steam is still coming up; neither of its windows exists yet.
    case starting
    /// The background helper that starts Steam is not running.
    case helperDown
    /// Steam was started and did not come up; the reason, as the supervisor
    /// words it.
    case gaveUp(String)
    /// Steam's login window exists.
    case signIn
    /// Steam's library window exists.
    case library
}

/// The first-run assistant: the screen it is on, what has been answered, and
/// the pass it runs. Which screens there are and what each starts on is
/// ``SetupFlow``'s; what the Mac has and where answers are kept is the
/// provisioner's ``SetupEnvironment``.
@MainActor
@Observable
final class SetupStore {
    /// What the assistant asks of the app around it.
    struct Actions {
        /// Which of Steam's windows exists, read when the last screen draws.
        var steamWindow: () -> SetupSteamWindow = { .library }
        /// Stops a Steam running elsewhere before the choice moves,
        /// narrating through its argument; answers why it could not.
        var stopClient: (_ narrate: (String) -> Void) async -> String? = { _ in nil }
        /// Starts Steam behind the assistant once it is installed.
        var startClient: () -> Void = {}
        /// Closes the assistant and shows the window Steam has ready.
        var finish: () -> Void = {}
        /// Closes the assistant and leaves Steam signed out.
        var skipSignIn: () -> Void = {}
        var repairHelper: () async -> DaemonService.RepairResult = { .alreadyHealthy }
        var openLoginItems: () -> Void = {}
        var restartSteam: () -> Void = {}
    }

    let provisioner: Provisioner
    let graphics: GraphicsStore
    @ObservationIgnored private let actions: Actions

    private(set) var screen: SetupScreen
    /// The Steams already on this Mac, each with what tells it apart.
    private(set) var candidates: [SteamCandidate] = []
    /// The Steam chosen among several; `nil` starts a new one.
    var steamChoice: SteamCandidate.ID?
    var engineChoice = SetupEngineChoice.builtIn
    /// The questions the progress screen still has to ask; the first is up.
    private(set) var cards: [SetupCard] = []
    /// Whether the toolkit question has moved on to Apple's page.
    private(set) var toolkitIsOpen = false
    /// Whether the progress screen lists its stages.
    var showsDetails = false
    /// Whether the pass takes over a Steam that was already installed.
    private(set) var isAdopting = false
    /// What the last helper repair came to.
    private(set) var helperRepair: DaemonService.RepairResult?
    /// Whether Sevoflurane opens at login, as this Mac has it.
    private(set) var opensAtLogin: Bool
    private(set) var isRepairingHelper = false

    /// Whether detection and the candidates' facts are in.
    private var isPrepared = false
    /// The welcome's button was pressed before the Mac had been looked at.
    private var beginsWhenPrepared = false
    /// The Steam folder a refused stop kept the pass from moving to.
    private var unreachedBottle: String?
    private var hasDeclinedToolkit = false
    private var hasStartedClient = false
    /// Steam was installed when this assistant opened: only questions are left.
    private let isResuming: Bool
    @ObservationIgnored private var pass: Task<Void, Never>?

    private var environment: any SetupEnvironment {
        provisioner.environment
    }

    /// `resuming` opens on what an assistant quit after Steam installed left
    /// unanswered.
    init(provisioner: Provisioner, graphics: GraphicsStore, actions: Actions = Actions(), resuming: Bool = false) {
        self.provisioner = provisioner
        self.graphics = graphics
        self.actions = actions
        isResuming = resuming
        screen = resuming ? .progress : .welcome
        opensAtLogin = provisioner.openAtLogin
        provisioner.environment.assistantInProgress = true
        graphics.toolkitDownload.onInstalled = { [weak self] _ in self?.questionAnswered() }
        if resuming {
            refreshCards()
            if cards.isEmpty { screen = .done }
        }
    }

    // MARK: - What the screens read

    var facts: SetupFlow.Facts {
        SetupFlow.Facts(
            candidates: candidates,
            hasUsableCrossOver: provisioner.detection?.usableCrossOver != nil,
            chosenSteam: steamChoice,
        )
    }

    /// The question the progress screen is asking.
    var card: SetupCard? {
        cards.first
    }

    var toolkit: GPTkDownload {
        graphics.toolkitDownload
    }

    /// Whether Steam is installed: this pass finished, or an earlier one had.
    var workIsDone: Bool {
        provisioner.activity == .done || (isResuming && provisioner.failure == nil && !provisioner.isWorking)
    }

    var hasFailed: Bool {
        provisioner.failure != nil
    }

    /// Whether the screen before this one can be gone back to: a question
    /// screen, where nothing has been touched yet.
    var canGoBack: Bool {
        SetupFlow.screen(before: screen, facts) != nil
    }

    var steamWindow: SetupSteamWindow {
        actions.steamWindow()
    }

    /// Whether the window takes its tall height: Apple's page is up.
    var wantsTallWindow: Bool {
        screen == .progress && card == .toolkit && toolkitIsOpen && toolkit.route == .here && toolkit.showsApplePage
    }

    /// Registers or removes the login item, and shows what the Mac then says.
    func setOpensAtLogin(_ opens: Bool) {
        provisioner.setOpenAtLogin(opens)
        opensAtLogin = provisioner.openAtLogin
    }

    // MARK: - Looking at the Mac

    /// Detects what the Mac has and reads what each Steam on it holds, then
    /// sets each question to what it starts on.
    func prepare() async {
        await provisioner.refreshDetection()
        var found: [SteamCandidate] = []
        for bottle in provisioner.detection?.steamBottles ?? [] {
            guard let isManaged = environment.engineIsManaged(ofBottleAt: bottle.url) else { continue }
            if !isManaged, provisioner.detection?.usableCrossOver == nil { continue }
            let facts = await environment.libraryFacts(ofBottleAt: bottle.url)
            found.append(SteamCandidate(bottle: bottle, isManaged: isManaged, facts: facts))
        }
        candidates = found
        if !isPrepared {
            steamChoice = SetupFlow.preselectedSteam(among: found, storedName: environment.bottleName)
            let startsOnCrossOver = SetupFlow.startsOnCrossOver(
                hasUsableCrossOver: facts.hasUsableCrossOver,
                storedChoiceIsManaged: environment.storedEngineIsManaged,
                steamIsInCrossOver: found.contains { !$0.isManaged },
            )
            engineChoice = startsOnCrossOver ? .crossover : .builtIn
        }
        isPrepared = true
        if beginsWhenPrepared {
            beginsWhenPrepared = false
            advance()
        }
    }

    // MARK: - Moving between screens

    /// The welcome's button. On a Mac with no question to ask, the work
    /// starts here.
    func begin() {
        guard screen == .welcome else { return }
        guard isPrepared else {
            beginsWhenPrepared = true
            return
        }
        advance()
    }

    /// A question screen's Continue. The work starts after the last one.
    func answerQuestion() {
        guard screen == .whichSteam || screen == .engine else { return }
        advance()
    }

    func goBack() {
        guard let previous = SetupFlow.screen(before: screen, facts) else { return }
        screen = previous
    }

    private func advance() {
        let next = SetupFlow.screen(after: screen, facts)
        if next == .progress {
            startWork()
        } else {
            screen = next
        }
    }

    // MARK: - The work

    private func startWork() {
        let adopted = SetupFlow.adopted(facts)
        let usesManagedEngine = adopted?.isManaged ?? (!facts.hasUsableCrossOver || engineChoice == .builtIn)
        environment.storeEngineChoice(managed: usesManagedEngine)
        let bottle: String
        if let adopted {
            bottle = adopted.bottle.name
        } else {
            let sameEngine = (provisioner.detection?.bottles ?? [])
                .filter { environment.engineIsManaged(ofBottleAt: $0.url) == usesManagedEngine }
            bottle = SetupFlow.newSteamName(
                stored: environment.bottleName, base: SteamBottle.defaultName, bottles: sameEngine,
            )
        }
        isAdopting = adopted != nil
        EventLog.shared.log(.setup, adopted == nil ? "setup: a new Steam in \(bottle)" : "setup: taking over the Steam in \(bottle)")
        screen = .progress
        refreshCards()
        runPass(into: bottle)
    }

    /// Moves the choice to `bottle` and provisions it. One pass at a time.
    private func runPass(into bottle: String) {
        guard pass == nil else { return }
        pass = Task(name: "Set up Steam") { [weak self] in
            guard let self else { return }
            if await provisioner.chooseBottle(named: bottle, stoppingClient: actions.stopClient) {
                unreachedBottle = nil
                await provisioner.provisionAndConfigure()
            } else {
                unreachedBottle = bottle
            }
            pass = nil
            passEnded()
        }
    }

    /// Runs the failed pass again: the move to a Steam folder that could not
    /// be reached, or the stages from the one that failed.
    func tryAgain() {
        guard hasFailed, pass == nil else { return }
        if let unreachedBottle {
            runPass(into: unreachedBottle)
            return
        }
        pass = Task(name: "Retry setting up Steam") { [weak self] in
            guard let self else { return }
            await provisioner.retry()
            pass = nil
            passEnded()
        }
    }

    /// Tries again with an engine the person downloaded themselves.
    func tryAgain(withEngineFile file: URL) {
        provisioner.engineTarball = file
        tryAgain()
    }

    /// Whether the failed stage is the engine's download, which a file on
    /// this Mac can stand in for.
    var offersEngineFile: Bool {
        provisioner.failure?.stage == .engine && provisioner.engineInstallPending
    }

    private func passEnded() {
        guard provisioner.activity == .done else { return }
        startClientOnce()
        // The engine is known only once installed: the toolkit question
        // belongs to the built-in one.
        refreshCards()
        finishIfNothingIsLeft()
    }

    private func startClientOnce() {
        guard !hasStartedClient else { return }
        hasStartedClient = true
        actions.startClient()
    }

    // MARK: - The questions asked during the work

    private func refreshCards() {
        let offersToolkit = !hasDeclinedToolkit && environment.usesManagedEngine && environment.runsD3DMetal
            && graphics.d3dMetalVersions.isEmpty && !graphics.engineHasOwnD3DMetal
        let open = SetupFlow.cards(
            sharingIsAnswered: environment.sharesRunStats != nil, offersToolkit: offersToolkit,
        )
        if open != cards { cards = open }
        if card != .toolkit, toolkitIsOpen { toolkitIsOpen = false }
    }

    private func questionAnswered() {
        refreshCards()
        finishIfNothingIsLeft()
    }

    private func finishIfNothingIsLeft() {
        guard screen == .progress, workIsDone, cards.isEmpty else { return }
        screen = .done
    }

    func answerSharing(_ shares: Bool) {
        environment.answerSharing(shares)
        EventLog.shared.log(.app, shares ? "run statistics: sharing" : "run statistics: not sharing")
        questionAnswered()
    }

    /// Brings up Apple's page, signed in here.
    func openToolkitPage() {
        toolkit.route = .here
        toolkitIsOpen = true
    }

    /// Hands the download to the person's own browser and watches for it.
    func useBrowserForToolkit() {
        toolkit.route = .browser
        toolkitIsOpen = true
    }

    /// Leaves the toolkit for later. A download under way carries on and
    /// installs when it ends.
    func declineToolkit() {
        hasDeclinedToolkit = true
        questionAnswered()
    }

    // MARK: - The last screen

    func finish() {
        environment.assistantInProgress = false
        actions.finish()
    }

    func skipSignIn() {
        environment.assistantInProgress = false
        actions.skipSignIn()
    }

    func repairHelper() {
        guard !isRepairingHelper else { return }
        isRepairingHelper = true
        Task(name: "Repair the background helper from setup") { [weak self] in
            guard let self else { return }
            helperRepair = await actions.repairHelper()
            isRepairingHelper = false
        }
    }

    func openLoginItems() {
        actions.openLoginItems()
    }

    func restartSteam() {
        actions.restartSteam()
    }

    #if DEBUG
        /// Puts the store on a screen with its state, for the gallery: the
        /// questions a screen is asking, the toolkit's page, a helper repair.
        func stage(
            screen: SetupScreen, cards: [SetupCard] = [], toolkitIsOpen: Bool = false, showsDetails: Bool = false,
            helperRepair: DaemonService.RepairResult? = nil,
        ) {
            self.screen = screen
            self.cards = cards
            self.toolkitIsOpen = toolkitIsOpen
            self.showsDetails = showsDetails
            self.helperRepair = helperRepair
        }
    #endif
}
