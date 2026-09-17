import Testing
@testable import Sevoflurane

/// The boot phase the daemon reports, as the text the popover shows.
struct SupervisorBootPhaseTests {
    @Test
    func `idle has no progress to name`() {
        #expect(SupervisorBootPhase.idle.progressText(elapsedSeconds: 12) == nil)
    }

    @Test
    func `each phase names itself and the seconds so far`() {
        #expect(SupervisorBootPhase.awaitingClient.progressText(elapsedSeconds: 7)
            == "Starting Windows and Steam… (7s)")
        #expect(SupervisorBootPhase.awaitingServices.progressText(elapsedSeconds: 31)
            == "Waiting for Steam’s services… (31s)")
        #expect(SupervisorBootPhase.pageBooting.progressText(elapsedSeconds: 40)
            == "Opening your library… (40s)")
    }

    @Test
    func `a clock that went backwards reads as zero`() {
        #expect(SupervisorBootPhase.awaitingClient.progressText(elapsedSeconds: -3)
            == "Starting Windows and Steam… (0s)")
    }
}
