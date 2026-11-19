import Foundation

/// What the app does about its registered background helper, decided from
/// observations alone so tests need no `SMAppService`.
///
/// The stuck state: a Mac that once registered the label from a
/// Development-signed build keeps a Background Task Management record with the
/// Development code requirement, and the Developer ID daemon then fails its
/// launch constraint. Re-registering keeps that requirement; only
/// `unregister()` then `register()` rebuilds it.
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
        /// The running daemon's build, when it reports one.
        var daemonBuild: String?
        /// The build of the daemon inside this app's bundle.
        var bundledDaemonBuild: String?
    }

    enum Action: Equatable {
        /// The daemon is answering and current.
        case none
        /// Registered and enabled, yet silent: tear the record down and
        /// rebuild it from this bundle's identity, once.
        case rebuild
        /// Still silent after the rebuild: shown to the user, not retried.
        case surfaceFailure
        /// Answering, but older than this app or another build: relaunch it,
        /// since launchd keeps a daemon's process across a bundle update.
        case restartStale
    }

    /// What a manual `repair()` does: it rebuilds only a silent daemon unless
    /// forced, since rebuilding a healthy one detaches the app for nothing.
    enum RepairAction: Equatable {
        /// The daemon is answering; leave it and the app's attachment alone.
        case alreadyHealthy
        /// The daemon is answering but its supervision gave up on the client: restart the
        /// client, which starts the crash-loop count over.
        case restartClient
        /// Tear the registration down and rebuild it from this bundle.
        case rebuild
    }

    static func repairAction(isAnswering: Bool, supervisionGaveUp: Bool = false, force: Bool) -> RepairAction {
        if force { return .rebuild }
        guard isAnswering else { return .rebuild }
        return supervisionGaveUp ? .restartClient : .alreadyHealthy
    }

    /// One step of the wait after a rebuild: a repair succeeds only once the
    /// new helper reports the app attached.
    enum RepairAttach: Equatable {
        /// The helper reports the app attached; the repair is done.
        case attached
        /// Keep polling.
        case wait
        /// Say hello again: the first one may have reached the helper that
        /// was on its way out.
        case helloAgain
        /// The helper has not taken the app within the budget.
        case timedOut
    }

    /// Seconds a rebuilt helper has to report the app attached.
    static let repairAttachBudget = 20
    /// Seconds before the one repeated hello.
    static let repairHelloAgainAfter = 5

    static func repairAttach(daemonSeesApp: Bool, elapsed: Int, saidHelloAgain: Bool) -> RepairAttach {
        if daemonSeesApp { return .attached }
        if elapsed >= repairAttachBudget { return .timedOut }
        if !saidHelloAgain, elapsed >= repairHelloAgainAfter { return .helloAgain }
        return .wait
    }

    static func decide(_ inputs: Inputs) -> Action {
        if inputs.isAnswering {
            if let daemonVersion = inputs.daemonVersion,
               AppVersion.isOlder(daemonVersion, than: inputs.appVersion) {
                return .restartStale
            }
            // A daemon that reports no build is another build than this app ships.
            if let bundled = inputs.bundledDaemonBuild, inputs.daemonBuild ?? "" != bundled {
                return .restartStale
            }
            return .none
        }
        // A missing registration is the caller's ordinary first-run register,
        // not a rebuild — there is no poisoned record to tear down.
        guard inputs.isRegistered else { return .none }
        return inputs.healAlreadyAttempted ? .surfaceFailure : .rebuild
    }
}
