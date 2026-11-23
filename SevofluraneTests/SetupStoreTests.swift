import Foundation
import Testing
@testable import Sevoflurane

/// The first-run assistant's store on simulated machines: which screens a
/// Mac gets, what the work is told to set up, and what is left to ask.
@MainActor
struct SetupStoreTests {
    private struct Rig {
        let store: SetupStore
        let environment: DryRunSetupEnvironment
        let provisioner: Provisioner
        let events: Events
    }

    /// What the store asked of the app around it.
    private final class Events {
        var clientStarts = 0
        var finishes = 0
    }

    private func makeRig(
        _ scenario: SetupScenario, detection: SetupDetection? = nil, sharing: Bool? = false, toolkitInstalled: Bool = true,
        resuming: Bool = false, configure: (DryRunSetupEnvironment) -> Void = { _ in },
    ) -> Rig {
        let environment = DryRunSetupEnvironment(scenario: scenario, stepDelay: .zero, detection: detection)
        environment.crossOverAppearsOnRecheck = false
        environment.sharesRunStats = sharing
        configure(environment)
        let provisioner = Provisioner(environment: environment)
        provisioner.installsEveryDependency = false
        let graphics = GraphicsStore(environment: DemoGraphicsEnvironment(
            scenario: toolkitInstalled ? .builtInWithToolkit : .builtInNoToolkit, stepDelay: .zero,
        ))
        let events = Events()
        var actions = SetupStore.Actions()
        actions.startClient = { events.clientStarts += 1 }
        actions.finish = { events.finishes += 1 }
        let store = SetupStore(provisioner: provisioner, graphics: graphics, actions: actions, resuming: resuming)
        return Rig(store: store, environment: environment, provisioner: provisioner, events: events)
    }

    private static let plainMac = SetupDetection(rosetta: true, crossover: nil, bottles: [], managedEngineVersions: [])

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: - The screens a Mac gets

    @Test
    func `a Mac with nothing on it starts the work on the first button and ends on the last screen`() async {
        let rig = makeRig(.freshMachine, detection: Self.plainMac)
        await rig.store.prepare()
        #expect(rig.store.screen == .welcome)
        rig.store.begin()
        #expect(rig.store.screen == .progress)
        #expect(!rig.store.canGoBack)
        let finished = await eventually { rig.store.screen == .done }
        #expect(finished)
        #expect(rig.environment.storedEngineIsManaged == true)
        #expect(rig.environment.bottleName == "Steam")
        #expect(rig.environment.state.managedEngineVersions == ["dry-run-engine"])
        #expect(rig.events.clientStarts == 1)
    }

    @Test
    func `the button pressed before the Mac was looked at begins once it has been`() async {
        let rig = makeRig(.freshMachine, detection: Self.plainMac)
        rig.store.begin()
        #expect(rig.store.screen == .welcome)
        await rig.store.prepare()
        #expect(rig.store.screen == .progress)
    }

    @Test
    func `several Steams are asked about, the one played last is chosen, and Back returns to the welcome`() async {
        let rig = makeRig(.multipleBottles) {
            $0.factsByBottle = [
                "Steam": SteamLibraryFacts(games: 2, lastPlayed: Date(timeIntervalSince1970: 1000), bytes: 10),
                "Games": SteamLibraryFacts(games: 9, lastPlayed: Date(timeIntervalSince1970: 9000), bytes: 90),
            ]
        }
        await rig.store.prepare()
        rig.store.begin()
        #expect(rig.store.screen == .whichSteam)
        // Another engine's Steam and a bottle without Steam are no candidates.
        #expect(rig.store.candidates.map(\.bottle.name) == ["Steam", "Steam Beta", "Games"])
        #expect(rig.store.candidates.first { $0.id == rig.store.steamChoice }?.bottle.name == "Games")
        #expect(rig.store.canGoBack)
        rig.store.goBack()
        #expect(rig.store.screen == .welcome)
        rig.store.begin()
        rig.store.answerQuestion()
        #expect(rig.store.screen == .progress)
        #expect(rig.store.isAdopting)
        let finished = await eventually { rig.store.screen == .done }
        #expect(finished)
        #expect(rig.environment.bottleName == "Games")
        // An existing Steam lives with one engine already: no engine question.
        #expect(rig.environment.storedEngineIsManaged == false)
    }

    @Test
    func `a new Steam beside existing ones is asked its engine and gets a free name`() async {
        let rig = makeRig(.multipleBottles)
        await rig.store.prepare()
        rig.store.begin()
        rig.store.steamChoice = nil
        rig.store.answerQuestion()
        #expect(rig.store.screen == .engine)
        rig.store.goBack()
        #expect(rig.store.screen == .whichSteam)
        rig.store.answerQuestion()
        rig.store.engineChoice = .crossover
        rig.store.answerQuestion()
        #expect(rig.store.screen == .progress)
        #expect(!rig.store.isAdopting)
        let finished = await eventually { rig.store.screen == .done }
        #expect(finished)
        #expect(rig.environment.bottleName == "Steam 2")
        #expect(rig.environment.storedEngineIsManaged == false)
    }

