import Testing
@testable import Sevoflurane

/// The guard that lets the test bundle run beside a live Steam client.
///
/// These assertions are about the process they run in: the host *is*
/// Sevoflurane, under the shipping bundle identifier, and the machine it is
/// running on may have a real client up. A failure here is not a broken unit —
/// it is the bundle having become unsafe to run.
@MainActor
struct TestHostGuardTests {
    @Test
    func `the host recognizes itself as one`() {
        #expect(TestHost.isHosting)
    }

    /// `ensureRunning` registers the helper and `repair(force:)` tears the
    /// registration down and rebuilds it; either would boot the live daemon
    /// out, and a bootout is the SIGTERM that closes the client.
    @Test
    func `the daemon registration is left alone from a test host`() async {
        #expect(await DaemonService.ensureRunning().isReachable)
        #expect(await DaemonService.repair(force: true) == .alreadyHealthy)
    }
}
