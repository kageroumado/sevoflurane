import Foundation

/// The process whose death takes the bottle down.
///
/// The dock shim in every managed spawn watches `SEVO_OWNER_PID` with a
/// `kqueue` `EVFILT_PROC/NOTE_EXIT` and runs `wineserver -k` when it exits.
/// Only the daemon claims ownership, so an app crash is survivable and a
/// daemon stop final; a spawn without an owner is reaped by nothing.
nonisolated enum BottleOwner {
    static let variable = "SEVO_OWNER_PID"

    /// Claims ownership for everything this process spawns from here on,
    /// CrossOver invocations included, which inherit the environment.
    static func claim() {
        setenv(variable, String(getpid()), 1)
    }

    /// The claimed owner, or nil.
    static var pid: String? {
        ProcessInfo.processInfo.environment[variable]
    }
}
