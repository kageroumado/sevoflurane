import Foundation
import Observation

/// Watches every process this app owns, names what each of them is doing, and
/// unwedges a game that has stopped doing anything.
///
/// The signal is deliberately cheap: a process's CPU time, read with
/// `proc_pid_rusage` every ``Rules/sampleEvery``, and the driver's present
/// counter where it exists. A process that has used no CPU for
/// ``Rules/candidateAfter`` and has presented nothing is a stall candidate;
/// one that is `SIGSTOP`ped reads the same way and is not a stall at all,
/// which is why the state is asked for rather than inferred.
///
/// Then a ladder, each rung written into the run record: release what is ours,
/// `SIGCONT` the tree, wait again, and only then kill it. A client process
/// at rest is left alone: the supervisor asks the client itself whether it works.
///
/// The same samples are what the process monitor shows; the window is this
/// object's view.
@MainActor
@Observable
final class StallWatch {
    /// Thresholds, all of them from the plan.
    nonisolated enum Rules {
        /// How often every process we own is read.
        static let sampleEvery: Duration = .seconds(2)
        /// No CPU for this long makes a process a stall candidate.
        static let candidateAfter: TimeInterval = 15
        /// How long a game gets after the release rungs before it is killed.
        static let killAfter: TimeInterval = 15
        /// A process using less than this share of one core counts as using
        /// none: a spin-wait at a few micros a second is not progress.
        static let idleCPUShare = 0.005
        /// One thread that never yields reads as one whole core, sample after sample. A game
        /// at work moves: over a core with its workers, under it while it waits for a frame.
        static let oneCoreBand = 0.93 ... 1.07
        /// How long a process stays inside ``oneCoreBand`` before the monitor says so.
        static let oneCoreAfter: TimeInterval = 60
        /// The engine beats once a second from the game's Cocoa main thread. This long
        /// without one and the window answers nothing: no click, no key, no close.
        static let notAnsweringAfter: TimeInterval = 10
        /// How long a run whose own process is gone waits for the client's stop edge
        /// before the watch ends Steam's entry itself and closes the run. The client
        /// reports an exit within a couple of seconds when it saw it; an entry that
        /// outlives its process by this much has been forgotten, and every later
        /// launch is a silent no-op until it clears.
        static let clientStopGrace: TimeInterval = 15
    }

    /// What a process is to us.
    nonisolated enum Role: String, Sendable, CaseIterable {
        /// Steam itself and its web helper.
        case client
        /// The bottle's own plumbing: services, the device host, explorer.
        case helper
        /// A game's own executable.
        case game
        /// Something a game started.
        case gameChild
        /// The engine's macOS-side processes: the Wine server, the relay.
        case driver
    }

    /// How a process reads right now.
    nonisolated enum State: String, Sendable {
        case running
        /// No CPU since the last sample, but not for long enough to matter.
        case idle
        /// `SIGSTOP`ped — by us, by a debugger, or by a terminal.
        case stopped
        /// No CPU and no present for ``Rules/candidateAfter``.
        case stalled
        /// The window's main thread has stopped while the process runs on: the picture may
        /// still move, and nothing the user does reaches the game.
        case notAnswering = "not answering"
    }

    /// One process we own, as the last sample saw it.
    nonisolated struct Process: Identifiable, Sendable, Equatable {
        var id: pid_t { pid }
        let pid: pid_t
        /// The Windows executable when the engine's chronicle named one,
        /// otherwise the Unix process name.
        let name: String
        let role: Role
        let cpuSeconds: Double
        /// Share of one core since the previous sample, 0 to the core count.
        let cpuShare: Double
        let footprintBytes: UInt64
        /// Frames the driver has presented for this process, when it has a
        /// counter. Absent for a process with no Metal layer.
        let presents: UInt64?
        let state: State
        /// The app id of the run this process belongs to, when it is a game's.
        let appID: Int?
        /// The process has held exactly one core for ``Rules/oneCoreAfter``: a busy loop,
        /// which a game at rest on a menu should not be in.
        var holdsOneCore = false
    }

