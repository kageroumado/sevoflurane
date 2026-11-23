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
    func `every state is on the step its name starts with`() async {
        for state in WizardState.all {
            await state.arrange()
            let step = state.id.split(separator: "-").first.map(String.init)
            let reached = await eventually { state.store.step.rawValue == step }
            #expect(reached, "\(state.id) is on \(state.store.step.rawValue)")
        }
    }

    @Test
    func `a run held in the engine download shows its stage and how far it is`() async throws {
        let provisioner = try await arranged("steam-engine-downloading").provisioner
        let reached = await eventually { provisioner.stageFraction == 0.42 }
        #expect(reached)
        #expect(provisioner.stage == Provisioner.Stage.engine)
        #expect(provisioner.isWorking)
    }

    @Test
    func `each failing machine ends its run failed`() async throws {
        for id in ["steam-rosetta-failed", "steam-engine-failed", "steam-installer-offline", "steam-failed"] {
            let store = try await arranged(id)
            let failed = await eventually { store.hasFailed }
            #expect(failed, "\(id) ended as \(store.provisioner.activity)")
        }
    }

    @Test
    func `the finished run is done and the adopted Steam reads as adopted`() async throws {
        let done = try await arranged("steam-done")
        let finished = await eventually { done.provisioner.activity == .done }
        #expect(finished)
        let adopting = try await arranged("steam-adopting")
        let held = await eventually { adopting.provisioner.stage == Provisioner.Stage.dependencies }
        #expect(held)
        #expect(adopting.adoptsSteam)
    }

    @Test
    func `a staged download stands in for Apple's page and reads no folder`() throws {
        let state = try #require(WizardState.all.first { $0.id == "graphics-browser" })
        #expect(state.store.gptk.isStaged)
        #expect(state.store.gptk.folderWatch.isWatching)
        #expect(state.height == SetupMetrics.windowSize.height)
        let signIn = try #require(WizardState.all.first { $0.id == "graphics-sign-in" })
        #expect(signIn.height == SetupMetrics.tallWindowHeight)
    }
}
