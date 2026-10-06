import Foundation
import Synchronization

/// What a launch owes a game before any process of it runs: the executables
/// of its install on record, so its env files name it, and on its first
/// launch under Sevoflurane the fix list's values written (``FixLedger``).
///
/// Every path that stages graphics for a game, spawns it or hands it to
/// Steam awaits this first, so the process reads its settings, DLL overrides
/// and renderer as the fixes left them. The wait is bounded by ``budget``:
/// past it the launch goes ahead as the game stands, and the first-launch
/// decision stays unmade, for the next launch to take.
nonisolated enum LaunchPreparation {
    /// How long a launch waits for its preparation. The work is a directory
    /// listing, the run log and a few small files, done in milliseconds on a
    /// healthy disk.
    static let budget: Duration = .seconds(5)

    /// Readies `appID`'s launch, waiting at most `budget`, and answers the
    /// fixes its first launch took, for the caller to announce.
    static func prepare(
        appID: Int, budget: Duration = budget, log: @escaping @Sendable (String) -> Void,
    ) async -> AppliedFixes? {
        let outcome = await run(within: budget) { gate in
            let recorded = GameExecutables.recordFromInstall(appID: appID)
            let fixes = FixLedger.applyAtFirstLaunch(appID: appID, committing: gate.commit)
            if fixes == nil, recorded {
                ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
            }
            return fixes
        }
        switch outcome {
        case let .finished(fixes):
            return fixes
        case .abandoned:
            log(
                "launch \(appID): its preparation took longer than \(budget), so it starts as it stands; "
                    + "its first-launch fixes wait for the next launch",
            )
            return nil
        }
    }

    // MARK: - The bounded wait

    /// How a bounded preparation ended.
    enum Outcome<Value: Sendable>: Sendable {
        /// It finished, before the budget ran out or after it began writing.
        case finished(Value)
        /// The budget ran out first, and the launch went on without it.
        case abandoned
    }

    /// The line between a preparation and the launch waiting on it. The
    /// preparation passes it before each write the launch must see whole;
    /// a launch that stops waiting closes it, unless a write is under way,
    /// in which case the launch waits for that write.
    final class Gate: Sendable {
        private enum State { case open, committing, abandoned }

        private let state = Mutex(State.open)

        /// Whether the preparation may write: `false` once the launch has
        /// gone on without it. From a `true` on, the launch waits for it.
        func commit() -> Bool {
            state.withLock { state in
                guard state != .abandoned else { return false }
                state = .committing
                return true
            }
        }

        /// Whether the launch may go on without the preparation: `false`
        /// when a write is already under way.
        func abandon() -> Bool {
            state.withLock { state in
                guard state == .open else { return false }
                state = .abandoned
                return true
            }
        }
    }

    /// Runs `body` on a global queue and waits for it at most `budget`. A
    /// body that has passed its gate by then is waited for to the end, so a
    /// launch never starts halfway through a write; one that has not finds
    /// the gate closed and writes nothing that needs it.
    ///
    /// The body and the clock both run on Dispatch: the body blocks on the
    /// disk, and a clock on the cooperative pool would wait behind that same
    /// kind of work, which is when the budget matters.
    static func run<Value: Sendable>(
        within budget: Duration, _ body: @escaping @Sendable (Gate) -> Value,
    ) async -> Outcome<Value> {
        let gate = Gate()
        let result = Pending<Value>()
        DispatchQueue.global(qos: .userInitiated).async { result.finish(body(gate)) }
        if let value = await result.value(within: budget) { return .finished(value) }
        guard gate.abandon() else { return await .finished(result.value()) }
        return .abandoned
    }

    /// A value one side sets once and any number of waiters read.
    private final class Pending<Value: Sendable>: Sendable {
        private struct State {
            var value: Value?
            var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]
        }

        private let state = Mutex(State())

        func finish(_ value: Value) {
            let waiters = state.withLock { state in
                state.value = value
                defer { state.waiters = [:] }
                return state.waiters.values
            }
            for waiter in waiters {
                waiter.resume(returning: value)
            }
        }

        /// The value, or `nil` once `budget` has passed without one.
        func value(within budget: Duration) async -> Value? {
            await withCheckedContinuation { continuation in
                let id = UUID()
                guard wait(id, continuation) else { return }
                let (seconds, attoseconds) = budget.components
                let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) {
                    self.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: nil)
                }
            }
        }

        /// The value, however long it takes.
        func value() async -> Value {
            // Only `finish` resumes a waiter that has no clock.
            await withCheckedContinuation { continuation in
                _ = wait(UUID(), continuation)
            }!
        }

        /// Files `continuation` as a waiter, or resumes it at once with a
        /// value already there; answers whether it was filed.
        private func wait(_ id: UUID, _ continuation: CheckedContinuation<Value?, Never>) -> Bool {
            let ready: Value?? = state.withLock { state in
                if let value = state.value { return .some(value) }
                state.waiters[id] = continuation
                return .none
            }
            guard let ready else { return true }
            continuation.resume(returning: ready)
            return false
        }
    }
}
