import Foundation
import Testing
@testable import Sevoflurane

/// What the app sends once it has attached, of the verbs asked for while the
/// daemon was out of reach.
struct HeldVerbTests {
    private func held(_ verb: String, at instant: ContinuousClock.Instant, expires: Bool = true) -> ClientSupervisor.HeldVerb {
        ClientSupervisor.HeldVerb(path: "/\(verb)", verb: verb, heldAt: instant, expires: expires)
    }

    @Test
    func `each verb is replayed once, at its newest ask`() {
        let now = ContinuousClock.now
        let verbs = [held("restart", at: now), held("start", at: now), held("restart", at: now)]
        #expect(ClientSupervisor.replayable(verbs, at: now).map(\.verb) == ["start", "restart"])
    }

    @Test
    func `a verb held past thirty seconds is dropped, the launch's own wish is not`() {
        let then = ContinuousClock.now
        let now = then + .seconds(45)
        let verbs = [
            held("show the library when healthy", at: then, expires: false),
            held("restart", at: then),
            held("start", at: now - .seconds(5)),
        ]
        #expect(ClientSupervisor.replayable(verbs, at: now).map(\.verb) == ["show the library when healthy", "start"])
    }
}
