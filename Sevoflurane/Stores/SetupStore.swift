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
    /// Steam was started and did not come up.
    case gaveUp
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
        /// Whether a Steam of this app is running now.
        var steamIsRunning: () async -> Bool = { false }
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
    private(set) var isRepairingHelper = false
    /// Whether Sevoflurane opens at login once the assistant is finished.
    var opensAtLogin: Bool

    /// Whether detection and the candidates' facts are in.
    private var isPrepared = false
    /// The welcome's button was pressed before the Mac had been looked at.
    private var beginsWhenPrepared = false
    /// Whether a Steam of this app was running when the Mac was looked at.
    private var steamIsRunning = false
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
        let environment = provisioner.environment
        // A stored engine choice with no assistant on record is an
        // installation an earlier version set up.
        let hasBeenSetUp = environment.assistantHasFinished
            || (environment.storedEngineIsManaged != nil && !environment.assistantInProgress)
        opensAtLogin = SetupFlow.opensAtLoginByDefault(
            isRegistered: provisioner.openAtLogin, hasBeenSetUp: hasBeenSetUp,
        )
        environment.assistantInProgress = true
        graphics.toolkitDownload.onChange = { [weak self] in self?.questionAnswered() }
        if resuming {
            refreshCards()
            if cards.isEmpty { screen = .done }
        }
    }

    // MARK: - What the screens read

    var facts: SetupFlow.Facts {
        var facts = SetupFlow.Facts(
            candidates: candidates,
            hasUsableCrossOver: provisioner.detection?.usableCrossOver != nil,
            chosenSteam: steamChoice,
        )
        facts.closesRunningSteam = steamIsRunning && provisioner.closesSteam(toChoose: target(facts).bottle)
        return facts
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

    var steamWindow: SetupSteamWindow {
        actions.steamWindow()
    }

    /// Whether Apple's page is up in this window.
    var showsApplePage: Bool {
        screen == .progress && card == .toolkit && toolkitIsOpen && toolkit.route == .here && toolkit.showsApplePage
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
        steamIsRunning = await actions.steamIsRunning()
        if !isPrepared {
            steamChoice = SetupFlow.preselectedSteam(among: found, storedName: environment.bottleName)
            let startsOnCrossOver = SetupFlow.startsOnCrossOver(
                hasUsableCrossOver: provisioner.detection?.usableCrossOver != nil,
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
        guard screen == .whichSteam || screen == .engine || screen == .closeSteam else { return }
        advance()
    }

    /// Back, or the decline of a question asked before the work: the screen
    /// before this one, where nothing has been touched yet.
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

    /// The Steam folder the work sets up and the engine it lives with, as
    /// the answers so far have it.
    private func target(_ facts: SetupFlow.Facts) -> (bottle: String, isManaged: Bool, isAdopted: Bool) {
        if let adopted = SetupFlow.adopted(facts) {
            return (adopted.bottle.name, adopted.isManaged, true)
        }
        let isManaged = !facts.hasUsableCrossOver || engineChoice == .builtIn
        let sameEngine = (provisioner.detection?.bottles ?? [])
            .filter { environment.engineIsManaged(ofBottleAt: $0.url) == isManaged }
        let bottle = SetupFlow.newSteamName(
            stored: environment.bottleName, base: SteamBottle.defaultName, bottles: sameEngine,
        )
        return (bottle, isManaged, false)
    }

    private func startWork() {
        var answers = SetupFlow.Facts(
            candidates: candidates,
            hasUsableCrossOver: provisioner.detection?.usableCrossOver != nil,
            chosenSteam: steamChoice,
        )
        answers.closesRunningSteam = false
        // The engine first: which folders belong to it follows from it.
        let engineIsManaged = SetupFlow.adopted(answers)?.isManaged
            ?? (!answers.hasUsableCrossOver || engineChoice == .builtIn)
        environment.storeEngineChoice(managed: engineIsManaged)
        let target = target(answers)
        isAdopting = target.isAdopted
        EventLog.shared.log(
            .setup, target.isAdopted ? "setup: taking over the Steam in \(target.bottle)" : "setup: a new Steam in \(target.bottle)",
        )
        screen = .progress
        refreshCards()
        runPass(into: target.bottle)
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
        refreshCards()
        finishIfNothingIsLeft()
    }

    private func startClientOnce() {
        guard !hasStartedClient else { return }
        hasStartedClient = true
        actions.startClient()
    }

    // MARK: - The questions asked during the work

    /// Whether the toolkit is this assistant's to offer: the built-in
    /// engine on a Mac that runs it, with none installed and none on its way,
    /// or with a download that failed and can be tried again.
    private var offersToolkit: Bool {
        guard !hasDeclinedToolkit, environment.usesManagedEngine, environment.runsD3DMetal,
              !graphics.engineHasOwnD3DMetal else { return false }
        if !toolkit.failedItems.isEmpty { return true }
        return graphics.d3dMetalVersions.isEmpty && toolkit.items.isEmpty
    }

    private func refreshCards() {
        let open = SetupFlow.cards(
            sharingIsAnswered: environment.sharesRunStats != nil, offersToolkit: offersToolkit,
        )
        if open != cards { cards = open }
        if card != .toolkit || !toolkit.items.isEmpty, toolkitIsOpen { toolkitIsOpen = false }
    }

    /// A question was answered, or the toolkit's download moved: the next
    /// question comes up, or the last screen.
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

    /// Starts the toolkit downloads that failed again.
    func retryToolkit() {
        toolkit.retryFailed()
    }

    /// Leaves the toolkit for later. A download under way carries on and
    /// installs when it ends.
    func declineToolkit() {
        hasDeclinedToolkit = true
        questionAnswered()
    }

    // MARK: - The last screen

    func finish() {
        closeAssistant()
        actions.finish()
    }

    func skipSignIn() {
        closeAssistant()
        actions.skipSignIn()
    }

    /// Puts the login item where the checkbox has it and takes the assistant
    /// off the record.
    private func closeAssistant() {
        if opensAtLogin != provisioner.openAtLogin {
            provisioner.setOpenAtLogin(opensAtLogin)
        }
        environment.assistantInProgress = false
        environment.assistantHasFinished = true
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