    @Test
    func `a Mac with CrossOver and no Steam is asked its engine, starting on the built-in one`() async {
        let rig = makeRig(.licensedNoBottle)
        await rig.store.prepare()
        rig.store.begin()
        #expect(rig.store.screen == .engine)
        #expect(rig.store.engineChoice == .builtIn)
        rig.store.answerQuestion()
        let finished = await eventually { rig.store.screen == .done }
        #expect(finished)
        #expect(rig.environment.storedEngineIsManaged == true)
        #expect(rig.environment.state.managedEngineVersions == ["dry-run-engine"])
    }

    @Test
    func `an intent for another screen does nothing`() async {
        let rig = makeRig(.multipleBottles)
        await rig.store.prepare()
        rig.store.answerQuestion()
        rig.store.goBack()
        rig.store.tryAgain()
        #expect(rig.store.screen == .welcome)
        #expect(rig.provisioner.activity == .idle)
    }

    // MARK: - Failure and retry

    @Test
    func `a failed pass stays on the work with its failure, and Try Again finishes it`() async {
        let rig = makeRig(.freshMachine, detection: Self.plainMac) { $0.installerFailures = 1 }
        await rig.store.prepare()
        rig.store.begin()
        let failed = await eventually { rig.store.hasFailed }
        #expect(failed)
        #expect(rig.store.screen == .progress)
        #expect(rig.provisioner.failure?.stage == .installer)
        #expect(!rig.store.offersEngineFile)
        #expect(rig.events.clientStarts == 0)
        rig.store.tryAgain()
        let finished = await eventually { rig.store.screen == .done }
        #expect(finished)
        #expect(rig.events.clientStarts == 1)
    }

    @Test
    func `a failed engine download offers a file, which the retry installs`() async {
        let rig = makeRig(.freshMachine, detection: Self.plainMac) { $0.engineFailure = "The Internet connection appears to be offline." }
        await rig.store.prepare()
        rig.store.begin()
        let failed = await eventually { rig.store.hasFailed }
        #expect(failed)
        #expect(rig.store.offersEngineFile)
        rig.environment.engineFailure = nil
        rig.store.tryAgain(withEngineFile: URL(fileURLWithPath: "/Users/you/Downloads/dormison-r14.tar.xz"))
        let finished = await eventually { rig.store.screen == .done }
        #expect(finished)
        #expect(rig.environment.state.managedEngineVersions == ["dormison-r14"])
    }

    // MARK: - The questions asked during the work

    @Test
    func `the work asks sharing, then the toolkit, and moves on when both are answered`() async {
        let rig = makeRig(.freshMachine, detection: Self.plainMac, sharing: nil, toolkitInstalled: false)
        await rig.store.prepare()
        rig.store.begin()
        #expect(rig.store.cards == [.sharing, .toolkit])
        let installed = await eventually { rig.store.workIsDone }
        #expect(installed)
        // Steam is in, and the screen waits on its questions.
        #expect(rig.store.screen == .progress)
        rig.store.answerSharing(true)
        #expect(rig.environment.sharesRunStats == true)
        #expect(rig.store.card == .toolkit)
        rig.store.openToolkitPage()
        #expect(rig.store.toolkitIsOpen)
        rig.store.declineToolkit()
        #expect(!rig.store.toolkitIsOpen)
        #expect(rig.store.screen == .done)
    }

    @Test
    func `the toolkit is offered only to the built-in engine without one`() async {
        let withToolkit = makeRig(.freshMachine, detection: Self.plainMac, toolkitInstalled: true)
        await withToolkit.store.prepare()
        withToolkit.store.begin()
        #expect(withToolkit.store.cards.isEmpty)

        let onCrossOver = makeRig(.licensedNoBottle, toolkitInstalled: false)
        await onCrossOver.store.prepare()
        onCrossOver.store.begin()
        onCrossOver.store.engineChoice = .crossover
        onCrossOver.store.answerQuestion()
        #expect(onCrossOver.store.cards.isEmpty)
    }

    // MARK: - Whether an assistant is in progress

    @Test
    func `an assistant is on record from its start to its finish`() async {
        let rig = makeRig(.freshMachine, detection: Self.plainMac)
        #expect(rig.environment.assistantInProgress)
        await rig.store.prepare()
        rig.store.begin()
        let finished = await eventually { rig.store.screen == .done }
        #expect(finished)
        #expect(rig.environment.assistantInProgress)
        rig.store.finish()
        #expect(!rig.environment.assistantInProgress)
        #expect(rig.events.finishes == 1)
    }

    @Test
    func `an assistant resumed after Steam installed opens on what is left to ask`() {
        let asking = makeRig(.provisioned, sharing: nil, resuming: true)
        #expect(asking.store.screen == .progress)
        #expect(asking.store.workIsDone)
        #expect(asking.store.cards == [.sharing])
        asking.store.answerSharing(false)
        #expect(asking.store.screen == .done)

        let answered = makeRig(.provisioned, sharing: true, resuming: true)
        #expect(answered.store.screen == .done)
    }
}
