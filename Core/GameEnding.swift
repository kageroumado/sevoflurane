import Darwin
import Foundation

/// Ends a game's own processes before Steam is asked to, so a requested stop
/// leaves no crash report.
///
/// Steam's `TerminateApp` makes Wine end one thread at a time (`SIGQUIT`,
/// `kill_thread`, then `abort_thread`'s `pthread_exit`) while non-Wine
/// threads keep running; a Wine thread dying inside a Metal or XPC call that
/// owns a libdispatch workloop makes libdispatch abort (`Invalid workloop
/// owner`), which macOS files as the game's crash. A whole-process `SIGTERM`,
/// unhandled by the engine, ends every thread at once without a report.
///
/// A macOS build is stopped through its native supervisor
/// (``NativeSessions``) first, and the same ladder ends what is left.
nonisolated enum GameEnding {
    /// How long a process gets to leave on `SIGTERM` before `SIGKILL`.
    static let grace: Duration = .seconds(5)
    /// How long the kernel gets to reap a `SIGKILL`ed process.
    static let killGrace: Duration = .seconds(2)
    static let poll: Duration = .milliseconds(100)

    /// What the ladder needs from the machine, replaceable in tests.
    protocol Processes: Sendable {
        /// Whether the process is still running: a zombie is gone.
        func isAlive(_ pid: pid_t) -> Bool
        func signal(_ pid: pid_t, _ signal: Int32)
        func sleep(_ duration: Duration) async
    }

    struct LiveProcesses: Processes {
        func isAlive(_ pid: pid_t) -> Bool {
            guard ProcessUsage.exists(pid: pid) else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
            }
            return read != size || info.pbi_status != UInt32(SZOMB)
        }

        func signal(_ pid: pid_t, _ signal: Int32) {
            kill(pid, signal)
        }

        func sleep(_ duration: Duration) async {
            try? await Task.sleep(for: duration)
        }
    }

    /// Which processes left on `SIGTERM`, needed `SIGKILL`, or survived.
    struct Outcome: Equatable, Sendable {
        var terminated: [pid_t] = []
        var killed: [pid_t] = []
        var survivors: [pid_t] = []
        /// The native supervisors that ended their macOS build and exited.
        var sessionsStopped: [pid_t] = []
        /// Native supervisors still running after their stop's wait.
        var sessionsUnstopped: [pid_t] = []

        var isEmpty: Bool {
            terminated.isEmpty && killed.isEmpty && survivors.isEmpty
                && sessionsStopped.isEmpty && sessionsUnstopped.isEmpty
        }

        /// One line for the log, or `nil` when there was nothing to end.
        var summary: String? {
            guard !isEmpty else { return nil }
            var parts: [String] = []
            if !sessionsStopped.isEmpty {
                parts.append("\(Self.count(sessionsStopped, "macOS build")) stopped through the native supervisor")
            }
            if !sessionsUnstopped.isEmpty {
                parts.append("\(Self.count(sessionsUnstopped, "native supervisor")) ignored the stop: \(sessionsUnstopped)")
            }
            if !terminated.isEmpty { parts.append("\(Self.count(terminated)) ended on SIGTERM") }
            if !killed.isEmpty { parts.append("\(Self.count(killed)) needed SIGKILL") }
            if !survivors.isEmpty { parts.append("\(Self.count(survivors)) survived: \(survivors)") }
            return "game processes: " + parts.joined(separator: ", ")
        }

        private static func count(_ pids: [pid_t], _ noun: String = "process") -> String {
            let plural = noun.hasSuffix("s") ? noun + "es" : noun + "s"
            return pids.count == 1 ? "1 \(noun)" : "\(pids.count) \(plural)"
        }
    }

    /// Ends the game's macOS builds through their supervisors, then every
    /// process of it still alive (``processes(ofApp:)``).
    static func end(appID: Int) async -> Outcome {
        let stop = await NativeSessions.stop(appID: appID, in: NativeSessions.live(removingStale: true))
        var outcome = await end(processes(ofApp: appID))
        outcome.sessionsStopped = stop.stopped
        outcome.sessionsUnstopped = stop.survivors
        return outcome
    }

    /// `SIGTERM` to all, `grace` to go, then `SIGKILL` and ``killGrace``.
    static func end(
        _ pids: [pid_t], grace: Duration = grace, processes: some Processes = LiveProcesses(),
    ) async -> Outcome {
        let targets = pids.filter(processes.isAlive)
        guard !targets.isEmpty else { return Outcome() }
        for pid in targets { processes.signal(pid, SIGTERM) }
        let unmoved = await remaining(of: targets, after: grace, processes: processes)
        var outcome = Outcome(terminated: targets.filter { !unmoved.contains($0) })
        guard !unmoved.isEmpty else { return outcome }
        for pid in unmoved { processes.signal(pid, SIGKILL) }
        let survivors = await remaining(of: unmoved, after: killGrace, processes: processes)
        outcome.killed = unmoved.filter { !survivors.contains($0) }
        outcome.survivors = survivors
        return outcome
    }

    /// The pids still alive once all have gone or `wait` has passed.
    private static func remaining(
        of pids: [pid_t], after wait: Duration, processes: some Processes,
    ) async -> [pid_t] {
        var elapsed: Duration = .zero
        var alive = pids.filter(processes.isAlive)
        while !alive.isEmpty, elapsed < wait {
            let step = min(poll, wait - elapsed)
            await processes.sleep(step)
            elapsed += step
            alive = alive.filter(processes.isAlive)
        }
        return alive
    }

    // MARK: - Which processes are the game's

    /// The game's macOS build processes (``NativeSessions``) and the bottle's
    /// processes named after its executables.
    static func processes(ofApp appID: Int) async -> [pid_t] {
        let native = NativeSessions.processes(ofApp: appID, in: NativeSessions.live())
        let bottled = await bottleProcesses(ofApp: appID)
        return native + bottled.filter { !native.contains($0) }
    }

    private static func bottleProcesses(ofApp appID: Int) async -> [pid_t] {
        let names = executableNames(ofApp: appID)
        guard !names.isEmpty else { return [] }
        // `pgrep` matches anywhere in the command line, so only candidates
        // whose argv[0] last component is one of the names are kept.
        let listing = await Subprocess.run("/usr/bin/pgrep", WineProcessList.pgrepArguments).output
        let exact = Set(names.flatMap { WineProcessList.pids(named: $0, inPgrepLong: listing) })
        guard !exact.isEmpty else { return [] }
        let patterns = names.map { NSRegularExpression.escapedPattern(for: $0) }
        return await ClientLifecycle.bottleProcessIDs(matchingAnyOf: patterns).filter(exact.contains)
    }

    static func executableNames(ofApp appID: Int) -> [String] {
        if AdoptedPrograms.isAdopted(appID) {
            return AdoptedPrograms.program(appID)
                .map { [$0.url.lastPathComponent.lowercased()] } ?? []
        }
        guard let directory = SharedGames.installDirectory(appID: appID) else { return [] }
        return GameExecutables.executables(in: directory)
    }
}
