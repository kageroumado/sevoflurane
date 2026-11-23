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
        let screens: [String: SetupScreen] = [
            "1-welcome": .welcome, "2-which-steam": .whichSteam, "3-engine": .engine, "4-progress": .progress,
            "5-done": .done,
        ]
        for state in WizardState.all {
            await state.arrange()
            let expected = screens.first { state.id.hasPrefix($0.key) }?.value
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
        #expect(!offer.wantsTallWindow)
        let signIn = try await arranged("4-progress-toolkit-sign-in")
        #expect(signIn.toolkitIsOpen)
        #expect(signIn.wantsTallWindow)
        let browser = try await arranged("4-progress-toolkit-browser")
        #expect(browser.toolkit.folderWatch.isWatching)
        #expect(!browser.wantsTallWindow)
    }

    @Test
    func `the Steam taken over reads as taken over`() async throws {
        let adopting = try await arranged("4-progress-adopting")
        let held = await eventually { adopting.provisioner.stage == .dependencies }
        #expect(held)
        #expect(adopting.isAdopting)
    }
}
