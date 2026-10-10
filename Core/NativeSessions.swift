import Darwin
import Foundation

/// The macOS builds running right now, as the engine's native supervisor
/// records them.
///
/// The dock shim starts every macOS build a game is mapped to
/// (``SteamPlayMacOS``) through `sevo-native-supervisor`, which runs the game
/// as the leader of a new process group, holds the pipe Steam's waiter
/// watches, and keeps one file per running game at
/// `<bottle>/.sevo/native-sessions/<supervisor pid>.json`, written whole by a
/// rename and removed when the supervisor exits. That file is the game's
/// identity outside the bottle: which windows are a game's wherever its
/// library is, and which processes a stop ends.
nonisolated enum NativeSessions {
    enum Constants {
        /// The sessions directory, relative to the bottle.
        static let directory = ".sevo/native-sessions"
        /// The file format this reader understands.
        static let version = 1
        /// The supervisor's executable name, which a live session's pid runs.
        static let supervisorName = "sevo-native-supervisor"
        /// How long a supervisor gets to end its game and exit after `SIGTERM`:
        /// its own ladder is ten seconds of grace, then `SIGKILL`.
        static let stopWait: Duration = .seconds(15)
        /// How often a stop looks at the supervisors while it waits.
        static let poll: Duration = .milliseconds(100)
        /// The most process-group members read for one session.
        static let groupCapacity = 1024
    }

    /// One running macOS build.
    struct Session: Equatable, Sendable {
        let appID: Int
        /// The supervisor's pid, which a stop signals and the file is named after.
        let supervisor: pid_t
        /// The game's own pid, the leader of its process group.
        let game: pid_t
        let processGroup: pid_t
        let executable: String
        /// The game's `.app`.
        let bundle: String
        let started: Date

        /// The bundle's file name, lowercased like every program name the
        /// window watch compares (``WineWindowWatch``).
        var name: String {
            URL(fileURLWithPath: bundle).lastPathComponent.lowercased()
        }

        /// Whether a process belongs to this game: the game itself, or any
        /// process still in its group.
        func owns(pid: pid_t, processGroup group: pid_t?) -> Bool {
            pid == game || (group.map { $0 == processGroup } ?? false)
        }
    }

    /// What the reader needs from the machine, so a test can stand in for it.
    protocol Machine: Sendable {
        /// Whether `pid` is a live native supervisor. A file whose supervisor
        /// is gone, or whose pid now runs something else, is stale.
        func isSupervisor(_ pid: pid_t) -> Bool
        func processGroup(of pid: pid_t) -> pid_t?
        func members(ofProcessGroup group: pid_t) -> [pid_t]
    }

    struct LiveMachine: Machine {
        func isSupervisor(_ pid: pid_t) -> Bool {
            guard let path = WineOrphans.executablePath(of: pid) else { return false }
            return URL(fileURLWithPath: path).lastPathComponent == Constants.supervisorName
        }

        func processGroup(of pid: pid_t) -> pid_t? {
            let group = getpgid(pid)
            return group > 0 ? group : nil
        }

        func members(ofProcessGroup group: pid_t) -> [pid_t] {
            var pids = [pid_t](repeating: 0, count: Constants.groupCapacity)
            let bytes = Int(proc_listpgrppids(group, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
            let count = min(max(0, bytes / MemoryLayout<pid_t>.size), pids.count)
            return pids.prefix(count).filter { $0 > 0 }
        }
    }

    static func directory(inBottle bottle: URL) -> URL {
        bottle.appendingPathComponent(Constants.directory, isDirectory: true)
    }

    /// One session file's contents, or `nil` for a file of another version
    /// or off the shape.
    static func parse(_ data: Data) -> Session? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == Constants.version,
              let appID = (object["appid"] as? String).flatMap({ Int($0) }) ?? (object["appid"] as? NSNumber)?.intValue,
              appID > 0,
              let supervisor = pid(object["supervisor"]),
              let game = pid(object["game"]),
              let group = pid(object["pgid"]),
              let executable = object["executable"] as? String,
              let bundle = object["bundle"] as? String, !bundle.isEmpty,
              let started = (object["started"] as? NSNumber)?.doubleValue
        else { return nil }
        return Session(
            appID: appID, supervisor: supervisor, game: game, processGroup: group,
            executable: executable, bundle: bundle, started: Date(timeIntervalSince1970: started),
        )
    }

    private static func pid(_ value: Any?) -> pid_t? {
        guard let number = (value as? NSNumber)?.intValue, number > 0, number <= Int(Int32.max) else { return nil }
        return pid_t(number)
    }

    /// The sessions whose supervisor is running. Temporary files (dotfiles)
    /// and stale files are skipped; `removingStale` also takes the stale ones
    /// off the disk.
    static func live(
        inBottle bottle: URL = SteamBottle.root,
        machine: some Machine = LiveMachine(),
        removingStale: Bool = false,
    ) -> [Session] {
        let directory = directory(inBottle: bottle)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var sessions: [Session] = []
        for name in names where !name.hasPrefix(".") && name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let session = parse(data) else { continue }
            guard machine.isSupervisor(session.supervisor) else {
                if removingStale { try? FileManager.default.removeItem(at: url) }
                continue
            }
            sessions.append(session)
        }
        return sessions.sorted { $0.supervisor < $1.supervisor }
    }

    /// The session a process belongs to, or `nil` for a process that is no
    /// running macOS build's.
    static func session(
        owning pid: pid_t, in sessions: [Session], machine: some Machine = LiveMachine(),
    ) -> Session? {
        guard !sessions.isEmpty else { return nil }
        let group = machine.processGroup(of: pid)
        return sessions.first { $0.owns(pid: pid, processGroup: group) }
    }

    /// Every process of an app's running macOS builds: each supervisor, its
    /// game, and whatever is left in the game's process group.
    static func processes(
        ofApp appID: Int, in sessions: [Session], machine: some Machine = LiveMachine(),
    ) -> [pid_t] {
        var pids: [pid_t] = []
        for session in sessions where session.appID == appID {
            for pid in [session.supervisor, session.game] + machine.members(ofProcessGroup: session.processGroup)
                where !pids.contains(pid) {
                pids.append(pid)
            }
        }
        return pids
    }

    /// What a stop came to: the supervisors that exited, and those still
    /// running when the wait ran out.
    struct StopOutcome: Equatable, Sendable {
        var stopped: [pid_t] = []
        var survivors: [pid_t] = []
    }

    /// Stops an app's running macOS builds through their supervisors:
    /// `SIGTERM` to each, which ends the game's whole process group, removes
    /// its file and closes the pipe Steam's waiter watches, so Steam sees the
    /// game stop. Answers once every supervisor has exited or
    /// ``Constants/stopWait`` has passed.
    static func stop(
        appID: Int,
        in sessions: [Session],
        machine: some Machine = LiveMachine(),
        processes: some GameEnding.Processes = GameEnding.LiveProcesses(),
        wait: Duration = Constants.stopWait,
    ) async -> StopOutcome {
        let supervisors = sessions.filter { $0.appID == appID }.map(\.supervisor)
        guard !supervisors.isEmpty else { return StopOutcome() }
        for pid in supervisors { processes.signal(pid, SIGTERM) }
        func running(_ pid: pid_t) -> Bool { processes.isAlive(pid) && machine.isSupervisor(pid) }
        var remaining = supervisors.filter(running)
        var elapsed: Duration = .zero
        while !remaining.isEmpty, elapsed < wait {
            let step = min(Constants.poll, wait - elapsed)
            await processes.sleep(step)
            elapsed += step
            remaining = remaining.filter(running)
        }
        return StopOutcome(stopped: supervisors.filter { !remaining.contains($0) }, survivors: remaining)
    }
}
