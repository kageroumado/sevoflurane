import Foundation
import Observation

/// Watches every process this app owns, names what each of them is doing, and
/// unwedges a game that has stopped doing anything.
///
/// The signal is a process's CPU time (`proc_pid_rusage` every
/// ``Rules/sampleEvery``) and the driver's present counter where it exists. A
/// process with no CPU and no presents for ``Rules/candidateAfter`` is a
/// stall candidate. Each rung of the ladder is written into the run record:
/// release what is ours, `SIGCONT` the tree, wait, then kill. Client
/// processes are the supervisor's. The process monitor shows these samples.
@MainActor
@Observable
final class StallWatch {
    /// Thresholds.
    nonisolated enum Rules {
        /// How often every process we own is read.
        static let sampleEvery: Duration = .seconds(2)
        /// No CPU for this long makes a process a stall candidate.
        static let candidateAfter: TimeInterval = 15
        /// How long a game gets after the release rungs before it is killed.
        static let killAfter: TimeInterval = 15
        /// Below this share of one core a process counts as idle: a spin-wait
        /// at a few micros a second is not progress.
        static let idleCPUShare = 0.005
        /// One thread that never yields reads as one whole core, sample after
        /// sample; a game at work moves above and below it.
        static let oneCoreBand = 0.93 ... 1.07
        /// How long inside ``oneCoreBand`` before the monitor says so.
        static let oneCoreAfter: TimeInterval = 60
        /// The engine beats once a second from the game's Cocoa main thread;
        /// this long without one, the window answers nothing.
        static let notAnsweringAfter: TimeInterval = 10
        /// How long a run whose process is gone waits for the client's stop
        /// edge before the watch ends Steam's entry itself. Until a forgotten
        /// entry clears, every later launch of the game is a silent no-op.
        static let clientStopGrace: TimeInterval = 15
    }

    /// What a process is to us.
    nonisolated enum Role: String, Sendable, CaseIterable {
        /// Steam itself and its web helper.
        case client
        /// The bottle's own plumbing: services, the device host, explorer.
        case helper
        case game
        /// Something a game started.
        case gameChild
        /// The engine's macOS-side processes: the Wine server, the relay.
        case driver
    }

    /// How a process reads right now.
    nonisolated enum State: String, Sendable {
        case running
        /// No CPU since the last sample, but not yet for ``Rules/candidateAfter``.
        case idle
        /// `SIGSTOP`ped, by us, a debugger or a terminal.
        case stopped
        /// No CPU and no present for ``Rules/candidateAfter``.
        case stalled
        /// The window's main thread has stopped while the process runs on.
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
        /// Frames the driver has presented, when the process has a counter.
        let presents: UInt64?
        let state: State
        /// The app id of the run this process belongs to.
        let appID: Int?
        /// The process has held exactly one core for ``Rules/oneCoreAfter``: a busy loop.
        var holdsOneCore = false
    }

    /// Called once for each process whose window stops answering, so the app
    /// can ask the user; a debugger or a sleeping Mac stops a main thread too.
    @ObservationIgnored var onNotAnswering: ((Process) -> Void)?
    @ObservationIgnored private var reportedNotAnswering: Set<pid_t> = []

    /// Called once for each run whose process has been gone for
    /// ``Rules/clientStopGrace`` with no stop edge, so the app can end
    /// Steam's stale entry.
    @ObservationIgnored var onGameProcessGone: ((Int) -> Void)?
    /// When each open run's process was first found gone, by app id.
    @ObservationIgnored private var goneSince: [Int: TimeInterval] = [:]

    /// Kills the tree under a game the user gave up on and closes its run as
    /// a watchdog ending.
    func end(_ process: Process) {
        for pid in tree(under: [process.pid]) { probes.signal(pid, SIGKILL) }
        probes.log("stall: ended \(process.name) (pid \(process.pid)) at the user's word")
        if let appID = process.appID { recorder?.close(appID: appID, kind: .watchdog) }
    }

    /// Everything we own, most CPU first.
    private(set) var processes: [Process] = []

