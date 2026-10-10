import Darwin
import Foundation

/// Ends a game's own processes before Steam is asked to, so that a stop
/// somebody asked for leaves no crash report behind.
///
/// Steam's `TerminateApp` reaches the game as `TerminateProcess`, and Wine
/// carries that out one thread at a time: the server sends every Wine thread
/// `SIGQUIT` (`server/thread.c`, `kill_thread`), and each thread's handler
/// leaves through `pthread_exit` (`dlls/ntdll/unix/thread.c`, `abort_thread`)
/// while the threads Wine did not make — AppKit's main thread, Metal's and
/// Core Audio's workers, libdispatch's — keep running. A Wine thread that dies
/// inside a Metal or XPC call owning a libdispatch workloop leaves the next
/// worker to find that owner gone, and libdispatch aborts the process
/// (`Invalid workloop owner`); macOS files that as a crash of the game's own
/// bundle and asks whether to reopen it. A signal to the whole process has no
/// such window: the kernel ends every thread at once with no user code in
/// between, and `SIGTERM`, which nothing in the engine handles, ends the
/// process without a report.
///
/// So a stop on purpose ends the game's processes here first — `SIGTERM`, a
/// bounded wait, `SIGKILL` for whatever is left — and only then reaches Steam,
/// whose `TerminateApp` finds no process to tear down and clears its own
/// record of the run. A game that crashes on its own still files its report:
/// only the stop the player or `sevo` asked for takes this path.
///
/// A macOS build runs under the engine's native supervisor
/// (``NativeSessions``), which owns the game's process group and the pipe
/// Steam's waiter watches; that build is stopped through its supervisor first,
/// and the same ladder then ends whatever of it is left.
nonisolated enum GameEnding {
    /// How long a process gets to leave on `SIGTERM` before `SIGKILL`.
    static let grace: Duration = .seconds(5)
    /// How long the kernel gets to reap a `SIGKILL`ed process before it is
    /// reported as a survivor.
    static let killGrace: Duration = .seconds(2)
    /// How often the processes are looked at while a wait runs.
    static let poll: Duration = .milliseconds(100)

    /// What the ladder needs from the machine, so a test can stand in for it.
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

    /// What became of the processes: which left on `SIGTERM`, which needed
    /// `SIGKILL`, and which answered to the end.
    struct Outcome: Equatable, Sendable {
        var terminated: [pid_t] = []
        var killed: [pid_t] = []
        var survivors: [pid_t] = []
        /// The native supervisors that ended their macOS build and exited.
        var sessionsStopped: [pid_t] = []
        /// The native supervisors still running when their stop's wait ran
        /// out; the ladder then signaled them with the rest.
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

    /// Ends the game: its running macOS builds through their supervisors,
    /// then every process of it still alive (``processes(ofApp:)``), and
    /// answers what it took.
    static func end(appID: Int) async -> Outcome {
        let stop = await NativeSessions.stop(appID: appID, in: NativeSessions.live(removingStale: true))
        var outcome = await end(processes(ofApp: appID))
        outcome.sessionsStopped = stop.stopped
        outcome.sessionsUnstopped = stop.survivors
        return outcome
    }

    /// `SIGTERM` to every live process at once, `grace` for them to go, then
    /// `SIGKILL` to what is left and ``killGrace`` for the kernel to reap it.
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

    /// The pids among `pids` still alive once they have all gone or `wait`
    /// has passed, whichever comes first.
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

    /// The game's own processes: those of its running macOS builds
    /// (``NativeSessions``), and those in this bottle named from its
    /// executables — every plausible exe in a Steam game's install directory,
    /// the one file an adopted program is. An app whose files cannot be placed
    /// and that runs no macOS build has nothing to match, and then only
    /// Steam's record speaks for it.
    static func processes(ofApp appID: Int) async -> [pid_t] {
        let native = NativeSessions.processes(ofApp: appID, in: NativeSessions.live())
        let bottled = await bottleProcesses(ofApp: appID)
        return native + bottled.filter { !native.contains($0) }
    }

    private static func bottleProcesses(ofApp appID: Int) async -> [pid_t] {
        let names = executableNames(ofApp: appID)
        guard !names.isEmpty else { return [] }
        // `pgrep` matches a pattern anywhere in the command line, so the
        // bottle-scoped candidates are kept only where the program itself —
        // argv[0]'s last path component — carries one of the names exactly.
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
