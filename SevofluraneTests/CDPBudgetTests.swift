import Foundation
import Testing
@testable import Sevoflurane

/// The bound on how much of the client's one DevTools thread the app may
/// take at once.
struct CDPBudgetTests {
    @Test
    func `the concurrency ceiling holds callers back`() async {
        let budget = CDPBudget(concurrentSessions: 2, perSecond: 1_000)
        await budget.take("first")
        await budget.take("second")
        #expect(await budget.state.inFlight == 2)

        let third = Task { await budget.take("third") }
        try? await Task.sleep(for: .milliseconds(120))
        #expect(await budget.state.inFlight == 2)

        await budget.release()
        await third.value
        #expect(await budget.state.inFlight == 2)
        await budget.release()
        await budget.release()
        #expect(await budget.state.inFlight == 0)
    }

    @Test
    func `the rate bounds how many start in a second`() async {
        let budget = CDPBudget(concurrentSessions: 100, perSecond: 4)
        for _ in 0 ..< 4 {
            await budget.take("burst")
            await budget.release()
        }
        #expect(await budget.state.tokens < 1)

        let clock = ContinuousClock()
        let began = clock.now
        await budget.take("the one over the rate")
        await budget.release()
        // A quarter of a second is one token at four a second.
        #expect(began.duration(to: clock.now) >= .milliseconds(200))
    }

    @Test
    func `a permit is released when the work throws`() async {
        struct Refused: Error {}
        let budget = CDPBudget(concurrentSessions: 1, perSecond: 1_000)
        await #expect(throws: Refused.self) {
            try await CDPBudget.spend("a call that fails", on: budget) { throw Refused() }
        }
        #expect(await budget.state.inFlight == 0)
    }
}
