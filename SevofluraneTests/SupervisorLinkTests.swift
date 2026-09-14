import Foundation
import Testing
@testable import Sevoflurane

/// The verdict crosses a process boundary as two strings, so the trip has to
/// be lossless: the app draws what the daemon derived, and `sevo` prints the
/// same words it always has.
struct SupervisorLinkTests {
    private static let everyHealth: [SupervisorHealth] = [
        .starting,
        .healthy,
        .waitingForSignIn,
        .degraded("Steam surfaced a dialog — see the log"),
        .restarting("launching the client"),
        .launching("waiting for the client (12s)"),
        .gaveUp("client keeps dying — likely crash-looping; see the log"),
        .paused,
    ]

    @Test
    func `a health survives the round trip through the link`() {
        for health in Self.everyHealth {
            let snapshot = SupervisorSnapshot(health, isBusyRestarting: false, version: "1.4")
            #expect(
                snapshot.supervisorHealth == health,
                "\(health) came back as \(snapshot.supervisorHealth)",
            )
        }
    }

    @Test
    func `the wire names are the ones sevo matches on`() {
        #expect(Self.everyHealth.map(\.wireName) == [
            "starting", "healthy", "waitingForSignIn", "degraded",
            "restarting", "launching", "gaveUp", "paused",
        ])
    }

    @Test
    func `a snapshot encodes and decodes whole`() throws {
        let snapshot = SupervisorSnapshot(
            .restarting("stopping the client"), isBusyRestarting: true, version: "1.4",
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(SupervisorSnapshot.self, from: data) == snapshot)
    }

    @Test
    func `page facts encode and decode whole`() throws {
        let facts = PageFacts(
            appPID: 4321, isAwaitingSignIn: true, isClientConnected: true, appVersion: "1.4",
        )
        let data = try JSONEncoder().encode(facts)
        #expect(try JSONDecoder().decode(PageFacts.self, from: data) == facts)
    }

    @Test
    func `every page command names itself on the wire`() {
        for command in [
            PageCommand.connectToClient, .reload, .rebuild, .dismissWindows,
            .dismissWindowsForQuit, .clientStopBegan, .clientStopEnded, .showLibrary,
        ] {
            #expect(PageCommand(rawValue: command.rawValue) == command)
        }
    }

    @Test
    func `an unknown health reads as starting rather than crashing the menu bar`() {
        #expect(SupervisorHealth(wireName: "somethingNewer", detail: "") == .starting)
    }
}

/// How `sevo status` reads the app process from two signals: the daemon's
/// attachment claim and the app's own link port. The bug this guards: a live
/// app the daemon lost after a rebuild must never read as "not running".
struct AppRunStateTests {
    @Test
    func `an app the daemon vouches for is attached`() {
        #expect(AppRunState.classify(daemonReportsAttached: true, appLinkAlive: false) == .attached)
        // Its own port need not be re-probed once the daemon confirms it.
        #expect(AppRunState.classify(daemonReportsAttached: true, appLinkAlive: true) == .attached)
    }

    @Test
    func `an app alive on its link port but not attached is detached, not gone`() {
        #expect(AppRunState.classify(daemonReportsAttached: false, appLinkAlive: true) == .detached)
    }

    @Test
    func `an app answering nowhere is not running`() {
        #expect(AppRunState.classify(daemonReportsAttached: false, appLinkAlive: false) == .notRunning)
    }

    @Test
    func `detached and attached are both running; only silence is not`() {
        #expect(AppRunState.attached.isRunning)
        #expect(AppRunState.detached.isRunning)
        #expect(!AppRunState.notRunning.isRunning)
    }

    @Test
    func `the state prints the words sevo status shows`() {
        #expect(AppRunState.attached.rawValue == "running")
        #expect(AppRunState.detached.rawValue == "running, reattaching")
        #expect(AppRunState.notRunning.rawValue == "not running")
    }
}
