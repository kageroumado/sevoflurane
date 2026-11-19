import Foundation

/// Runs `body` on the main actor, hopping only when it has to.
///
/// KVO delivers on the mutating thread. WebKit mutates on main in practice
/// without promising it, and `MainActor.assumeIsolated` off main traps, so
/// the body runs inline on main (keeping order) and is scheduled otherwise.
nonisolated func onMainThread(_ body: @escaping @Sendable @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
}