    /// The seams every reading comes through, for tests.
    nonisolated struct Probes: Sendable {
        var usage: @Sendable (pid_t) -> ProcessUsage? = { ProcessUsage.read(pid: $0) }
        var isStopped: @Sendable (pid_t) -> Bool = { ProcessUsage.isStopped(pid: $0) }
        var children: @Sendable (pid_t) -> [pid_t] = { ProcessUsage.children(of: $0) }
        var name: @Sendable (pid_t) -> String? = { ProcessUsage.name(of: $0) }
        /// A present count, which the kill rung needs before it may kill. The
        /// app answers `nil`: a still picture presents nothing and is not a
        /// stall (``killsOnCPUAlone``).
        var presents: @Sendable (pid_t) -> UInt64? = { _ in nil }
        var mainThreadSilence: @Sendable (pid_t) -> TimeInterval? = { pid in
            // A HoYoverse game's page is written in the companion prefix.
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
        /// The client's Wine windows on screen, which the dialog rung reads.
        var dialogs: @Sendable () async -> [WineWindowWatch.Window] = { await WineWindowWatch.scan().wineWindows }
    }

    /// Whether a game may be killed when nothing says whether it presented.
    /// False: a download wait, a cut scene decoded elsewhere or a dialog all
    /// read as zero CPU, so the kill is left to the user.
    static let killsOnCPUAlone = false

    private let probes: Probes
    private let chronicleURL: URL
    private var tracked: [pid_t: Tracked] = [:]
    private var exeByPID: [pid_t: String] = [:]
    private var chronicle: WineChronicleTail?
    private var loop: Task<Void, Never>?

    /// Where stalls are recorded and runs closed.
    var recorder: RunRecorder?

    /// - Parameter chronicleURL: The dock shim's chronicle, where Unix pids
    ///   meet Windows executables.
    init(probes: Probes = Probes(), chronicleURL: URL = WineChronicle.url) {
        self.probes = probes
        self.chronicleURL = chronicleURL
        chronicle = WineChronicleTail(url: chronicleURL)
    }

    // MARK: - The loop

    /// Starts sampling; a second call replaces the first loop.
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

    /// One pass: reads and judges every process we own, and climbs the ladder for stalls.
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
        // The kill rung measures one stall, so a process that moved or left restarts its ladder.
        let stalled = Set(found.filter { $0.state == .stalled }.map(\.pid))
        laddersBegan = laddersBegan.filter { stalled.contains($0.key) }
        leftAlone.formIntersection(stalled)
        reportedDialogs = reportedDialogs.filter { stalled.contains($0.key) }
        for process in found where process.state == .stalled {
            climb(for: process, at: now)
        }
        if found.contains(where: { $0.state == .stalled }) { refreshDialogs() }
    }

