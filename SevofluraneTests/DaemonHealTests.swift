import Foundation
import Testing
@testable import Sevoflurane

/// The launch self-heal decision, as a function of what the app observed about
/// its background helper. Kept apart from `SMAppService`, so these exercise the
/// decision without touching Background Task Management.
struct DaemonHealTests {
    private func decide(
        registered: Bool = true,
        answering: Bool,
        attempted: Bool = false,
        daemonVersion: String? = nil,
        appVersion: String = "1.6",
    ) -> DaemonHeal.Action {
        DaemonHeal.decide(DaemonHeal.Inputs(
            isRegistered: registered,
            isAnswering: answering,
            healAlreadyAttempted: attempted,
            daemonVersion: daemonVersion,
            appVersion: appVersion,
        ))
    }

    @Test
    func `a registered but silent helper is rebuilt, once`() {
        #expect(decide(registered: true, answering: false, attempted: false) == .rebuild)
    }

    @Test
    func `an answering helper of the app's own version heals nothing`() {
        #expect(decide(answering: true, daemonVersion: "1.6", appVersion: "1.6") == .none)
        // A patch component the app does not carry still matches.
        #expect(decide(answering: true, daemonVersion: "1.6.0", appVersion: "1.6") == .none)
    }

    @Test
    func `a second silent attach surfaces the failure rather than looping`() {
        #expect(decide(registered: true, answering: false, attempted: true) == .surfaceFailure)
    }

    @Test
    func `a helper older than the app is restarted`() {
        #expect(decide(answering: true, daemonVersion: "1.5", appVersion: "1.6") == .restartStale)
        #expect(decide(answering: true, daemonVersion: "1.6", appVersion: "1.6.1") == .restartStale)
    }

    @Test
    func `a helper of the same version and another build is restarted`() {
        func decide(running: String?, bundled: String?) -> DaemonHeal.Action {
            DaemonHeal.decide(DaemonHeal.Inputs(
                isRegistered: true, isAnswering: true, healAlreadyAttempted: false,
                daemonVersion: "1.11", appVersion: "1.11",
                daemonBuild: running, bundledDaemonBuild: bundled,
            ))
        }
        #expect(decide(running: "A", bundled: "A") == .none)
        #expect(decide(running: "A", bundled: "B") == .restartStale)
        // launchd keeps a daemon across an update; one from before builds
        // were reported says nothing, and is another build for that.
        #expect(decide(running: nil, bundled: "B") == .restartStale)
        // An app that cannot read its own daemon decides by version alone.
        #expect(decide(running: "A", bundled: nil) == .none)
    }

    @Test
    func `this process and its file on disk are one build`() throws {
        let inMemory = try #require(MachOIdentity.ofThisProcess)
        let executable = try #require(Bundle.main.executableURL)
        #expect(MachOIdentity.ofFile(executable) == inMemory)
        #expect(MachOIdentity.ofFile(URL(fileURLWithPath: "/etc/hosts")) == nil)
    }

    @Test
    func `a helper newer than the app is left alone`() {
        // A daemon ahead of the app is not this launch's problem to fix; only
        // an older one gets restarted.
        #expect(decide(answering: true, daemonVersion: "1.7", appVersion: "1.6") == .none)
    }

    @Test
    func `an unregistered silent helper is the caller's first-run register, not a rebuild`() {
        // Nothing to tear down, so the decision defers to the ordinary
        // registration path rather than rebuilding a record that is absent.
        #expect(decide(registered: false, answering: false) == .none)
    }

    @Test
    func `an answering helper with no reported version is taken as current`() {
        #expect(decide(answering: true, daemonVersion: nil, appVersion: "1.6") == .none)
    }

    @Test
    func `repair leaves an answering daemon alone`() {
        // The escape hatch run on a healthy system must not rebuild — that
        // would detach the running app.
        #expect(DaemonHeal.repairAction(isAnswering: true, force: false) == .alreadyHealthy)
    }

    @Test
    func `repair rebuilds a silent daemon`() {
        #expect(DaemonHeal.repairAction(isAnswering: false, force: false) == .rebuild)
    }

    @Test
    func `force rebuilds even a daemon that is answering`() {
        #expect(DaemonHeal.repairAction(isAnswering: true, force: true) == .rebuild)
        #expect(DaemonHeal.repairAction(isAnswering: false, force: true) == .rebuild)
    }

    @Test
    func `version ordering compares component by component`() {
        #expect(DaemonHeal.isOlder("1.5", than: "1.6"))
        #expect(DaemonHeal.isOlder("1.6", than: "1.6.1"))
        #expect(!DaemonHeal.isOlder("1.6", than: "1.6.0"))
        #expect(!DaemonHeal.isOlder("1.6.0", than: "1.6"))
        #expect(!DaemonHeal.isOlder("1.10", than: "1.9"))
        #expect(DaemonHeal.isOlder("1.9", than: "1.10"))
        // A non-numeric or empty version counts as zero, so it never reads as
        // newer than a numbered release.
        #expect(DaemonHeal.isOlder("dev", than: "1.6"))
        #expect(DaemonHeal.isOlder("0", than: "1.6"))
    }
}
