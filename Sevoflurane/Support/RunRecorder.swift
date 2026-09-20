import Foundation

/// A launch in progress and everything about the machine that was true when
/// it started. `Sendable` so closing one can leave the caller's actor: it
/// reads the tails of two logs, which is disk work.
nonisolated struct RunInProgress: Sendable {
    let started: ContinuousClock.Instant
    var record: RunRecord
    /// The macOS pid of the launch's own executable, from the dock shim's
    /// chronicle. It is what the run's meters are read from, and it is not
    /// carried in the armed file: a pid outlives nothing, and the next
    /// process to hold that number is somebody else's.
    var gamePID: pid_t?
    /// Where the two logs ended when the run began; what they gained since is
    /// the run's own output.
    let wineLogOffset: UInt64
    let steamLogOffset: UInt64
    /// The client showed an error for this game action.
    var steamError: String?
    /// Where the record goes when the run is over, and the two logs its
    /// ending is read from.
    var runsRoot = RunLog.root
    var wineLog = WineLog.fileURL
    var processLog = RunRecorder.steamProcessLogURL

    /// Reads what the two logs gained during the run, decides how it ended,
    /// and appends the record.
    ///
    /// - Parameters:
    ///   - kind: The ending the caller knows for a fact whatever the logs say
    ///     — the stall watchdog's kill.
    ///   - unrecorded: What an ending Steam never wrote down is, on this
    ///     path. A quit takes the bottle down with the app, so Steam is gone
    ///     before it can record the exit it caused.
    func write(
        lasting seconds: Double,
        kind: RunRecord.Exit.Kind?,
        unrecorded: RunRecord.Exit.Kind = .unknown,
    ) {
        var record = record
        record.durationSeconds = seconds
        let steamTail = RunRecorder.text(of: processLog, from: steamLogOffset)
        let wineTail = RunRecorder.text(of: wineLog, from: wineLogOffset)
        record.runtime = SteamGameProcessLog.runtime(
            forApp: record.appid, in: steamTail, exe: record.exe,
        )
        let exit = SteamGameProcessLog.exit(
            forApp: record.appid, running: record.exe, in: steamTail,
        )
        if let answered = WineProvenance.renderer(forApp: record.appid, exe: record.exe, in: wineTail) {
            record.renderer = answered
        }
        record.crash = WineExceptionTrail.lastException(in: wineTail)
        let notes = WineExceptionTrail.notes(in: wineTail)
        record.notes = notes.isEmpty ? nil : notes
        let endedNotResponding = wineTail.contains("ended by the user while not responding")
        record.exit = RunRecord.Exit(
            kind: kind ?? Self.kind(
                code: exit?.code, crashed: record.crash != nil, endedNotResponding: endedNotResponding,
                stopRequested: RunLog.takeStopRequest(forApp: record.appid, in: runsRoot),
                steamError: steamError, unrecorded: unrecorded,
            ),
            code: exit?.code,
        )
        RunLog.append(record, in: runsRoot)
        RunRecorder.log("run recorded — \(record.summary)")
        RunRecorder.didClose(record)
        RunRecorder.didRecord?(record, wineTail)
    }

    /// How a run ended, from what the client and Steam's log actually say.
    private static func kind(
        code: Int?, crashed: Bool, endedNotResponding: Bool, stopRequested: Bool, steamError: String?,
        unrecorded: RunRecord.Exit.Kind,
    ) -> RunRecord.Exit.Kind {
        if crashed { return .crash }
        if endedNotResponding { return .endedNotResponding }
        if let code {
            if code == 0 { return .user }
            return stopRequested ? .stopped : .exitError
        }
        return steamError == nil ? unrecorded : .steamTerminate
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

/// A record's own moment: UTC, seconds, so records from two machines sort
/// against each other. Spelled out rather than taken from
/// `ISO8601DateFormatter`, which is not `Sendable` and would need an unchecked
/// global to be shared between the app and `sevo`.
nonisolated let runRecordStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}()

/// Opens a record when the client says a launch began, and closes it when the
/// client says the app stopped running.
///
/// Armed at `GameActionStart` rather than at the first window: three of the
/// five failed launches of the 2026-09-08 playtest never had a window, and a
/// recorder hung off the window watch records nothing for exactly the launches
/// worth recording. Closed from the client's own
/// `GameSessions.RegisterForAppLifetimeNotifications`, because a game Steam
/// started is not a process this app can wait on; the exit status comes from
/// Steam's `gameprocess_log.txt`, which is the only place it exists.
///
/// Steam can have two games up at once, so a run is keyed by app id.
final nonisolated class RunRecorder {
    /// Where the recorder narrates. The app points it at its own event log.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = { _ in }

    /// A record has been written, complete with how the run ended. Called on
    /// the closing queue; the app hops to the main actor from here to decide
    /// whether the ending deserves a word with the user.
    nonisolated(unsafe) static var didClose: @Sendable (RunRecord) -> Void = { _ in }

    /// A run that has just been written, with what the Wine log gained while
    /// it ran. The app hangs report collection off it (``CrashCollector``);
    /// the CLI leaves it unset, since a `sevo` process only ever reads
    /// records somebody else wrote.
    ///
    /// Called on the closing queue, after the record is on disk.
    nonisolated(unsafe) static var didRecord: (@Sendable (RunRecord, String) -> Void)?

    private var open: [Int: OpenRun] = [:]
    private var hasGroomed = false
    /// The directory this recorder's records and armed runs live in, and
    /// the two logs it reads a run's ending out of.
    private let runs: URL
    private let wineLog: URL
    /// A fixed Steam process-log to read a run's ending from. Nil in
    /// production, where each `arm` resolves the booted engine's bottle log
    /// at launch time (the engine can change between launches); a test injects
    /// a concrete file so its fixtures, not a real bottle, decide the run.
    private let processLogOverride: URL?
    /// The driver's present counters, sampled for as long as a run is open;
    /// what fills the record's ``RunRecord/fps``.
    let presentStats: PresentStats

    /// A launch in progress and everything about the machine that was true
    /// when it started. `Sendable` so closing one can leave the main actor:
    /// it reads the tails of two logs, which is disk work.
    typealias OpenRun = RunInProgress

    init(
        runs: URL = RunLog.root,
        wineLog: URL = WineLog.fileURL,
        processLog: URL? = nil,
        presentStats: PresentStats = PresentStats(),
    ) {
        self.runs = runs
        self.wineLog = wineLog
        self.processLogOverride = processLog
        self.presentStats = presentStats
    }

    /// Apps whose open run the client has confirmed running.
    private var confirmedRunning: Set<Int> = []
    /// When a launch of an app took over from a run of it that was still open:
    /// a game's launcher starting the game. The stop edge that follows within
    /// ``handoverWindow`` is the launcher's, and the new run outlives it.
    private var handovers: [Int: ContinuousClock.Instant] = [:]
    private static let handoverWindow: Duration = .seconds(5)

    /// A launch of `appID` has begun. Re-arming an app that is already open
    /// closes the old run: the client has told us a new one started, so
    /// whatever the old one did, it is over and nobody said how.
    func arm(appID: Int) {
        guard appID != 0 else { return }
        if open[appID] != nil {
            close(appID: appID, kind: .unknown)
            handovers[appID] = .now
        }
        confirmedRunning.remove(appID)
        let values = GameConfig.game(appID)
        let booted = BottleGraphics.bootedSelection()
        let selection = booted.map {
            (renderer: $0.renderer, msync: $0.msync, d3dMetalVersion: $0.d3dMetalVersion)
        } ?? {
            let current = BottleGraphics.currentSelection()
            return (current.renderer, current.msync, current.d3dMetalVersion)
        }()
        // The engine the running client booted from, which is what actually
        // ran the game — never Engine.active, which may already name the next
        // restart's staged selection. Its bottle is where Steam wrote this
        // run's exit, so the record and the log it reads name the same engine.
        let bootedEngine = BottleGraphics.bootedEngineRoot().flatMap(Engine.booted(fromRoot:))
        let steamLog = processLogOverride
            ?? bootedEngine.map(Self.steamProcessLogURL(forEngine:))
            ?? Self.steamProcessLogURL
        let now = Date.now
        let record = RunRecord(
            t: runRecordStamp.string(from: now),
            appid: appID,
            name: values.name,
            engine: (bootedEngine ?? Engine.active).recordIdentifier,
            renderer: values.runner == GameRunner.nwjs ? GameRunner.nwjs : selection.renderer.rawValue,
            runner: values.runner ?? GameRunner.wine,
            windows: GameConfig.windows(bottle: SteamBottle.name, game: appID).value.rawValue,
            tuning: Self.tuningLabel(forApp: appID),
            upscaler: GameConfig.upscaler(bottle: SteamBottle.name, game: appID).value,
            msync: selection.msync,
            d3dmetal: selection.d3dMetalVersion,
            macos: Self.macOSVersion,
            chip: Self.chip,
            host: Self.hostState(),
        )
        open[appID] = OpenRun(
            started: .now,
            record: record,
            wineLogOffset: Self.size(of: wineLog),
            steamLogOffset: Self.size(of: steamLog),
            runsRoot: runs,
            wineLog: wineLog,
            processLog: steamLog,
        )
        persist(appID: appID)
        presentStats.arm(appID: appID)
        if !hasGroomed {
            hasGroomed = true
            Task.detached(name: "Groom the run records") { [runs] in RunLog.groom(in: runs) }
        }
    }

    /// One of the launch's processes reached the Mac driver, named by the
    /// dock shim's chronicle. The executable's file, found in the game's
    /// install or given by the caller, says whether it is a 32- or 64-bit
    /// image; the chronicle's pid is what the run's meters are read from.
    func noteExecutable(
        _ exe: String, pid: pid_t? = nil, forApp appID: Int, at url: URL? = nil,
    ) {
        if let pid { open[appID]?.gamePID = pid }
        guard open[appID]?.record.exe == nil else { return }
        open[appID]?.record.exe = exe
        let file = url ?? Self.executableURL(named: exe, forApp: appID)
        open[appID]?.record.arch = file.flatMap(PEResources.machine(of:))?.bits
        persist(appID: appID)
    }

    /// Reads the meters that only exist while a run is up: what the kernel
    /// has billed the game's own process, and whether macOS is running a Game
    /// Mode session.
    ///
    /// Sampled rather than read at the close, because by then the process is
    /// gone and `proc_pid_rusage` has nothing to answer with; the last
    /// reading that came back is what the record keeps, and the counters only
    /// grow. Called every ``meterInterval`` while any run is open.
    ///
    /// Memory only: a sample every two seconds is not worth a write to the
    /// armed file, whose job is to name the launch a killed app left running.
    func sample() {
        guard !open.isEmpty else { return }
        let gameMode = GameModeSignal.isActive()
        for (appID, run) in open {
            // Sticky: a session that began when the game went full screen and
            // ended before the game did is still a fact about the run.
            open[appID]?.record.gameMode = gameMode || run.record.gameMode == true
            guard let pid = run.gamePID, let usage = ProcessUsage.read(pid: pid) else { continue }
            open[appID]?.record.energy = RunRecord.Energy(usage)
        }
    }

    /// Every how many meter ticks the native runs' processes are looked for.
    static let nativeCheckEvery = 3

    /// The open runs on the native NW.js runner, whose end only their own
    /// processes tell.
    var nativeRuns: [Int] {
        open.filter { $0.value.record.runner == GameRunner.nwjs }.map(\.key)
    }

    /// Native runs whose processes have been seen alive.
    private var nativeSeen: Set<Int> = []

    /// A native run's processes were looked for. Seen and then gone is the
    /// end of the run; never seen yet is a game still starting.
    func noteNativeProcesses(alive: Bool, forApp appID: Int) {
        if alive {
            nativeSeen.insert(appID)
        } else if nativeSeen.remove(appID) != nil {
            // No exit code exists for a process Steam never tracked: it was
            // asked to stop, or the player closed it.
            close(appID: appID, kind: RunLog.takeStopRequest(forApp: appID, in: runs) ? .stopped : .user)
        }
    }

    /// How often ``sample`` is worth calling: two system calls per open run,
    /// which is the same cadence the stall watchdog samples at.
    static let meterInterval: Duration = .seconds(2)

    /// Whether any run is open, which is what makes the meters worth reading
    /// and the machine worth sampling.
    var isRecording: Bool {
        !open.isEmpty
    }

    /// The macOS process each open run is running under, for the watchdog that
    /// samples them and for the monitor that lists them. A run whose
    /// executable never reached the Mac driver is not in it.
    var runningPIDs: [Int: pid_t] {
        open.compactMapValues(\.gamePID)
    }

    /// An open run's record as it stands, for anything that wants to act on a
    /// game that is still playing — the process monitor collecting its report
    /// without waiting for it to end.
    func openRecord(forApp appID: Int) -> RunRecord? {
        guard var run = open[appID] else { return nil }
        run.record.durationSeconds = Self.seconds(since: run.started)
        return run.record
    }

    /// One rung of the stall ladder, written into the run it happened in.
    ///
    /// `at` is measured from the run's own start rather than passed in: the
    /// watchdog knows how long the game has been still, and the record wants
    /// to know when in the session that was.
    func noteStall(lasting duration: Double, unwedged: String?, forApp appID: Int) {
        guard let run = open[appID] else { return }
        // Clamped: a rung cannot have happened before the run it is in, and
        // the two clocks that decide this are not the same one.
        let stall = RunRecord.Stall(
            at: max(0, Self.seconds(since: run.started) - duration), duration: duration,
            unwedged: unwedged,
        )
        open[appID]?.record.stalls = (run.record.stalls ?? []) + [stall]
        persist(appID: appID)
    }

    /// Where the executable a launch named sits on disk: in the app's Steam
    /// install, or, for an adopted program, wherever it was adopted from.
    /// The tuning a record carries: the preset, and for a custom one its
    /// parameters, since two custom runs are only comparable by them.
    private static func tuningLabel(forApp appID: Int) -> String {
        let tuning = GameConfig.tuning(bottle: SteamBottle.name, game: appID).value
        guard tuning == .custom else { return tuning.rawValue }
        return "custom:\(GameConfig.tuningParameters(bottle: SteamBottle.name, game: appID).argument)"
    }

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

    /// The game's first window is on screen.
    func noteWindowUp(forApp appID: Int) {
        guard var run = open[appID], run.record.windowAfterSeconds == nil else { return }
        run.record.windowAfterSeconds = Self.seconds(since: run.started)
        open[appID] = run
        persist(appID: appID)
    }

    /// The client raised an error for this game action.
    func noteSteamError(_ detail: String, forApp appID: Int) {
        guard let run = open[appID], run.steamError != detail else { return }
        open[appID]?.steamError = detail
        persist(appID: appID)
    }

    /// The client says the app is running. A run it never announced a launch
    /// for (the game a launcher started, after the launcher's own run closed)
    /// opens here.
    func noteRunning(appID: Int) {
        if open[appID] == nil { arm(appID: appID) }
        confirmedRunning.insert(appID)
        handovers[appID] = nil
    }

    /// The client says the app stopped running. Right after a hand-over that
    /// is the old instance going, and the run just armed has yet to start.
    func noteStopped(appID: Int) {
        if let handover = handovers.removeValue(forKey: appID),
           !confirmedRunning.contains(appID),
           ContinuousClock.now - handover < Self.handoverWindow {
            return
        }
        close(appID: appID)
    }

    /// Ends the open run of `appID`. The record is written on the closing
    /// queue: finishing it reads the tails of two logs, which is disk work
    /// the caller should not wait on.
    func close(appID: Int, kind: RunRecord.Exit.Kind? = nil) {
        guard var run = open.removeValue(forKey: appID) else { return }
        confirmedRunning.remove(appID)
        nativeSeen.remove(appID)
        run.record.fps = presentStats.disarm(appID: appID)
        // Before the write rather than after it: the same app id can be armed
        // again in the next moment, and a disarm behind that would take the
        // new run's file with it.
        RunLog.disarm(appID: appID, in: runs)
        let lasted = Self.seconds(since: run.started)
        Self.closings.async { run.write(lasting: lasted, kind: kind) }
    }

    /// Closes every open run, for the quit path: the app is going away and
    /// nothing will learn any more about these than is already on disk.
    /// Inline, because nothing will drain a queue after this either.
    ///
    /// A game still up here is one the teardown is about to take down with
    /// the bottle, so an ending Steam never recorded is that quit.
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

    /// Takes over the runs an earlier process of this app left open.
    ///
    /// A game outlives the app that launched it — a force-quit sends the
    /// bottle nothing — so the launch is armed on disk as well as in memory
    /// and read back here. Steam's own process log is what says which of them
    /// is still up: it tracks every process it started for an app id, and it
    /// is rewritten at each client start, so an app with no line in it at all
    /// belongs to a client session that is over.
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
                runsRoot: runs,
                wineLog: wineLog,
                processLog: steamLog,
            )
            let tail = Self.text(of: steamLog, from: armed.steamLogOffset)
            let stillUp = SteamGameProcessLog.tracks(app: appID, in: tail)
                && SteamGameProcessLog.exits(forApp: appID, in: tail).isEmpty
            if stillUp {
                // The counter starts from this moment: the frames of the run
                // before the app went away are in no page this process read.
                presentStats.arm(appID: appID)
                Self.log("run reattached — \(armed.record.summary)")
            } else {
                close(appID: appID)
            }
        }
    }

    /// Writes an open run to disk, so the launch outlives this process.
    private func persist(appID: Int) {
        guard let run = open[appID] else { return }
        RunLog.arm(run.armed, in: runs)
    }

    /// Where a closing run reads its logs and writes its record. Serial, so
    /// two games ending together are two records rather than one damaged
    /// line.
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

    /// Elapsed seconds, one decimal.
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

    /// The same log inside a named engine's own bottle, for a run recorded
    /// against the engine that booted the client rather than ``Engine/active``.
    static func steamProcessLogURL(forEngine engine: Engine) -> URL {
        SteamBottle
            .steamRoot(inBottle: engine.bottlesRoot.appendingPathComponent(SteamBottle.name))
            .appendingPathComponent("logs/gameprocess_log.txt")
    }

    /// A file shorter than the offset was truncated under us (Steam rewrites
    /// its own log at each client start) and is read whole.
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

    /// How much of a log's growth is read back at a run's end. A game left
    /// running overnight with a verbose channel on can write gigabytes; the
    /// exception that ends it is at the end.
    private static let maximumTailBytes = 4_000_000

    private static func size(of url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
