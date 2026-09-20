import Foundation
import Testing
@testable import Sevoflurane

/// What the log says when a program of ours exits: a stop we asked for reads as one.
struct ExitLineTests {
    private let stop = Date(timeIntervalSinceReferenceDate: 1000)

    @Test
    func `an exit with no stop behind it reads as an exit`() {
        let line = ClientLifecycle.exitLine(of: "wine launcher", status: 15, stopRequestedAt: nil, now: stop)
        #expect(line == "wine launcher exited (status 15)")
    }

    @Test
    func `an exit inside the stop window is the stop we asked for`() {
        let line = ClientLifecycle.exitLine(
            of: "sevo-discord-bridge.exe", status: 1, stopRequestedAt: stop, now: stop.addingTimeInterval(80),
        )
        #expect(line == "sevo-discord-bridge.exe went down with the stop we asked for (status 1)")
    }

    @Test
    func `an exit long after a stop is its own`() {
        let line = ClientLifecycle.exitLine(
            of: "wine launcher", status: 1, stopRequestedAt: stop,
            now: stop.addingTimeInterval(ClientLifecycle.stopWindow + 1),
        )
        #expect(line == "wine launcher exited (status 1)")
    }
}
