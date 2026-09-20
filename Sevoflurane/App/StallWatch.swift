import Foundation
import Observation

/// Watches every process this app owns, names what each of them is doing, and
/// unwedges a game that has stopped doing anything (`Docs/diagnostics-plan.md`).
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
        /// The driver's present counter for a process, once it lands. Nothing
        /// answers today, which is why the watchdog will not kill on CPU
        /// alone — see ``killsOnCPUAlone``.
        var presents: @Sendable (pid_t) -> UInt64? = { _ in nil }
        var signal: @Sendable (pid_t, Int32) -> Void = { kill($0, $1) }
        /// Seconds on a monotonic clock.
        var now: @Sendable () -> TimeInterval = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        }
        var log: @Sendable (String) -> Void = { EventLog.enqueue(.app, $0) }

        init() {}
    }

    /// Whether a game may be killed when nothing can say whether it presented.
    ///
    /// False, and it stays false until the driver's present counter lands: a
    /// game waiting on a download, a cut scene decoded on another thread, or a
    /// dialog behind its own window all read as zero CPU, and killing one of
    /// those loses a session to a guess. Until then the watchdog names the
    /// stall, runs the rungs that cost nothing, and stops.
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
        for process in found where process.state == .stalled {
            climb(for: process, at: now)
        }
        if found.contains(where: { $0.state == .stalled }) { refreshDialogs() }
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
        tracked[pid] = Tracked(
            cpuNanoseconds: usage.cpuTimeNanoseconds, presents: presents,
            lastMoved: lastMoved, lastRead: now,
        )
        let name = exeByPID[pid] ?? probes.name(pid) ?? "pid \(pid)"
        return Process(
            pid: pid,
            name: name,
            role: role(of: name, pid: pid),
            cpuSeconds: usage.cpuSeconds,
            cpuShare: (share * 1000).rounded() / 1000,
            footprintBytes: usage.footprintBytes,
            presents: presents,
            state: state(pid: pid, moved: moved, still: now - lastMoved),
            appID: appID(of: pid),
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
            note(appID: appID, for: stalledFor, unwedged: nil)
            probes.log(
                "stall: \(process.name) has been still for \(Int(stalledFor)) s; "
                    + "nothing counts its frames, so it is left alone",
            )
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
