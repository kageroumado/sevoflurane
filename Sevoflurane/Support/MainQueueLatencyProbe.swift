import Dispatch
import Foundation
import os
import Synchronization

/// A benchmark instrument: how long the main thread takes to answer a ping
/// while one scenario step runs. A ping is a block posted to the main queue
/// from a user-interactive thread every ``MainQueueLatencyProbe/pingInterval``;
/// the time until it runs is the main thread's queueing delay at that moment.
/// A delay above ``MainQueueLatencyProbe/stallThreshold`` is a stall — the
/// main thread was busy, or blocked behind lower-priority work — and is
/// also emitted as a `MainThreadStall` Point of Interest so Instruments can
/// line it up with what every other thread was doing.
///
/// It runs only inside `runSmokeBenchmark`, and it measures queueing delay
/// rather than responsiveness: a nested event loop that never ends still
/// drains the main queue, so a frozen menu reads here as zero delay.
/// ``MenuTrackingWatchdog`` is what watches for that.
final nonisolated class MainQueueLatencyProbe: Sendable {
    static let pingInterval: Duration = .milliseconds(16)
    static let stallThreshold: Duration = .milliseconds(50)

    /// What one window of pings saw. `pings` is how many were delivered;
    /// `maxDelayMilliseconds` the worst single queueing delay.
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

    /// The counters since the previous snapshot, which are then reset — one
    /// call per scenario step gives per-step figures.
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

    /// Accounts one delivered ping. Internal so a test can feed delays
    /// without a live main run loop.
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