    /// Ends a run whose process has been gone for ``Rules/clientStopGrace``
    /// without a stop edge, or moves it to a live sibling. The run closes as
    /// the user's ending, since no exit status exists.
    private func closeRunsWhoseProcessIsGone(at now: TimeInterval) {
        let running = runningPIDs
        goneSince = goneSince.filter { running[$0.key] != nil }
        for (appID, pid) in running {
            guard probes.usage(pid) == nil else {
                goneSince[appID] = nil
                continue
            }
            if let sibling = liveSibling(of: pid, followedBy: Set(running.values)) {
                probes.log("run \(appID): its process (pid \(pid)) is gone and pid \(sibling) of the same program "
                    + "is running — following that one")
                recorder?.follow(pid: sibling, forApp: appID)
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

    /// The oldest live process running the same executable as `pid` and
    /// followed by no other run: a Chromium game's processes all run its exe.
    private func liveSibling(of pid: pid_t, followedBy followed: Set<pid_t>) -> pid_t? {
        guard let exe = exeByPID[pid] else { return nil }
        return exeByPID
            .filter { $0.value == exe && !followed.contains($0.key) && probes.usage($0.key) != nil }
            .keys.min()
    }

    /// The live pids the chronicle named, plus each open run's pid.
    private func liveRoots() -> [pid_t] {
        let alive = exeByPID.keys.filter { probes.usage($0) != nil }
        exeByPID = exeByPID.filter { alive.contains($0.key) }
        return Array(Set(alive + Array(runningPIDs.values)))
    }

    private var runningPIDs: [Int: pid_t] {
        recorder?.runningPIDs ?? [:]
    }

    /// Every process under the roots, breadth first.
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

    /// The chronicle is the only place Unix pids meet Windows executable names.
    private func readChronicle() {
        for entry in chronicle?.newEntries() ?? [] where entry.verb == .armed {
            exeByPID[entry.pid] = entry.executable.lowercased()
        }
    }

    // MARK: - Judging one process

    private nonisolated struct Tracked {
        var cpuNanoseconds: UInt64
        var presents: UInt64?
        var lastMoved: TimeInterval
        var lastRead: TimeInterval
        /// Since when every sample has been inside ``Rules/oneCoreBand``.
        var oneCoreSince: TimeInterval?
    }

    /// Since when a process has held one core, given the newest sample's share.
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
        // Asked: a stopped process looks stalled from the CPU counter alone.
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

    /// The client's own processes, which the supervisor restarts.
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
            // At rest is normal here (Steam's web helper children idle for
            // minutes); the supervisor judges the client.
            break
        }
    }

    /// When each stalled process's ladder began, so the kill rung waits its
    /// own ``Rules/killAfter``.
    private var laddersBegan: [pid_t: TimeInterval] = [:]
    /// Processes already reported as still and left alone.
    private var leftAlone: Set<pid_t> = []
    /// The dialog each stalled process was last reported behind: a dialog
    /// that stays up is written into the run once, not on every sample.
    private var reportedDialogs: [pid_t: String] = [:]

    private func unwedge(_ process: Process, at now: TimeInterval) {
        let appID = process.appID ?? appIDOfTree(containing: process.pid)
        let began = laddersBegan[process.pid] ?? now
        laddersBegan[process.pid] = began
        let stalledFor = now - began

        // 1. A modal dialog means it waits for a person.
        if let dialog = modalDialog() {
            if reportedDialogs[process.pid] != dialog {
                reportedDialogs[process.pid] = dialog
                note(appID: appID, for: stalledFor, unwedged: "dialog: \(dialog)")
                probes.log("stall: \(process.name) is behind \(dialog) — not a stall")
            }
            laddersBegan[process.pid] = nil
            return
        }
        reportedDialogs[process.pid] = nil

        // 2. Wake a tree with a stopped process in it.
        let tree = tree(under: [process.pid])
        if tree.contains(where: probes.isStopped) {
            for pid in tree { probes.signal(pid, SIGCONT) }
            note(appID: appID, for: stalledFor, unwedged: "sigcont")
            probes.log("stall: continued \(tree.count) stopped processes under \(process.name)")
            return
        }

        // 3. Kill only when the present counter says the game drew nothing.
        guard stalledFor >= Rules.killAfter else { return }
        guard Self.killsOnCPUAlone || process.presents != nil else {
            // Once per process: a crash handler sits still all session.
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

    /// The app id of the run whose process is an ancestor of this pid.
    private func appIDOfTree(containing pid: pid_t) -> Int? {
        for (appID, root) in runningPIDs where tree(under: [root]).contains(pid) { return appID }
        return nil
    }

    /// A Wine dialog on screen, from the previous pass's scan:
    /// `CGWindowListCopyWindowInfo` is a window-server round trip that stalls
    /// on a busy host.
    private func modalDialog() -> String? {
        dialogs.first.map { "\($0.owner)'s dialog \($0.title.map { "“\($0)”" } ?? "")" }
    }

    private var dialogs: [WineWindowWatch.Window] = []

    private func refreshDialogs() {
        let scan = probes.dialogs
        Task(name: "Scan for Wine dialogs") { [weak self] in
            let found = await scan()
            self?.dialogs = found
        }
    }

    /// Writes one rung into the run record.
    private func note(appID: Int?, for duration: TimeInterval, unwedged: String?) {
        guard let appID, let recorder else { return }
        recorder.noteStall(
            lasting: (duration * 10).rounded() / 10, unwedged: unwedged, forApp: appID,
        )
    }
}
