import Foundation

/// A launch in progress and the machine's state when it started. `Sendable` so closing one, which
/// reads two logs, can leave the caller's actor.
nonisolated struct RunInProgress: Sendable {
    let started: ContinuousClock.Instant
    var record: RunRecord
    /// The macOS pid of the launch's executable, from the dock shim's chronicle; the meters read
    /// it. Never put it in the armed file: after a restart the number may be another process's.
    var gamePID: pid_t?
    /// Where the two logs ended when the run began.
    let wineLogOffset: UInt64
    let steamLogOffset: UInt64
    /// The client showed an error for this game action.
    var steamError: String?
    /// The engine's `sevo:run` and `sevo:gfx` renderer lines, gathered while the run is up: a long
    /// run's Wine log outgrows the tail read at its close.
    var provenance = ""
    /// Where ``provenance`` has read the Wine log to; nil until the first read.
    var provenanceOffset: UInt64?
    /// Busy-thread counts (``ThreadActivity``) at each sample taken while the game had focus.
    var busyThreadSamples: [Int] = []
    /// The processors the game was told of: the Mac's, or the game's cap.
    var processors = ProcessInfo.processInfo.activeProcessorCount
    /// Where the record goes and the two logs its ending is read from.
    var runsRoot = RunLog.root
    var wineLog = WineLog.fileURL
    var processLog = RunRecorder.steamProcessLogURL

    /// Reads what the two logs gained during the run, decides how it ended, and appends the record.
    ///
    /// - Parameters:
    ///   - kind: The ending the caller knows for a fact, such as the stall watchdog's kill.
    ///   - unrecorded: The ending to record when Steam wrote none; a quit takes Steam down
    ///     before it can record the exit it caused.
    ///   - programExitGrace: How long to wait for an adopted program's exit line
    ///     (``ProgramExit``), which its launcher writes a moment after the program's process is gone.
    func write(
        lasting seconds: Double?,
        kind: RunRecord.Exit.Kind?,
        unrecorded: RunRecord.Exit.Kind = .unknown,
        programExitGrace: Duration = .zero,
    ) {
        var record = record
        record.durationSeconds = seconds
        record.threads = RunRecord.Threads(samples: busyThreadSamples, processors: processors)
        if let trace = record.fps?.trace,
           let contents = FrameTrace.read(FrameTrace.directory(in: runsRoot).appendingPathComponent(trace)) {
            record.fps?.gameplay = GameplayWindow.gameplay(of: contents)
        }
        let steamTail = RunRecorder.text(of: processLog, from: steamLogOffset)
        record.runtime = SteamGameProcessLog.runtime(
            forApp: record.appid, in: steamTail, exe: record.exe,
        )
        let exit = SteamGameProcessLog.exit(
            forApp: record.appid, running: record.exe, in: steamTail,
        )
        var wineTail = RunRecorder.text(of: wineLog, from: wineLogOffset)
        var programStatus = ProgramExit.status(forApp: record.appid, in: wineTail)
        if kind == nil, exit == nil, programStatus == nil, programExitGrace > .zero {
            let deadline = ContinuousClock.now + programExitGrace
            while programStatus == nil, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: Self.programExitPoll)
                wineTail = RunRecorder.text(of: wineLog, from: wineLogOffset)
                programStatus = ProgramExit.status(forApp: record.appid, in: wineTail)
            }
        }
        let code = exit?.code ?? programStatus
        let lines = provenance.isEmpty ? wineTail : provenance + "\n" + wineTail
        // A macOS build: the wine log holds only the bridge helper's lines.
        if record.runner != GameRunner.macos {
            if let answered = WineProvenance.renderer(forApp: record.appid, exe: record.exe, in: lines) {
                record.renderer = answered
                record.rendererConfirmed = true
            } else if record.runner != GameRunner.nwjs, record.rendererConfirmed != true {
                record.rendererConfirmed = false
            }
        }
        let ending = WineExceptionTrail.ending(
            in: wineTail,
            forProcesses: WineProvenance.processes(forApp: record.appid, in: lines),
            winePIDs: WineProvenance.winePIDs(forApp: record.appid, in: lines),
        )
        let notes = WineExceptionTrail.notes(in: wineTail)
        record.notes = notes.isEmpty ? nil : notes
        if record.video == nil { record.video = VideoStarvation.video(forApp: record.appid, in: lines) }
        let endedNotResponding = wineTail.contains("ended by the user while not responding")
        let ended = kind ?? Self.kind(
            code: code, ending: ending, endedNotResponding: endedNotResponding,
            stopRequest: RunLog.takeStopRequest(forApp: record.appid, in: runsRoot),
            steamError: steamError, unrecorded: unrecorded,
        )
        record.crash = ending.crash ?? Self.statusCrash(code: code, ended: ended)
        record.exit = RunRecord.Exit(kind: ended, code: code)
        RunLog.append(record, in: runsRoot)
        RunRecorder.log("run recorded — \(record.summary)")
        RunRecorder.didClose(record)
        RunRecorder.didRecord?(record, wineTail)
    }

    private static let programExitPoll: TimeInterval = 0.25

    /// How a run ended. A stop on record outranks the exit status: the stop ends the process whole,
    /// which reads as 0, and Steam's own `TerminateProcess` reads as 1.
    static func kind(
        code: Int?, ending: WineExceptionTrail.Ending, endedNotResponding: Bool, stopRequest: RunLog.StopSource?,
        steamError: String?, unrecorded: RunRecord.Exit.Kind,
    ) -> RunRecord.Exit.Kind {
        if ending.crash != nil { return ending.afterWindowsClosed ? .crashAtExit : .crash }
        if endedNotResponding { return .endedNotResponding }
        if let code {
            if let stopRequest { return stoppedKind(stopRequest) }
            if code == 0 { return .user }
            if exceptionStatus(code) != nil { return ending.windowsClosedAtEnd ? .crashAtExit : .crash }
            return .exitError
        }
        return steamError == nil ? unrecorded : .steamTerminate
    }

    /// The exception a run's exit status names, for a crash no log line described.
    private static func statusCrash(code: Int?, ended: RunRecord.Exit.Kind) -> RunRecord.Crash? {
        guard ended == .crash || ended == .crashAtExit, let status = code.flatMap(exceptionStatus) else { return nil }
        return RunRecord.Crash(code: status)
    }

    /// The NT status an error-severity exit code (`0xC…`, negative as Steam prints it) names:
    /// Windows hands the ending exception's status on as the exit code, so `-1073741819` is
    /// `0xc0000005`. `STATUS_CONTROL_C_EXIT` (a console closing) and `-1` (a program's own
    /// `exit(-1)`) answer nil.
    static func exceptionStatus(_ code: Int) -> String? {
        guard (Int(Int32.min) ... Int(UInt32.max)).contains(code) else { return nil }
        let bits = UInt32(truncatingIfNeeded: code)
        guard bits >= 0xC000_0000, bits != controlCExit, bits != exitMinusOne else { return nil }
        return String(format: "0x%08x", bits)
    }

    private static let controlCExit: UInt32 = 0xC000_013A
    private static let exitMinusOne: UInt32 = 0xFFFF_FFFF

    static func stoppedKind(_ source: RunLog.StopSource) -> RunRecord.Exit.Kind {
        switch source {
        case .player: .stopped
        case .tool: .stoppedByTool
        }
    }

    /// The armed form of this run, for the file that outlives the process.
    var armed: RunLog.ArmedRun {
        RunLog.ArmedRun(
            record: record,
            started: Date(timeIntervalSinceNow: -RunRecorder.seconds(since: started)),
            wineLogOffset: wineLogOffset,
            steamLogOffset: steamLogOffset,
            steamError: steamError,
            steamLog: processLog.path,
        )
    }
}

