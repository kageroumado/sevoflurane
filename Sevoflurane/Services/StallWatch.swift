import Foundation
import Observation

/// Watches every process this app owns, names what each of them is doing, and
/// unwedges a game that has stopped doing anything.
///
/// The signal is a process's CPU time (`proc_pid_rusage` every
/// ``Rules/sampleEvery``) and the driver's present counter. A game process
/// with no CPU and no new frame for ``Rules/candidateAfter`` is still, which
/// is two different things: a game waiting for its player, and a game that
/// has hung. Its window tells them apart (``WindowProbe``): one that answers
/// is at rest and is left alone for as long as it likes. One that does not
/// answer, in a tree where nothing else moves either, is ended after
/// ``Rules/killAfter``. Before that the ladder names a dialog it is waiting
/// behind and continues a stopped tree. Client processes are the
/// supervisor's. The process monitor shows these samples.
@MainActor
@Observable
final class StallWatch {
    /// Thresholds.
    nonisolated enum Rules {
        /// How often every process we own is read.
        static let sampleEvery: Duration = .seconds(2)
        /// No CPU for this long makes a process a stall candidate.
        static let candidateAfter: TimeInterval = 15
        /// How long a still game's window may go unanswered before the game
        /// is ended. A minute covers a connection that times out on the
        /// window's own thread.
        static let killAfter: TimeInterval = 60
        /// How often the windows are asked again while a still game's has
        /// not answered.
        static let askWindowsEvery: TimeInterval = 15
        /// How often a game at rest is asked again. Rarely: each asking
        /// starts a program in the bottle.
        static let askRestingEvery: TimeInterval = 300
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
        /// As still as a stalled one, with a window that answers or none to
        /// ask: a game waiting for its player.
        case atRest = "at rest"
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
        /// Frames the process has put on screen; one that draws is moving
        /// even at no measurable CPU.
        var presents: @Sendable (pid_t) -> UInt64? = { pid in
            PresentStats.presents(of: pid) ?? PresentStats.presents(
                of: pid, in: SteamBottle.companion.appendingPathComponent(".sevo/run"),
            )
        }
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
        /// Which programs' windows answer, by lowercased executable name; nil
        /// when they could not be asked.
        var windows: @Sendable () async -> [String: WindowProbe.Verdict]? = { await WindowProbe.ask() }
    }

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
        // A ladder measures one stillness, so a process that moved or left restarts its own.
        let still = found.filter { isStill($0, at: now) }
        let stillPIDs = Set(still.map(\.pid))
        laddersBegan = laddersBegan.filter { stillPIDs.contains($0.key) }
        restingSince = restingSince.filter { stillPIDs.contains($0.key) }
        deafSince = deafSince.filter { stillPIDs.contains($0.key) }
        reportedDialogs = reportedDialogs.filter { stillPIDs.contains($0.key) }
        wantsWindowAnswers = false
        for process in still {
            climb(for: process, at: now)
        }
        if !still.isEmpty { refreshDialogs() }
        if wantsWindowAnswers { askWindows(at: now) }
    }

    /// Whether a process has gone ``Rules/candidateAfter`` without CPU or a
    /// frame. One whose main thread is also silent counts: it is the most
    /// still of all.
    private func isStill(_ process: Process, at now: TimeInterval) -> Bool {
        switch process.state {
        case .stalled, .atRest: true
        case .notAnswering: tracked[process.pid].map { now - $0.lastMoved >= Rules.candidateAfter } ?? false
        case .running, .idle, .stopped: false
        }
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
        guard still >= Rules.candidateAfter else { return .idle }
        return restingSince[pid] == nil ? .stalled : .atRest
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

    /// When each still process's ladder began: an answer from before it says
    /// nothing about this stillness.
    private var laddersBegan: [pid_t: TimeInterval] = [:]
    /// When each still process was last found at rest, with a window that
    /// answers or none to ask: it is left alone until asked again.
    private var restingSince: [pid_t: TimeInterval] = [:]
    /// Since when each still process's window has gone unanswered.
    private var deafSince: [pid_t: TimeInterval] = [:]
    /// What the windows said at the last asking, and when it was put.
    private var windowAnswers: (askedAt: TimeInterval, verdicts: [String: WindowProbe.Verdict])?
    private var isAskingWindows = false
    /// Set during a pass by a process that needs a newer answer.
    private var wantsWindowAnswers = false
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

        // 3. Ask its window. A game that answers is waiting for its player.
        let rested = restingSince[process.pid]
        if let rested, now - rested < Rules.askRestingEvery { return }
        // An answer counts when it was asked for during this stillness, and
        // after the last one this process was settled by.
        guard let asked = windowAnswers, asked.askedAt >= began, rested.map({ asked.askedAt > $0 }) ?? true else {
            wantsWindowAnswers = true
            return
        }
        switch asked.verdicts[process.name.lowercased()] {
        case .answers:
            if restingSince[process.pid] == nil {
                probes.log("stall: \(process.name) is at rest — no processor time and no frames, and its window answers")
            }
            restingSince[process.pid] = asked.askedAt
            deafSince[process.pid] = nil
        case nil:
            // No window on screen: a crash handler sits like this all session.
            if restingSince[process.pid] == nil {
                probes.log("stall: \(process.name) is still and has no window to ask, so it is left alone")
            }
            restingSince[process.pid] = asked.askedAt
            deafSince[process.pid] = nil
        case .deaf:
            let since = deafSince[process.pid] ?? asked.askedAt
            if deafSince[process.pid] == nil {
                deafSince[process.pid] = since
                probes.log(
                    "stall: \(process.name) is still and its window does not answer — ended in "
                        + "\(Int(Rules.killAfter)) s unless something in the game moves",
                )
            }
            restingSince[process.pid] = nil
            // 4. End it once the window has stayed unanswered and nothing in the game has moved.
            guard asked.askedAt - since >= Rules.killAfter, everythingIsStill(around: process, appID: appID, at: now) else {
                wantsWindowAnswers = true
                return
            }
            for pid in tree { probes.signal(pid, SIGKILL) }
            note(appID: appID, for: stalledFor, unwedged: "sigkill")
            probes.log(
                "stall: ended \(process.name) and \(tree.count - 1) under it — still for \(Int(stalledFor)) s "
                    + "with a window that never answered",
            )
            laddersBegan[process.pid] = nil
            deafSince[process.pid] = nil
            if let appID { recorder?.close(appID: appID, kind: .watchdog) }
        }
    }

    /// Whether every process of the game is still: the one judged, its
    /// children, and the run's whole tree. A launcher waiting on a busy game,
    /// or a game waiting on its installer, is at work.
    private func everythingIsStill(around process: Process, appID: Int?, at now: TimeInterval) -> Bool {
        var members = Set(tree(under: [process.pid]))
        if let appID, let root = runningPIDs[appID] { members.formUnion(tree(under: [root])) }
        return processes.filter { members.contains($0.pid) }.allSatisfy { isStill($0, at: now) }
    }

    /// Asks the windows again, one asking at a time and no more often than
    /// ``Rules/askWindowsEvery``.
    private func askWindows(at now: TimeInterval) {
        guard !isAskingWindows else { return }
        if let last = windowAnswers, now - last.askedAt < Rules.askWindowsEvery { return }
        isAskingWindows = true
        let ask = probes.windows
        let clock = probes.now
        Task(name: "Ask the game windows") { [weak self] in
            let askedAt = clock()
            let verdicts = await ask()
            guard let self else { return }
            isAskingWindows = false
            // An asking that could not be put says nothing; the next pass asks again.
            windowAnswers = verdicts.map { (askedAt, $0) }
        }
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
