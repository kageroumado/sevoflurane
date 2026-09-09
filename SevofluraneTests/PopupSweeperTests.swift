import Foundation
import Testing
@testable import Sevoflurane

/// What keeps the app off the bottled client's one DevTools thread: sweeps
/// that join instead of racing.
struct PopupSweeperTests {
    /// A counter the sweep hook increments, so a test can say how many
    /// sweeps actually reached the client.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func bump() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test
    func `concurrent asks share one sweep`() async {
        let sweeps = Counter()
        let sweeper = PopupSweeper(minimumInterval: .seconds(30)) {
            // Long enough that every caller below is waiting on this one.
            try? await Task.sleep(for: .milliseconds(200))
            return ["popup \(sweeps.bump())"]
        }
        let names = await withTaskGroup(of: [String].self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await sweeper.sweep() }
            }
            return await group.reduce(into: [[String]]()) { $0.append($1) }
        }
        #expect(sweeps.count == 1)
        #expect(names.allSatisfy { $0 == ["popup 1"] })
    }

    @Test
    func `a second sweep waits out the minimum interval`() async {
        let sweeps = Counter()
        let sweeper = PopupSweeper(minimumInterval: .milliseconds(300)) {
            ["popup \(sweeps.bump())"]
        }
        let clock = ContinuousClock()
        let began = clock.now
        _ = await sweeper.sweep()
        _ = await sweeper.sweep()
        #expect(sweeps.count == 2)
        #expect(began.duration(to: clock.now) >= .milliseconds(280))
    }

    @Test
    func `a second notification extends the schedule instead of racing it`() async {
        let sweeps = Counter()
        let sweeper = PopupSweeper(
            minimumInterval: .milliseconds(50), scheduleLength: .milliseconds(150),
        ) {
            ["notificationtoasts_\(sweeps.bump())_desktop"]
        }
        let reported = Counter()
        await sweeper.sweepAfterNotification { _ in _ = reported.bump() }
        await sweeper.sweepAfterNotification { _ in _ = reported.bump() }
        // Past the delay before the first sweep and the schedule's own length,
        // so nothing is still in flight.
        try? await Task.sleep(for: .seconds(1))
        #expect(sweeps.count >= 1)
        // One schedule ran, so every sweep was reported exactly once. Two
        // racing schedules would report each other's sweeps as well.
        #expect(reported.count == sweeps.count)
    }
}
