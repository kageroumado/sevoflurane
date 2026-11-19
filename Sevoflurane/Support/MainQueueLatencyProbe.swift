import Dispatch
import Foundation
import os
import Synchronization

/// A benchmark instrument for `runSmokeBenchmark`: the main queue's
/// queueing delay, measured by a block posted from a user-interactive
/// thread every ``MainQueueLatencyProbe/pingInterval``. A delay above
/// ``MainQueueLatencyProbe/stallThreshold`` is a stall, also emitted as a
/// `MainThreadStall` Point of Interest for Instruments.
///
/// A nested event loop that never ends still drains the main queue, so a
/// frozen menu reads here as zero delay; ``MenuTrackingWatchdog`` watches
/// for that.
final nonisolated class MainQueueLatencyProbe: Sendable {
    static let pingInterval: Duration = .milliseconds(16)
    static let stallThreshold: Duration = .milliseconds(50)

    /// What one window of pings saw.
    struct Snapshot: Encodable, Equatable {
        var pings: Int
        var maxDelayMilliseconds: Double
        var stallsOverThreshold: Int
        var stalledMilliseconds: Double
    }

    private struct State {
        var running = false
        var snapshot = Snapshot(
            pings: 0, maxDelayMilliseconds: 0, stallsOverThreshold: 0, stalledMilliseconds: 0,
        )
    }

    private let state = Mutex(State())
    private let clock = ContinuousClock()

    /// Starts the ping thread. Idempotent.
    func start() {
        let shouldStart = state.withLock { state -> Bool in
            if state.running { return false }
            state.running = true
            return true
        }
        guard shouldStart else { return }
        let thread = Thread { [weak self] in
            while let self, self.isRunning {
                let posted = self.clock.now
                DispatchQueue.main.async { self.record(delay: posted.duration(to: self.clock.now)) }
                Thread.sleep(forTimeInterval: Self.pingInterval.seconds)
            }
        }
        thread.name = "Main thread watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        state.withLock { $0.running = false }
    }

    /// The counters since the previous snapshot, then reset.
    func snapshotAndReset() -> Snapshot {
        state.withLock { state in
            defer {
                state.snapshot = Snapshot(
                    pings: 0, maxDelayMilliseconds: 0, stallsOverThreshold: 0,
                    stalledMilliseconds: 0,
                )
            }
            return state.snapshot
        }
    }

    private var isRunning: Bool {
        state.withLock(\.running)
    }

    /// Accounts one delivered ping; internal so a test can feed delays.
    func record(delay: Duration) {
        let milliseconds = delay.milliseconds
        let stalled = delay >= Self.stallThreshold
        state.withLock { state in
            state.snapshot.pings += 1
            state.snapshot.maxDelayMilliseconds = max(state.snapshot.maxDelayMilliseconds, milliseconds)
            if stalled {
                state.snapshot.stallsOverThreshold += 1
                state.snapshot.stalledMilliseconds += milliseconds
            }
        }
        if stalled {
            PerfProbe.poi.emitEvent(
                "MainThreadStall", "delay_ms=\(Int(milliseconds.rounded()), privacy: .public)",
            )
        }
    }
}

nonisolated extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    var seconds: Double {
        milliseconds / 1000
    }
}