/// What the app saw of a game's window at one look.
nonisolated struct GameObservation: Equatable, Sendable {
    var focus: FrameTrace.Focus
    /// The display under the game's window; nil while none is on screen.
    var display: RunRecord.Display?
}

/// A record's moment: UTC, seconds, so records from two machines sort together.
/// `ISO8601DateFormatter` is not `Sendable`, so sharing it between the app and `sevo` would need an
/// unchecked global.
nonisolated let runRecordStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}()

/// Opens a record when the client says a launch began, and closes it when the client says the app
/// stopped running; runs are keyed by app id, since Steam can have two games up.
///
/// Armed at `GameActionStart`, because a failed launch often never opens a window (three of five in
/// one playtest). Closed from `GameSessions.RegisterForAppLifetimeNotifications`, because a game
/// Steam started is not a process this app can wait on; the exit status exists only in Steam's
/// `gameprocess_log.txt`.
final nonisolated class RunRecorder {
    /// Where the recorder narrates.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = { _ in }

    /// A record has been written with its ending; called on the closing queue.
    nonisolated(unsafe) static var didClose: @Sendable (RunRecord) -> Void = { _ in }

    /// A game's own settings as a run is armed; replaceable for tests.
    nonisolated(unsafe) static var gameValues: @Sendable (Int) -> ConfigValues = { GameConfig.game($0) }

    /// An open run's video decoder produced nothing (``RunRecord/video``); called on whatever
    /// thread read the log, so the app can offer the other decoder while the game waits.
    nonisolated(unsafe) static var didStarveVideo: (@Sendable (RunRecord) -> Void)?

    /// A record is on disk, with what the Wine log gained while it ran; called on the closing
    /// queue. The app collects reports from it (``CrashCollector``).
    nonisolated(unsafe) static var didRecord: (@Sendable (RunRecord, String) -> Void)?

    /// A run has just closed, called with its app id before the record is written. Every ending
    /// passes here, an adopted program's included.
    var onClose: ((Int) -> Void)?

    private var open: [Int: OpenRun] = [:]
    private var hasGroomed = false
    private let runs: URL
    private let wineLog: URL
    /// A fixed Steam process log, for tests. Nil in the app, where each `arm` resolves the booted
    /// engine's bottle log.
    private let processLogOverride: URL?
    /// The driver's present counters, sampled while a run is open; they fill ``RunRecord/fps``.
    let presentStats: PresentStats
    /// How long a closing program run waits for its exit line (``ProgramExit``); three seconds
    /// covers the launcher's teardown.
    private let programExitGrace: Duration

    typealias OpenRun = RunInProgress

    init(
        runs: URL = RunLog.root,
        wineLog: URL = WineLog.fileURL,
        processLog: URL? = nil,
        presentStats: PresentStats = PresentStats(),
        programExitGrace: Duration = .seconds(3),
    ) {
        self.runs = runs
        self.wineLog = wineLog
        self.processLogOverride = processLog
        self.presentStats = presentStats
        self.programExitGrace = programExitGrace
    }

    /// Apps whose open run the client has confirmed running.
    private var confirmedRunning: Set<Int> = []
    /// When a launch took over from a still-open run of the same app (a launcher starting its
    /// game). The stop edge within ``handoverWindow`` is the launcher's.
    private var handovers: [Int: ContinuousClock.Instant] = [:]
    private static let handoverWindow: Duration = .seconds(5)

    /// A program was pressed: its run's Wine trail starts at the log's end now, since the process
    /// can write before the reply is handled.
    func noteLaunchPressed(appID: Int) {
        pressedOffsets[appID] = (Self.size(of: wineLog), .now)
    }

    private func takePressedOffset(_ appID: Int) -> UInt64? {
        defer { pressedOffsets[appID] = nil }
        guard let pressed = pressedOffsets[appID], .now - pressed.at < Self.pressedOffsetLife else { return nil }
        return pressed.offset
    }

    private var pressedOffsets: [Int: (offset: UInt64, at: ContinuousClock.Instant)] = [:]
    private static let pressedOffsetLife: Duration = .seconds(300)

    /// A launch of `appID` has begun. Re-arming an open app closes the old run as unknown.
    func arm(appID: Int) {
        guard appID != 0 else { return }
        if open[appID] != nil {
            close(appID: appID, kind: .unknown)
            handovers[appID] = .now
        }
        confirmedRunning.remove(appID)
        let values = Self.gameValues(appID)
        let booted = BottleGraphics.bootedSelection()
        let selection = booted.map {
            (renderer: $0.renderer, msync: $0.msync, d3dMetalVersion: $0.d3dMetalVersion)
        } ?? {
            let current = BottleGraphics.currentSelection()
            return (current.renderer, current.msync, current.d3dMetalVersion)
        }()
        // The engine the client booted from, which ran the game. Never Engine.active: it may name
        // the next restart's staged selection. Steam writes this run's exit in that engine's
        // bottle.
        let bootedEngine = BottleGraphics.bootedEngineRoot().flatMap(Engine.booted(fromRoot:))
        let steamLog = processLogOverride
            ?? bootedEngine.map(Self.steamProcessLogURL(forEngine:))
            ?? Self.steamProcessLogURL
        let now = Date.now
        let native = Engine.running.supportsSteamPlayMacOS && SteamPlayMacOS.mappedApps().contains(appID)
        var record = RunRecord(
            t: runRecordStamp.string(from: now),
            appid: appID,
            name: values.name,
            engine: (bootedEngine ?? Engine.active).recordIdentifier,
            renderer: native ? GameRunner.macos
                : values.runner == GameRunner.nwjs ? GameRunner.nwjs : selection.renderer.rawValue,
            rendererRequested: native || values.runner == GameRunner.nwjs
                ? nil : (values.renderer ?? selection.renderer).rawValue,
            runner: native ? GameRunner.macos : values.runner ?? GameRunner.wine,
            windows: GameConfig.windows(bottle: SteamBottle.name, game: appID).value.rawValue,
            tuning: Self.tuningLabel(forApp: appID),
            upscaler: native ? nil : GameConfig.upscaler(bottle: SteamBottle.name, game: appID).value,
            msync: selection.msync,
            d3dmetal: selection.d3dMetalVersion,
            macos: Self.macOSVersion,
            chip: Self.chip,
            mac: MacHardware.model,
            gpuCores: MacHardware.gpuCores,
            memoryGB: MacHardware.memoryGB,
            host: Self.hostState(),
        )
        if native {
            record.d3dmetal = nil
            record.rendererConfirmed = true
        }
        open[appID] = OpenRun(
            started: .now,
            record: record,
            wineLogOffset: takePressedOffset(appID) ?? Self.size(of: wineLog),
            steamLogOffset: Self.size(of: steamLog),
            processors: Self.processorsSeen(forApp: appID),
            runsRoot: runs,
            wineLog: wineLog,
            processLog: steamLog,
        )
        persist(appID: appID)
        presentStats.arm(appID: appID, trace: FrameTrace.Writer(
            url: FrameTrace.url(appID: appID, stamp: record.t, in: runs), appID: appID, stamp: record.t,
        ))
        if !hasGroomed {
            hasGroomed = true
            Task.detached(name: "Groom the run records") { [runs] in
                RunLog.groom(in: runs)
                FrameTrace.groom(in: runs)
            }
        }
    }

    /// One of the launch's processes reached the Mac driver, named by the dock shim's chronicle.
    /// The executable's file gives the image's bitness; the run follows the named process, so a
    /// launcher armed first hands over its name and pid.
    func noteExecutable(
        _ exe: String, pid: pid_t? = nil, forApp appID: Int, at url: URL? = nil,
    ) {
        // A process arriving after the game has drawn (Genshin's frame-rate unlocker, a companion
        // window) is a helper; the game keeps its pid.
        var takesOver = false
        if let pid, open[appID]?.gamePID == nil || !presentStats.hasCounted(forApp: appID) {
            takesOver = open[appID]?.gamePID != pid
            open[appID]?.gamePID = pid
            // A Quick Launch program's pages carry no app id, so its frames are found by pid.
            if AdoptedPrograms.program(appID) != nil { presentStats.claim(pid: pid, forApp: appID) }
        }
        // A game set to native NW.js whose process loaded winemac.drv was started under Wine (an
        // exe shared with another game, on an engine that keys env files by name), so it is
        // recorded as a Wine run.
        if pid != nil, open[appID]?.record.runner == GameRunner.nwjs {
            open[appID]?.record.runner = GameRunner.wine
            open[appID]?.record.renderer = Self.bottleRenderer()
            open[appID]?.record.rendererConfirmed = nil
            Self.log("run \(appID): set to the native NW.js runner, but \(exe) started under Wine — recorded as a Wine run")
        }
        guard open[appID]?.record.exe == nil || takesOver else { return }
        open[appID]?.record.exe = exe
        open[appID]?.record.product = nil
        let file = url ?? Self.executableURL(named: exe, forApp: appID)
        open[appID]?.record.arch = file.flatMap(PEResources.machine(of:))?.bits
        if AdoptedPrograms.isAdopted(appID), let info = file.flatMap(PEResources.read) {
            open[appID]?.record.product = info.productName ?? info.fileDescription
        }
        persist(appID: appID)
    }

    /// The bottle's booted renderer, else its next boot's: a Wine run's renderer until its log
    /// confirms one.
    private static func bottleRenderer() -> String {
        (BottleGraphics.bootedSelection()?.renderer ?? BottleGraphics.currentSelection().renderer).rawValue
    }

    /// Samples the meters that exist only while a run is up: the kernel's bill for the game's
    /// process and whether a Game Mode session runs. At the close `proc_pid_rusage` has nothing
    /// to read, so the record keeps the last reading. Memory only; the armed file is not rewritten.
    ///
    /// - Parameters:
    ///   - observe: The game window's focus, for the frame trace (``GameplayWindow``), and its display.
    ///   - busyThreads: Busy threads of a process (``ThreadActivity``), counted while the game is focused.
    func sample(
        observing observe: (pid_t) -> GameObservation? = { _ in nil },
        busyThreads: (pid_t) -> Int? = { ThreadActivity.busyThreads(pid: $0) },
    ) {
        guard !open.isEmpty else { return }
        let gameMode = GameModeSignal.isActive()
        for (appID, run) in open {
            // Sticky: a Game Mode session that ended before the game is still a fact about the run.
            open[appID]?.record.gameMode = gameMode || run.record.gameMode == true
            guard let pid = run.gamePID else { continue }
            if let seen = observe(pid) {
                presentStats.note(focus: seen.focus, display: seen.display, forApp: appID)
                if let display = seen.display, seen.focus == .focused || run.record.display == nil {
                    open[appID]?.record.display = display
                }
                if seen.focus == .focused, let busy = busyThreads(pid) {
                    open[appID]?.busyThreadSamples.append(busy)
                }
            }
            // The largest window seen: a game opens on a launcher or splash window first.
            if let window = MacHardware.largestWindow(ofPID: pid),
               window.area > (run.record.resolution?.window?.area ?? 0) {
                open[appID]?.record.resolution = RunRecord.Resolution(
                    window: window, render: run.record.resolution?.render,
                )
            }
            guard let usage = ProcessUsage.read(pid: pid) else { continue }
            open[appID]?.record.energy = RunRecord.Energy(usage)
        }
    }

    /// Every how many meter ticks the Wine log is read for renderer lines: ten seconds.
    static let provenanceCheckEvery = 5

    /// One open Wine run's next read of the Wine log.
    nonisolated struct ProvenanceRead: Sendable {
        let appID: Int
        let log: URL
        let offset: UInt64
    }

    /// The open Wine runs, each with where its Wine log was last read to.
    var provenanceReads: [ProvenanceRead] {
        open.compactMap { appID, run in
            guard run.record.runner != GameRunner.nwjs else { return nil }
            return ProvenanceRead(
                appID: appID, log: run.wineLog, offset: run.provenanceOffset ?? run.wineLogOffset,
            )
        }
    }

    /// Folds in the renderer lines `read` found, so a report collected mid-game already names the renderer.
    ///
    /// - Parameter read: The read that was started; its lines are dropped if the run closed or re-armed since.
    func noteProvenance(_ lines: String, readTo end: UInt64, for read: ProvenanceRead) {
        guard var run = open[read.appID],
              (run.provenanceOffset ?? run.wineLogOffset) == read.offset else { return }
        run.provenanceOffset = end
        if !lines.isEmpty {
            run.provenance += run.provenance.isEmpty ? lines : "\n" + lines
        }
        let answered = run.record.runner == GameRunner.macos ? nil : WineProvenance.renderer(
            forApp: read.appID, exe: run.record.exe, pid: run.gamePID, in: run.provenance,
        )
        let changed = answered.map { $0 != run.record.renderer || run.record.rendererConfirmed != true } ?? false
        if let answered, changed {
            run.record.renderer = answered
            run.record.rendererConfirmed = true
        }
        let starved = run.record.video == nil
            ? VideoStarvation.video(forApp: read.appID, in: run.provenance) : nil
        if let starved { run.record.video = starved }
        open[read.appID] = run
        if changed || starved != nil { persist(appID: read.appID) }
        if let starved {
            Self.log("run \(read.appID): \(starved.summary)")
            Self.didStarveVideo?(run.record)
        }
    }

    /// The renderer and decoded-nothing lines the Wine log gained from `offset`, and where the read
    /// stopped: after the last whole line. A log shorter than `offset` was replaced and is read
    /// from its start; growth past ``maximumTailBytes`` is skipped to its last stretch.
    static func provenance(in url: URL, from offset: UInt64) -> (lines: String, end: UInt64) {
        let size = size(of: url)
        var start = size < offset ? 0 : offset
        guard size > start, let handle = try? FileHandle(forReadingFrom: url) else { return ("", start) }
        defer { try? handle.close() }
        let skipped = size - start > UInt64(maximumTailBytes)
        if skipped { start = size - UInt64(maximumTailBytes) }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ("", start) }
        let whole = data[data.startIndex ... lastNewline]
        var lines = whole.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // The first line of a skipped-to stretch starts mid-line.
        if skipped, !lines.isEmpty { lines.removeFirst() }
        let kept = lines.lazy
            .map { String(decoding: $0, as: UTF8.self) }
            .filter {
                $0.contains("sevo:run pid=") || ($0.contains("sevo:gfx pid=") && $0.contains("renderer="))
                    || $0.contains(VideoStarvation.marker)
            }
        return (kept.joined(separator: "\n"), start + UInt64(whole.count))
    }

    static let nativeCheckEvery = 3

    /// Open runs on the native NW.js runner, whose end only their processes tell.
    var nativeRuns: [Int] {
        open.filter { $0.value.record.runner == GameRunner.nwjs }.map(\.key)
    }

    /// Open runs of Quick Launch programs. A Quick Launch start sends no lifetime edge, so their
    /// processes tell their end; a library start also has Steam's edge, and the first closes the
    /// run.
    var programRuns: [Int] {
        open.filter { appID, run in
            run.record.runner != GameRunner.nwjs && AdoptedPrograms.program(appID) != nil
        }.map(\.key)
    }

    /// Empty checks that close a program run whose process never appeared: about two minutes, since
    /// a HoYoverse game's first launch makes its companion prefix first.
    static let programNeverSeenChecks = 20

    private var nativeSeen: Set<Int> = []
    private var nativeUnseen: [Int: Int] = [:]
    /// Empty checks that close a native run never seen alive: about thirty seconds.
    static let nativeNeverSeenChecks = 5

    /// A native run's processes were looked for. Seen and then gone ends the run, as a requested
    /// stop or as `gone` (nil leaves a Wine program's ending to its Wine trail); never seen closes
    /// it after `neverSeenChecks` empty looks.
    func noteNativeProcesses(
        alive: Bool, forApp appID: Int, gone: RunRecord.Exit.Kind? = .user,
        neverSeenChecks: Int = nativeNeverSeenChecks,
    ) {
        if alive {
            nativeSeen.insert(appID)
            nativeUnseen[appID] = nil
        } else if nativeSeen.remove(appID) != nil {
            let stop = RunLog.takeStopRequest(forApp: appID, in: runs)
            close(appID: appID, kind: stop.map(RunInProgress.stoppedKind) ?? gone)
        } else {
            let checks = nativeUnseen[appID, default: 0] + 1
            nativeUnseen[appID] = checks
            if checks >= neverSeenChecks { close(appID: appID, kind: .unknown) }
        }
    }

    /// How often ``sample`` runs: two system calls per open run, the stall watchdog's cadence.
    static let meterInterval: Duration = .seconds(2)

    var isRecording: Bool {
        !open.isEmpty
    }

    /// Runs closed so far, so a poller sees every closing, a re-arm within one poll included.
    private(set) var closedRuns = 0

    /// The macOS pid each open run follows, for the stall watchdog and the process monitor.
    var runningPIDs: [Int: pid_t] {
        open.compactMapValues(\.gamePID)
    }

    /// Moves an open run onto another process of the game, after the followed one exited.
    func follow(pid: pid_t, forApp appID: Int) {
        open[appID]?.gamePID = pid
    }

    /// An open run's record as it stands, for acting on a game still playing.
    func openRecord(forApp appID: Int) -> RunRecord? {
        guard var run = open[appID] else { return nil }
        run.record.durationSeconds = Self.seconds(since: run.started)
        return run.record
    }

    /// One rung of the stall ladder, written into its run; `at` comes from the run's start minus
    /// the stall's length.
    func noteStall(lasting duration: Double, unwedged: String?, forApp appID: Int) {
        guard let run = open[appID] else { return }
        // Clamped: two different clocks decide this.
        let stall = RunRecord.Stall(
            at: max(0, Self.seconds(since: run.started) - duration), duration: duration,
            unwedged: unwedged,
        )
        open[appID]?.record.stalls = (run.record.stalls ?? []) + [stall]
        persist(appID: appID)
    }

    /// The tuning a record carries; a custom preset includes its parameters, since only those make
    /// two custom runs comparable.
    private static func tuningLabel(forApp appID: Int) -> String {
        let tuning = GameConfig.tuning(bottle: SteamBottle.name, game: appID).value
        guard tuning == .custom else { return tuning.rawValue }
        return "custom:\(GameConfig.tuningParameters(bottle: SteamBottle.name, game: appID).argument)"
    }

    /// The processors a launch is told of: its cap when below the Mac's count.
    private static func processorsSeen(forApp appID: Int) -> Int {
        let host = ProcessInfo.processInfo.activeProcessorCount
        let cap = GameConfig.processors(bottle: SteamBottle.name, game: appID).value
        return cap > 0 ? min(cap, host) : host
    }

    /// The launch's executable on disk: in the Steam install, or wherever an adopted program came
    /// from.
    private static func executableURL(named exe: String, forApp appID: Int) -> URL? {
        let wanted = exe.lowercased()
        if let program = GameConfig.game(appID).program,
           program.url.lastPathComponent.lowercased() == wanted {
            return program.url
        }
        guard let directory = SharedGames.installDirectory(appID: appID) else { return nil }
        return GameExecutables.executableURLs(in: directory)
            .first { $0.lastPathComponent.lowercased() == wanted }
    }

    func noteWindowUp(forApp appID: Int) {
        guard var run = open[appID], run.record.windowAfterSeconds == nil else { return }
        run.record.windowAfterSeconds = Self.seconds(since: run.started)
        open[appID] = run
        persist(appID: appID)
    }

    func noteSteamError(_ detail: String, forApp appID: Int) {
        guard let run = open[appID], run.steamError != detail else { return }
        open[appID]?.steamError = detail
        persist(appID: appID)
    }

    /// The client says the app is running. A run it never announced (a launcher's game, after the
    /// launcher's run closed) opens here.
    func noteRunning(appID: Int) {
        if open[appID] == nil { arm(appID: appID) }
        confirmedRunning.insert(appID)
        handovers[appID] = nil
    }

    /// The client says the app stopped running. Right after a hand-over that is the old instance
    /// going.
    func noteStopped(appID: Int) {
        if let handover = handovers.removeValue(forKey: appID),
           !confirmedRunning.contains(appID),
           ContinuousClock.now - handover < Self.handoverWindow {
            return
        }
        close(appID: appID)
    }

    /// Ends the open run of `appID`; the record is written on the closing queue, since it reads two logs.
    ///
    /// - Parameters:
    ///   - kind: The ending the caller knows for a fact.
    ///   - unrecorded: The ending when Steam wrote no exit and the logs name nothing else.
    ///   - durationKnown: False for a run that ended unwatched, which records no duration.
    func close(
        appID: Int, kind: RunRecord.Exit.Kind? = nil, unrecorded: RunRecord.Exit.Kind = .unknown,
        durationKnown: Bool = true,
    ) {
        guard var run = open.removeValue(forKey: appID) else { return }
        closedRuns += 1
        onClose?(appID)
        confirmedRunning.remove(appID)
        nativeSeen.remove(appID)
        nativeUnseen[appID] = nil
        run.record.fps = presentStats.disarm(appID: appID)
        // Disarmed before the write: the app id can be re-armed at once, and a later disarm would
        // take the new run's file.
        RunLog.disarm(appID: appID, in: runs)
        let lasted = durationKnown ? Self.seconds(since: run.started) : nil
        // Only a program closing now has a launcher still writing its exit line.
        let grace = durationKnown && AdoptedPrograms.isAdopted(appID) ? programExitGrace : .zero
        Self.closings.async {
            run.write(lasting: lasted, kind: kind, unrecorded: unrecorded, programExitGrace: grace)
        }
    }

    /// Closes every open run, inline, for the quit path. A game still up is about to go down with
    /// the bottle, so an ending Steam never recorded is the quit.
    func closeAll() {
        for var run in open.values {
            run.record.fps = presentStats.disarm(appID: run.record.appid)
            RunLog.disarm(appID: run.record.appid, in: runs)
            run.write(
                lasting: Self.seconds(since: run.started), kind: nil, unrecorded: .appQuit,
            )
        }
        open.removeAll()
    }

    /// Takes over the runs an earlier process of this app left armed on disk (a force-quit leaves
    /// its game running). Steam's process log, rewritten at each client start, says which are still
    /// up.
    func reattach() {
        for armed in RunLog.armedRuns(in: runs) {
            let appID = armed.record.appid
            guard open[appID] == nil else { continue }
            let lasted = max(0, Date.now.timeIntervalSince(armed.started))
            let steamLog = armed.steamLog.map { URL(fileURLWithPath: $0) }
                ?? processLogOverride ?? Self.steamProcessLogURL
            open[appID] = OpenRun(
                started: .now.advanced(by: .seconds(-lasted)),
                record: armed.record,
                wineLogOffset: armed.wineLogOffset,
                steamLogOffset: armed.steamLogOffset,
                steamError: armed.steamError,
                processors: Self.processorsSeen(forApp: appID),
                runsRoot: runs,
                wineLog: wineLog,
                processLog: steamLog,
            )
            let tail = Self.text(of: steamLog, from: armed.steamLogOffset)
            let stillUp = SteamGameProcessLog.tracks(app: appID, in: tail)
                && SteamGameProcessLog.exits(forApp: appID, in: tail).isEmpty
            if stillUp {
                // The counter starts now; the earlier process's trace stays as it is.
                presentStats.arm(appID: appID)
                Self.log("run reattached — \(armed.record.summary)")
            } else {
                close(appID: appID, durationKnown: false)
            }
        }
    }

    private func persist(appID: Int) {
        guard let run = open[appID] else { return }
        RunLog.arm(run.armed, in: runs)
    }

    /// Serial, so two games ending together write two records rather than one damaged line.
    private static let closings = DispatchQueue(label: "sevo.runrecorder", qos: .utility)

    // MARK: - The machine

    private static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var chip: String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0
        else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &value, &size, nil, 0) == 0
        else { return nil }
        return String(decoding: value.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func hostState() -> RunRecord.Host {
        let snapshot = HostSnapshot.take()
        return RunRecord.Host(thermal: snapshot.thermalState, load: snapshot.loadAverage1m)
    }

    fileprivate static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return (seconds * 10).rounded() / 10
    }

    // MARK: - The two logs a run's end is read from

    static var steamProcessLogURL: URL {
        SteamBottle.steamRoot.appendingPathComponent("logs/gameprocess_log.txt")
    }

    /// The same log in a named engine's bottle, for a run recorded against the engine that booted
    /// the client.
    static func steamProcessLogURL(forEngine engine: Engine) -> URL {
        SteamBottle
            .steamRoot(inBottle: engine.bottlesRoot.appendingPathComponent(SteamBottle.name))
            .appendingPathComponent("logs/gameprocess_log.txt")
    }

    /// What `url` gained from `offset`, at most ``maximumTailBytes`` of its end. A file shorter
    /// than the offset was truncated (Steam rewrites its log at each client start) and is read from
    /// its start.
    fileprivate static func text(of url: URL, from offset: UInt64) -> String {
        let size = size(of: url)
        let start = size < offset ? 0 : offset
        guard size > start, let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let length = min(Int(size - start), maximumTailBytes)
        guard (try? handle.seek(toOffset: size - UInt64(length))) != nil,
              let data = try? handle.read(upToCount: length) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// How much of a log's growth is read at a run's end: a verbose channel overnight writes
    /// gigabytes, and the ending is at the end.
    private static let maximumTailBytes = 4_000_000

    private static func size(of url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