    /// Called once for each process whose window stops answering. The app asks the user
    /// whether to end it; nothing is killed on this signal alone, since a debugger or a
    /// sleeping Mac stops a main thread too.
    @ObservationIgnored var onNotAnswering: ((Process) -> Void)?
    @ObservationIgnored private var reportedNotAnswering: Set<pid_t> = []

    /// Called once for each run whose process has been gone for ``Rules/clientStopGrace``
    /// with no stop edge from the client. The app asks the client to end the app, which
    /// clears the entry Steam kept for a process it lost track of.
    @ObservationIgnored var onGameProcessGone: ((Int) -> Void)?
    /// When each open run's process was first found gone, by app id.
    @ObservationIgnored private var goneSince: [Int: TimeInterval] = [:]

    /// Ends a game the user gave up on: the whole tree under it, and the run closes as a
    /// watchdog ending.
    func end(_ process: Process) {
        for pid in tree(under: [process.pid]) { probes.signal(pid, SIGKILL) }
        probes.log("stall: ended \(process.name) (pid \(process.pid)) at the user's word")
        if let appID = process.appID { recorder?.close(appID: appID, kind: .watchdog) }
    }

    /// Everything we own, most CPU first — what the process monitor lists.
    private(set) var processes: [Process] = []

    /// The seams every reading comes through, so a test can drive a whole
    /// ladder against processes that do not exist.
    nonisolated struct Probes: Sendable {
        var usage: @Sendable (pid_t) -> ProcessUsage? = { ProcessUsage.read(pid: $0) }
        var isStopped: @Sendable (pid_t) -> Bool = { ProcessUsage.isStopped(pid: $0) }
        var children: @Sendable (pid_t) -> [pid_t] = { ProcessUsage.children(of: $0) }
        var name: @Sendable (pid_t) -> String? = { ProcessUsage.name(of: $0) }
        /// A present count for a process, which the kill rung takes as evidence the process
        /// can be judged by its frames. Unanswered in the app: the stats page counts presents,
        /// but a game showing a still picture presents nothing and is not stalled — see
        /// ``killsOnCPUAlone``.
        var presents: @Sendable (pid_t) -> UInt64? = { _ in nil }
        /// How long the process's Cocoa main thread has been silent, when its engine says.
        var mainThreadSilence: @Sendable (pid_t) -> TimeInterval? = { pid in
            // The companion's too: a HoYoverse game's page is written there.
            PresentStats.mainThreadSilence(of: pid) ?? PresentStats.mainThreadSilence(
                of: pid,
                in: SteamBottle.companion.appendingPathComponent(".sevo/run"),
            )
        }
        var signal: @Sendable (pid_t, Int32) -> Void = { kill($0, $1) }
        /// Seconds on a monotonic clock.
        var now: @Sendable () -> TimeInterval = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        }
        var log: @Sendable (String) -> Void = { EventLog.enqueue(.app, $0) }
    }

    /// Whether a game may be killed when nothing can say whether it presented.
    ///
    /// False: a game waiting on a download, a cut scene decoded on another
    /// thread, or a dialog behind its own window all read as zero CPU, and
    /// killing one of those loses a session to a guess. The present counter
    /// does not settle it either — a menu or a paused scene at rest presents
    /// nothing — so the watchdog names the stall, runs the rungs that cost
    /// nothing, and leaves the kill to the user (the not-responding prompt).
    static let killsOnCPUAlone = false

    private let probes: Probes
    private let chronicleURL: URL
    private var tracked: [pid_t: Tracked] = [:]
    private var exeByPID: [pid_t: String] = [:]
    private var chronicle: WineChronicleTail?
    private var loop: Task<Void, Never>?

    /// What a run is told about its own stalls, and what ends one that will
    /// not come back.
    var recorder: RunRecorder?

    /// - Parameter chronicleURL: The dock shim's chronicle, which is where
    ///   the Unix pids and the Windows executables meet. A test points it at
    ///   a file of its own and appends the lines a bottle would have written.
    init(probes: Probes = Probes(), chronicleURL: URL = WineChronicle.url) {
        self.probes = probes
        self.chronicleURL = chronicleURL
        chronicle = WineChronicleTail(url: chronicleURL)
    }

    // MARK: - The loop

    /// Starts sampling. Idempotent: a second call replaces the first loop.
    func start() {
        loop?.cancel()
        chronicle = WineChronicleTail(url: chronicleURL)
        loop = Task(name: "Watch for stalled processes") { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Rules.sampleEvery)
                self?.sample()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One pass: read every process we own, judge each of them, and run the
    /// ladder for anything that has stalled.
    func sample() {
        readChronicle()
        let now = probes.now()
        closeRunsWhoseProcessIsGone(at: now)
        let roots = liveRoots()
        let all = tree(under: roots)
        var seen: Set<pid_t> = []
        var found: [Process] = []
        for pid in all {
            guard let usage = probes.usage(pid) else { continue }
            seen.insert(pid)
            found.append(judge(pid, usage: usage, at: now))
        }
        tracked = tracked.filter { seen.contains($0.key) }
        processes = found.sorted { $0.cpuShare > $1.cpuShare }
        reportedNotAnswering.formIntersection(seen)
        for process in found where process.state == .notAnswering
            && (process.role == .game || process.role == .gameChild)
            && !reportedNotAnswering.contains(process.pid) {
            reportedNotAnswering.insert(process.pid)
            probes.log("stall: \(process.name) (pid \(process.pid)) has stopped answering — its main thread "
                + "is silent while the process runs")
            if let appID = process.appID { note(appID: appID, for: Rules.notAnsweringAfter, unwedged: "not answering") }
            onNotAnswering?(process)
        }
        // A process that moved again, or is gone, starts any later stall's ladder from its
        // own beginning: the kill rung measures one stall, never the time since the first.
        let stalled = Set(found.filter { $0.state == .stalled }.map(\.pid))
        laddersBegan = laddersBegan.filter { stalled.contains($0.key) }
        leftAlone.formIntersection(stalled)
        for process in found where process.state == .stalled {
            climb(for: process, at: now)
        }
        if found.contains(where: { $0.state == .stalled }) { refreshDialogs() }
    }

    /// Ends a run whose process has been gone for ``Rules/clientStopGrace`` without the
    /// client saying it stopped. A stop edge inside the grace closes the run the usual
    /// way and drops it from here; a process the client lost is ended in Steam through
    /// ``onGameProcessGone`` and the run closes as the user's ending, since no exit
    /// status exists for it.
    private func closeRunsWhoseProcessIsGone(at now: TimeInterval) {
        let running = runningPIDs
        goneSince = goneSince.filter { running[$0.key] != nil }
        for (appID, pid) in running {
            guard probes.usage(pid) == nil else {
                goneSince[appID] = nil
                continue
            }
            let since = goneSince[appID] ?? now
            goneSince[appID] = since
            guard now - since >= Rules.clientStopGrace else { continue }
            probes.log(
                "run \(appID): its process (pid \(pid)) is gone and the client has not said it stopped "
                    + "in \(Int(Rules.clientStopGrace)) s — ending Steam's entry and closing the run",
            )
            goneSince[appID] = nil
            onGameProcessGone?(appID)
            recorder?.close(appID: appID, unrecorded: .user)
        }
    }

    /// The pids the chronicle named that are still alive, plus whatever the
    /// recorder knows a run is running under.
    private func liveRoots() -> [pid_t] {
        let alive = exeByPID.keys.filter { probes.usage($0) != nil }
        exeByPID = exeByPID.filter { alive.contains($0.key) }
        return Array(Set(alive + Array(runningPIDs.values)))
    }

    /// What the recorder says each open run is running under.
    private var runningPIDs: [Int: pid_t] {
        recorder?.runningPIDs ?? [:]
    }

    /// Every process under the roots. The roots are bottle processes, so the
    /// tree is the bottle plus whatever a game started.
    private func tree(under roots: [pid_t]) -> [pid_t] {
        var seen: Set<pid_t> = []
        var queue = roots
        var order: [pid_t] = []
        while let pid = queue.first {
            queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            order.append(pid)
            queue += probes.children(pid)
        }
        return order
    }

    /// The engine's chronicle names every bottle process and its executable
    /// the moment `winemac.drv` loads it, which is the only place the Unix
    /// pids and the Windows names meet.
    private func readChronicle() {
        for entry in chronicle?.newEntries() ?? [] where entry.verb == .armed {
            exeByPID[entry.pid] = entry.executable.lowercased()
        }
    }

    // MARK: - Judging one process

    /// What one process has been doing since the last sample, and for how
    /// long it has been doing nothing.
    private nonisolated struct Tracked {
        var cpuNanoseconds: UInt64
        var presents: UInt64?
        /// When the process last did something.
        var lastMoved: TimeInterval
        /// When it was last read, for the share.
        var lastRead: TimeInterval
        /// Since when every sample has been inside ``Rules/oneCoreBand``.
        var oneCoreSince: TimeInterval?
    }

    /// Since when a process has held one core, given where the newest sample falls.
    nonisolated static func oneCoreSince(_ previous: TimeInterval?, share: Double, at now: TimeInterval) -> TimeInterval? {
        Rules.oneCoreBand.contains(share) ? (previous ?? now) : nil
    }

    private func judge(_ pid: pid_t, usage: ProcessUsage, at now: TimeInterval) -> Process {
        let presents = probes.presents(pid)
        let previous = tracked[pid]
        let elapsed = previous.map { now - $0.lastRead } ?? 0
        let burned = usage.cpuTimeNanoseconds &- (previous?.cpuNanoseconds ?? 0)
        let share = elapsed > 0 ? Double(burned) / 1e9 / elapsed : 0
        let drew = presents != nil && presents != previous?.presents
        let moved = previous == nil || share > Rules.idleCPUShare || drew
        let lastMoved = moved ? now : (previous?.lastMoved ?? now)
        let oneCoreSince = Self.oneCoreSince(previous?.oneCoreSince, share: share, at: now)
        tracked[pid] = Tracked(
            cpuNanoseconds: usage.cpuTimeNanoseconds, presents: presents,
            lastMoved: lastMoved, lastRead: now, oneCoreSince: oneCoreSince,
        )
        let name = exeByPID[pid] ?? probes.name(pid) ?? "pid \(pid)"
        let role = role(of: name, pid: pid)
        let holdsOneCore = (role == .game || role == .gameChild)
            && oneCoreSince.map { now - $0 >= Rules.oneCoreAfter } ?? false
        return Process(
            pid: pid,
            name: name,
            role: role,
            cpuSeconds: usage.cpuSeconds,
            cpuShare: (share * 1000).rounded() / 1000,
            footprintBytes: usage.footprintBytes,
            presents: presents,
            state: (probes.mainThreadSilence(pid) ?? 0) >= Rules.notAnsweringAfter
                ? .notAnswering : state(pid: pid, moved: moved, still: now - lastMoved),
            appID: appID(of: pid),
            holdsOneCore: holdsOneCore,
        )
    }

    private func state(pid: pid_t, moved: Bool, still: TimeInterval) -> State {
        // Asked rather than inferred: a stopped process uses no CPU and is
        // not stalled, and the two are indistinguishable from the counter.
        if probes.isStopped(pid) { return .stopped }
        if moved { return .running }
        return still >= Rules.candidateAfter ? .stalled : .idle
    }

    private func role(of name: String, pid: pid_t) -> Role {
        if Self.clientPrograms.contains(name) { return .client }
        if WineWindowWatch.gameInfrastructureOwners.contains(name)
            || Self.bottleHelpers.contains(name) { return .helper }
        if appID(of: pid) != nil { return .game }
        if exeByPID[pid] != nil { return .gameChild }
        return .driver
    }

    private func appID(of pid: pid_t) -> Int? {
        runningPIDs.first { $0.value == pid }?.key
    }

    /// The client's own processes, which the supervisor restarts rather than
    /// the watchdog killing.
    static let clientPrograms: Set<String> = ["steam.exe", "steamwebhelper.exe"]

    /// The bottle's plumbing, which is never a game and never worth killing.
    static let bottleHelpers: Set<String> = [
        "services.exe", "winedevice.exe", "plugplay.exe", "rpcss.exe", "svchost.exe",
        "wineboot.exe", "start.exe", "steamservice.exe", "steamwebhelper.exe",
    ]

    // MARK: - The ladder

    /// One rung, per stalled process, per sample.
    private func climb(for process: Process, at now: TimeInterval) {
        switch process.role {
        case .game, .gameChild:
            unwedge(process, at: now)
        case .client, .helper, .driver:
            // None is a session. A helper at rest is a helper with nothing to
            // do, and so is a client process: Steam's web helper keeps several
            // children that sit at zero CPU for minutes. Whether the client
            // works is the supervisor's question, asked of the client itself.
            break
        }
    }

    /// When each stalled process's ladder began, so the kill rung waits its
    /// own ``Rules/killAfter`` rather than firing on the sample that found it.
    private var laddersBegan: [pid_t: TimeInterval] = [:]
    /// Processes already reported as still and left alone.
    private var leftAlone: Set<pid_t> = []

    /// The rungs, in order, for a game that has stopped doing anything.
    private func unwedge(_ process: Process, at now: TimeInterval) {
        let appID = process.appID ?? appIDOfTree(containing: process.pid)
        let began = laddersBegan[process.pid] ?? now
        laddersBegan[process.pid] = began
        let stalledFor = now - began

        // 1. Anything of ours holding it. A modal dialog under the game is an
        //    answer rather than a stall: it is waiting for a person.
        if let dialog = modalDialog() {
            note(appID: appID, for: stalledFor, unwedged: "dialog: \(dialog)")
            probes.log("stall: \(process.name) is behind \(dialog) — not a stall")
            laddersBegan[process.pid] = nil
            return
        }

        // 2. A stopped process in the tree reads as a stall; wake the tree.
        let tree = tree(under: [process.pid])
        if tree.contains(where: probes.isStopped) {
            for pid in tree { probes.signal(pid, SIGCONT) }
            note(appID: appID, for: stalledFor, unwedged: "sigcont")
            probes.log("stall: continued \(tree.count) stopped processes under \(process.name)")
            return
        }

        // 3. Still nothing, and long enough. Killing on CPU alone is a guess,
        //    so it waits for the present counter to say the game drew nothing.
        guard stalledFor >= Rules.killAfter else { return }
        guard Self.killsOnCPUAlone || process.presents != nil else {
            // Said once per process: a crash handler sits still for a whole
            // session, and a line every ladder buries the log it is written to.
            if leftAlone.insert(process.pid).inserted {
                note(appID: appID, for: stalledFor, unwedged: nil)
                probes.log(
                    "stall: \(process.name) has been still for \(Int(stalledFor)) s; "
                        + "nothing counts its frames, so it is left alone",
                )
            }
            laddersBegan[process.pid] = nil
            return
        }
        for pid in tree { probes.signal(pid, SIGKILL) }
        note(appID: appID, for: stalledFor, unwedged: "sigkill")
        probes.log("stall: killed \(tree.count) processes under \(process.name)")
        laddersBegan[process.pid] = nil
        if let appID { recorder?.close(appID: appID, kind: .watchdog) }
    }

    /// The app id of a run whose own process is somewhere above this pid — a
    /// game's child is the run's stall as much as the game's own process is.
    private func appIDOfTree(containing pid: pid_t) -> Int? {
        for (appID, root) in runningPIDs where tree(under: [root]).contains(pid) { return appID }
        return nil
    }

    /// A Wine dialog on screen, which is a game waiting for an answer rather
    /// than one that has stopped.
    ///
    /// Read from the previous pass's scan: `CGWindowListCopyWindowInfo` is a
    /// round trip to the window server, and on the busy host where a stall
    /// happens that round trip is a stall of its own.
    private func modalDialog() -> String? {
        dialogs.first.map { "\($0.owner)'s dialog \($0.title.map { "“\($0)”" } ?? "")" }
    }

    private var dialogs: [WineWindowWatch.Window] = []

    /// Refreshes what the window server says, for the next pass to read.
    private func refreshDialogs() {
        Task(name: "Scan for Wine dialogs") { [weak self] in
            let scan = await WineWindowWatch.scan()
            self?.dialogs = scan.wineWindows
        }
    }

    /// Writes one rung into the run record, where the whole ladder is read
    /// back afterwards.
    private func note(appID: Int?, for duration: TimeInterval, unwedged: String?) {
        guard let appID, let recorder else { return }
        recorder.noteStall(
            lasting: (duration * 10).rounded() / 10, unwedged: unwedged, forApp: appID,
        )
    }
}
