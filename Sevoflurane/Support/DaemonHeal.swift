import Foundation

/// The decision the app makes about the background helper it registered,
/// derived from observations alone — the registration state, whether the
/// control port answered, whether a rebuild was already tried this launch, and
/// the two versions — so it can be exercised without touching Background Task
/// Management or `SMAppService`.
///
/// The stuck state this exists for: a Mac that once registered the daemon's
/// label from a Development-signed local build keeps a Background Task
/// Management record whose LightWeight Code Requirement is the Development one.
/// The shipped Developer ID daemon then fails its launch constraint and never
/// answers. Re-registering over an enabled record leaves that requirement in
/// place; only `unregister()` then `register()` tears the record down and
/// rebuilds the requirement from the current bundle's identity.
nonisolated enum DaemonHeal {
    /// What the app observed about its background helper on one attach.
    struct Inputs: Equatable {
        /// Background Task Management holds an enabled record for the label.
        var isRegistered: Bool
        /// The daemon answered the control port within the startup window.
        var isAnswering: Bool
        /// A rebuild has already run this launch.
        var healAlreadyAttempted: Bool
        /// The daemon's reported version, when it answered.
        var daemonVersion: String?
        /// This app's version.
        var appVersion: String
    }

    enum Action: Equatable {
        /// The daemon is answering and current.
        case none
        /// Registered and enabled, yet silent: tear the record down and
        /// rebuild it from this bundle's identity, once.
        case rebuild
        /// The rebuild already ran and the daemon is still silent — a stuck
        /// state the user is shown, not one the app keeps retrying.
        case surfaceFailure
        /// Answering, but older than this app: relaunch it so the app is never
        /// driving a stale helper.
        case restartStale
    }

    static func decide(_ inputs: Inputs) -> Action {
        if inputs.isAnswering {
            if let daemonVersion = inputs.daemonVersion,
               isOlder(daemonVersion, than: inputs.appVersion) {
                return .restartStale
            }
            return .none
        }
        // A missing registration is the caller's ordinary first-run register,
        // not a rebuild — there is no poisoned record to tear down.
        guard inputs.isRegistered else { return .none }
        return inputs.healAlreadyAttempted ? .surfaceFailure : .rebuild
    }

    /// Orders two dotted versions by numeric component, missing trailing
    /// components read as zero so "1.6" equals "1.6.0". A component that is not
    /// a number counts as zero, which keeps a "dev" or empty version from ever
    /// reading as newer than a numbered release.
    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        let left = components(lhs), right = components(rhs)
        for index in 0 ..< max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
