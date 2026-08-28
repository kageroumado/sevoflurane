import Foundation

/// Runs `body` on the main actor, hopping only when it has to.
///
/// KVO delivers on whichever thread mutated the property. WebKit mutates the
/// properties observed here on the main thread, but that is a WebKit
/// implementation detail rather than a promise, and `MainActor.assumeIsolated`
/// off the main thread is a hard trap rather than a recoverable error. So the
/// assumption is asserted only where it is already true — no hop, so ordering
/// is preserved — and scheduled when it is not.
nonisolated func onMainThread(_ body: @escaping @Sendable @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
}
