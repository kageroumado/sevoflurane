import Foundation
import Testing
@testable import Sevoflurane

/// Setup's hold on the bottle it provisions, and the stop that comes before
/// the wizard moves the choice to another bottle. These read and write
/// nothing: the live suite is the one the running daemon reads, and a lease
/// written from a test would hold the real client down.
struct ProvisioningLeaseTests {
    private let prefix = "/Users/u/Library/Application Support/Sevoflurane/Bottles/Retest26"
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func lease(prefix: String? = nil, expiresIn seconds: TimeInterval = 60) -> ProvisioningLease.Lease {
        ProvisioningLease.Lease(prefix: prefix ?? self.prefix, owner: 4242, expires: now + seconds)
    }

    @Test
    func `a live lease on the bottle holds it`() {
        let held = ProvisioningLease.holding(lease(), prefix: prefix, now: now) { _ in true }
        #expect(held == lease())
        #expect(held?.name == "Retest26")
    }

    /// Every other bottle starts as it would have: the lease is on one prefix.
    @Test
    func `a lease on another bottle holds nothing`() {
        let other = lease(prefix: "/Users/u/Library/Application Support/Sevoflurane/Bottles/Steam")
        #expect(ProvisioningLease.holding(other, prefix: prefix, now: now) { _ in true } == nil)
    }

    /// A pass that hung stops renewing, and the lease lapses with its term.
    @Test
    func `an expired lease holds nothing`() {
        #expect(ProvisioningLease.holding(lease(expiresIn: -1), prefix: prefix, now: now) { _ in true } == nil)
        #expect(ProvisioningLease.holding(lease(expiresIn: 0), prefix: prefix, now: now) { _ in true } == nil)
    }

    /// An app that crashed mid-setup releases nothing, and its lease goes with
    /// its process rather than holding the client down for the rest of a term.
    @Test
    func `a lease whose owner is gone holds nothing`() {
        #expect(ProvisioningLease.holding(lease(), prefix: prefix, now: now) { _ in false } == nil)
    }

    @Test
    func `no lease holds nothing`() {
        #expect(ProvisioningLease.holding(nil, prefix: prefix, now: now) { _ in true } == nil)
    }

    @Test
    func `a lease survives the preference suite`() {
        #expect(ProvisioningLease.lease(from: ProvisioningLease.stored(lease())) == lease())
        #expect(ProvisioningLease.lease(from: ["prefix": prefix]) == nil)
        #expect(ProvisioningLease.lease(from: nil) == nil)
    }

    /// The daemon and the pass spell the prefix from different code; the key
    /// is the standardized path, so both land on one string.
    @Test
    func `the key is the standardized prefix`() {
        let spelled = URL(fileURLWithPath: "/Users/u/Bottles/Steam/../Retest26/")
        #expect(ProvisioningLease.key(for: spelled) == "/Users/u/Bottles/Retest26")
    }

    /// A term fits several renewals, so one late renewal never drops the hold.
    @Test
    func `a term outlasts two renewals`() {
        #expect(ProvisioningLease.term > 2 * Double(ProvisioningLease.renewal.components.seconds))
    }
}

struct SetupBottleSwitchTests {
    private let steam = "/B/Steam"
    private let retest = "/B/Retest26"

    @Test
    func `adopting the bottle the client runs in stops nothing`() {
        #expect(!Provisioner.choosingStopsClient(chosen: steam, configured: steam, booted: steam))
        #expect(!Provisioner.choosingStopsClient(chosen: steam, configured: steam, booted: nil))
    }

    /// Written under a running client, the new name puts that client out of
    /// every stop's reach, and it goes on answering as the new bottle's.
    @Test
    func `choosing another bottle stops the client first`() {
        #expect(Provisioner.choosingStopsClient(chosen: retest, configured: steam, booted: steam))
        #expect(Provisioner.choosingStopsClient(chosen: retest, configured: steam, booted: nil))
    }

    /// The preference already moved (a `defaults write`), and the client
    /// still runs where it booted.
    @Test
    func `a client booted elsewhere is stopped even when the preference already moved`() {
        #expect(Provisioner.choosingStopsClient(chosen: retest, configured: retest, booted: steam))
    }

    @Test
    func `a stopped client or no daemon lets the choice move`() {
        #expect(ClientSupervisor.switchStopStep(after: .stopped, waited: .zero, budget: .seconds(60)) == .proceed)
        #expect(ClientSupervisor.switchStopStep(after: .unreachable, waited: .zero, budget: .seconds(60)) == .proceed)
    }

    /// A restart under way refuses the stop; the switch waits it out and
    /// asks again, and a restart that outlasts the budget keeps the old
    /// choice rather than writing the new name under a running client.
    @Test
    func `a restart under way is waited out within the budget`() {
        #expect(ClientSupervisor.switchStopStep(after: .busy, waited: .seconds(5), budget: .seconds(60)) == .waitForRestart)
        #expect(ClientSupervisor.switchStopStep(after: .busy, waited: .seconds(60), budget: .seconds(60)) == .refuse)
    }

    @Test
    func `a stop that failed keeps the old choice`() {
        #expect(ClientSupervisor.switchStopStep(after: .failed, waited: .zero, budget: .seconds(60)) == .refuse)
    }
}
