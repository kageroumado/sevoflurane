import Foundation

/// The process whose death takes the bottle down.
///
/// The engine's dock shim is `DYLD_INSERT_LIBRARIES`'d into every managed
/// spawn; where it finds `SEVO_OWNER_PID` it opens a `kqueue`
/// `EVFILT_PROC/NOTE_EXIT` on that pid and runs `wineserver -k` when it fires.
/// So whichever process claims ownership here is the one the prefix cannot
/// outlive — the daemon, never the app, which is exactly what makes an app
/// crash survivable and a daemon stop final.
///
/// A spawn with no owner is a bottle nothing reaps: only the daemon claims it,
/// so a stray client started by anything else keeps running until something
/// asks it to stop.
nonisolated enum BottleOwner {
    static let variable = "SEVO_OWNER_PID"

    /// Claims ownership for this process, for everything it spawns from here
    /// on. Setting it in the environment covers the CrossOver invocations too,
    /// which inherit it rather than being handed an environment of their own.
    static func claim() {
        setenv(variable, String(getpid()), 1)
    }

    /// The owner as a spawn should carry it, or nil in a process that has not
    /// claimed the bottle.
    static var pid: String? {
        ProcessInfo.processInfo.environment[variable]
    }
}
