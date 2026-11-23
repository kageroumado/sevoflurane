import Foundation
import Testing
@testable import Sevoflurane

/// The gallery's states of the first-run assistant (``WizardState``): each
/// store is where its name says, so a screenshot named for a state shows it.
@MainActor
struct WizardStateTests {
    /// Walks the state named `id` and answers its store.
    private func arranged(_ id: String) async throws -> SetupStore {
        let state = try #require(WizardState.all.first { $0.id == id })
        await state.arrange()
        return state.store
    }

    /// Waits for `condition`, which a run reaches some main-actor turns after
    /// the button that starts it is pressed.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test
    func `every state is on the screen its name says`() async {
        let screens: [(prefix: String, screen: SetupScreen)] = [
            ("1-welcome", .welcome), ("2-which-steam", .whichSteam), ("3-engine", .engine),
            ("3-close-steam", .closeSteam), ("4-progress", .progress), ("5-done", .done),
        ]
        for state in WizardState.all {
            await state.arrange()
            let expected = screens.first { state.id.hasPrefix($0.prefix) }?.screen
            let reached = await eventually { state.store.screen == expected }
            #expect(reached, "\(state.id) is on \(state.store.screen.rawValue)")
        }
    }

    @Test
    func `a run held in the engine download shows its stage and how far it is`() async throws {
        let provisioner = try await arranged("4-progress-early").provisioner
        let reached = await eventually { provisioner.stageFraction == 0.42 }
        #expect(reached)
        #expect(provisioner.stage == .engine)
        #expect(provisioner.isWorking)
        #expect(provisioner.passFraction > 0)
    }

    @Test
    func `each failing machine ends its run failed, with a sentence`() async throws {
        for id in ["4-progress-failed-download", "4-progress-failed-steam-download", "4-progress-failed-installer"] {
            let store = try await arranged(id)
            let failed = await eventually { store.hasFailed }
            #expect(failed, "\(id) ended as \(store.provisioner.activity)")
        }
        let offline = try await arranged("4-progress-failed-steam-download").provisioner.failure
        #expect(offline?.cause == "The Internet connection appears to be offline.")
        #expect(offline?.advice == SetupFailureText.networkAdvice)
        let once = try await arranged("4-progress-failed-installer")
        #expect(!once.offersDiagnostics)
        let twice = try await arranged("4-progress-failed-twice")
        let offered = await eventually { twice.offersDiagnostics }
        #expect(offered)
    }

    @Test
    func `closing a running Steam is a stage of the run, working or failed`() async throws {
        let closing = try await arranged("4-progress-closing-steam").provisioner
        let working = await eventually { closing.stage == .steamStop && closing.isWorking }
        #expect(working)
        let refused = try await arranged("4-progress-closing-steam-failed").provisioner
        let failed = await eventually { refused.failure?.stage == .steamStop }
        #expect(failed)
    }

    @Test
    func `the questions are up on the states named for them`() async throws {
        let sharing = try await arranged("4-progress-sharing")
        #expect(sharing.card == .sharing)
        let waiting = try await arranged("4-progress-done-sharing")
        let installed = await eventually { waiting.workIsDone }
        #expect(installed)
        #expect(waiting.card == .sharing)
        let offer = try await arranged("4-progress-toolkit")
        #expect(offer.card == .toolkit)
        #expect(!offer.toolkitIsOpen)
        #expect(!offer.showsApplePage)
        let signIn = try await arranged("4-progress-toolkit-sign-in")
        #expect(signIn.showsApplePage)
        let browser = try await arranged("4-progress-toolkit-browser")
        #expect(browser.toolkitIsOpen)
        #expect(!browser.showsApplePage)
        // Downloads under way fold the offer away and bring the next question up.
        let running = try await arranged("4-progress-toolkit-running")
        #expect(running.card == .sharing)
        #expect(running.toolkit.downloadFraction != nil)
        let failed = try await arranged("4-progress-toolkit-failed")
        #expect(failed.card == .toolkit)
        #expect(failed.toolkit.failedItems.count == 1)
    }

    @Test
    func `a short display caps the window and gives Apple's page what is left`() throws {
        let small = try #require(WizardState.all.first { $0.id == "4-progress-toolkit-sign-in-13-inch" })
        small.layout.pageHeight = 2000
        #expect(small.layout.windowHeight == small.layout.heightLimit)
        #expect(small.layout.applePageHeight < SetupMetrics.applePageHeight.upperBound)
        #expect(small.layout.applePageHeight >= SetupMetrics.applePageHeight.lowerBound)
        let roomy = SetupLayout()
        roomy.pageHeight = 300
        #expect(roomy.windowHeight == SetupMetrics.windowSize.height)
        roomy.pageHeight = 700
        #expect(roomy.windowHeight == 700 + SetupMetrics.barHeight)
    }

    @Test
    func `the Steam taken over reads as taken over`() async throws {
        let adopting = try await arranged("4-progress-adopting")
        let held = await eventually { adopting.provisioner.stage == .dependencies }
        #expect(held)
        #expect(adopting.isAdopting)
    }
}
