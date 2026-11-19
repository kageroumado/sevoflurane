import Foundation

/// A token bucket over DevTools session creation against the bottled client.
/// CEF serves `/json` and every WebSocket upgrade from one thread, and a
/// hundred concurrent capped calls once silenced an idle client's DevTools
/// server for thirty-two seconds. The bridge's persistent socket spends one
/// permit to open and none after.
actor CDPBudget {
    static let shared = CDPBudget()

    static let concurrentSessions = 2

    /// Session starts per second.
    static let perSecond = 8.0

    /// How long one exchange may hold its permit.
    static let callCap: Duration = .seconds(5)

    /// How often a waiting caller looks again; contention is rare and short.
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

    /// Takes a permit when the ceiling and rate allow; `caller` names the
    /// waiter in the log. Balance every call with ``release()``.
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
                // A cancelled caller still takes a permit, so its release
                // stays paired; its work fails on its own cancellation check.
                tokens = max(tokens - 1, 0)
                inFlight += 1
                return
            }
        }
    }

    func release() {
        inFlight = max(inFlight - 1, 0)
    }

    /// For tests.
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

    /// The same, against a budget of the caller's own.
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
