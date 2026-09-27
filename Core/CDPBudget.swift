import Foundation

/// The whole allowance for opening DevTools sessions against the bottled
/// client, in one place.
///
/// CEF serves `/json` and every WebSocket upgrade from a single thread, so
/// what one session costs, every other session pays. Per-call caps bound how
/// long one exchange may take and nothing bounded how many ran at once, so
/// "at most five seconds per call" composed into a hundred concurrent calls
/// and the DevTools server went silent for thirty-two seconds on a client
/// that was alive and idle. This is the missing half: a token bucket over
/// session creation, so a burst waits its turn instead of arriving together.
///
/// The bridge's own persistent SharedJSContext socket is one connection for
/// the app's lifetime and carries the page's hot path; it spends a permit to
/// open, and none of its traffic after that.
actor CDPBudget {
    static let shared = CDPBudget()

    /// How many one-shot DevTools exchanges may be in flight at once.
    static let concurrentSessions = 2

    /// How many may start in any one second.
    static let perSecond = 8.0

    /// How long one exchange may hold its permit.
    static let callCap: Duration = .seconds(5)

    /// How often a waiting caller looks again. Contention is rare and short,
    /// so the cost of asking is a few comparisons on an actor that is
    /// otherwise idle.
    private static let retryInterval: Duration = .milliseconds(50)

    private let ceiling: Int
    private let rate: Double
    private var inFlight = 0
    private var tokens: Double
    private var refilled = ContinuousClock.now

    init(concurrentSessions: Int = CDPBudget.concurrentSessions, perSecond: Double = CDPBudget.perSecond) {
        ceiling = concurrentSessions
        rate = perSecond
        tokens = perSecond
    }

    /// Takes a permit, waiting until both the concurrency ceiling and the
    /// rate allow it. `caller` names the surface in the log line a wait
    /// produces. Balance every call with ``release()``.
    func take(_ caller: String) async {
        var announced = false
        while true {
            refill()
            if inFlight < ceiling, tokens >= 1 {
                tokens -= 1
                inFlight += 1
                return
            }
            if !announced {
                announced = true
                ClientLifecycle.log(
                    "\(caller) is waiting on the CDP budget — \(inFlight) session(s) in flight",
                )
            }
            do {
                try await Task.sleep(for: Self.retryInterval)
            } catch {
                // A cancelled caller takes its permit and lets the work it
                // wraps fail on its own cancellation check, so the release
                // that balances this stays paired.
                tokens = max(tokens - 1, 0)
                inFlight += 1
                return
            }
        }
    }

    func release() {
        inFlight = max(inFlight - 1, 0)
    }

    /// What is in flight and what is left of this second's allowance, for a
    /// test to read.
    var state: (inFlight: Int, tokens: Double) {
        (inFlight, tokens)
    }

    private func refill() {
        let now = ContinuousClock.now
        let gap = refilled.duration(to: now).components
        let elapsed = Double(gap.seconds) + Double(gap.attoseconds) / 1e18
        guard elapsed > 0 else { return }
        refilled = now
        tokens = min(rate, tokens + elapsed * rate)
    }
}

extension CDPBudget {
    /// Runs `body` holding one permit from the shared budget.
    static func spend<T>(_ caller: String, _ body: () async throws -> T) async throws -> T {
        try await spend(caller, on: shared, body)
    }

    /// The same, against a budget of the caller's own — how a test drives it
    /// without the app's.
    static func spend<T>(
        _ caller: String, on budget: CDPBudget, _ body: () async throws -> T,
    ) async throws -> T {
        await budget.take(caller)
        do {
            let value = try await body()
            await budget.release()
            return value
        } catch {
            await budget.release()
            throw error
        }
    }
}
