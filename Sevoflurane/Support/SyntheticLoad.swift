import Foundation
import Synchronization

/// Busy threads that stand in for a running game while a scenario is timed.
///
/// A Windows game under Wine keeps every core busy at the default scheduling
/// class, so that is what the threads run at unless asked otherwise. Paths
/// that hold up correctly under this load are scheduled above it (the main
/// thread, the user-initiated bridge queues); anything that stalls was
/// waiting on work that runs at or below the game's priority — a priority
/// inversion, which is what the load exists to find.
final nonisolated class SyntheticLoad: Sendable {
    enum QualityOfService: String, CaseIterable, Sendable {
        case background
        case utility
        case `default`
        case userInitiated

        var thread: Foundation.QualityOfService {
            switch self {
            case .background: .background
            case .utility: .utility
            case .default: .default
            case .userInitiated: .userInitiated
            }
        }
    }

    let threadCount: Int
    let qualityOfService: QualityOfService

    private let stopped = Mutex(false)
    private let finished = DispatchGroup()

    init(threads: Int, qualityOfService: QualityOfService = .default) {
        threadCount = max(0, min(threads, ProcessInfo.processInfo.activeProcessorCount * 2))
        self.qualityOfService = qualityOfService
    }

    func start() {
        for index in 0 ..< threadCount {
            finished.enter()
            let thread = Thread { [self] in
                defer { finished.leave() }
                // A linear congruential step the optimizer cannot fold away
                // between checks of the stop flag.
                var value = UInt64(index) &+ 1
                while !isStopped {
                    for _ in 0 ..< 50_000 {
                        value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    }
                    if value == 0 { value = 1 }
                }
            }
            thread.name = "Synthetic load \(index)"
            thread.qualityOfService = qualityOfService.thread
            thread.start()
        }
    }

    /// Stops the threads and waits for them to exit, so a scenario's
    /// "after" measurements are taken on a quiet machine.
    func stop() {
        stopped.withLock { $0 = true }
        _ = finished.wait(timeout: .now() + 2)
    }

    private var isStopped: Bool {
        stopped.withLock { $0 }
    }
}
