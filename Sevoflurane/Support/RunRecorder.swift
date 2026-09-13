import Foundation

/// One game launch: what it ran on, how long it lasted, and how it ended.
///
/// The record is the spine of the diagnostics (`Docs/diagnostics-plan.md`):
/// the summary a report window shows, the body of an issue, and the only
/// thing that survives a game that dies in two seconds with nothing on
/// screen. It names no one — see ``Redaction`` for what is kept out.
nonisolated struct RunRecord: Codable, Equatable, Sendable {
    /// When the launch began, UTC, seconds.
    var t: String
    var appid: Int
    /// The game's title, as the library spells it.
    var name: String? = nil
    /// The executable the launch's own processes ran, from the dock shim's
    /// chronicle. Absent for a launch whose process never reached the Mac
    /// driver.
    var exe: String? = nil
    /// The engine directory's version (`dormison-r4`), or the CodeWeavers app.
    var engine: String
    /// What the client booted with, which is what the game inherited — never
    /// the stored selection, which may already name the next restart's.
    var renderer: String
    /// `wine` or `nwjs` (``GameRunner``).
    var runner: String
    /// The driver's window treatment for this game (``WindowTreatment``).
    var windows: String
    var msync: Bool
    /// The D3DMetal toolkit version in force, when there is one.
    var d3dmetal: String? = nil
    /// What the game is built on, told by the processes Steam tracked for it:
    /// `unity`, `unreal`, or absent when nothing said.
    var runtime: String? = nil
    var macos: String
    var chip: String? = nil
    /// How long after the launch began the game's first window appeared.
    /// Absent for a run that never drew.
    var windowAfterSeconds: Double? = nil
    var durationSeconds: Double? = nil
    /// Present once the driver's present counter lands (`Docs/diagnostics-plan.md`).
    var fps: FrameRate? = nil
    /// Present once the stall watchdog lands.
    var stalls: [Stall]? = nil
    var exit: Exit? = nil
    var crash: Crash? = nil
    /// The renderer's own complaints during the run, deduplicated with counts.
    var notes: [String]? = nil
    var host: Host

    enum CodingKeys: String, CodingKey {
        case t
        case appid
        case name
        case exe
        case engine
        case renderer
        case runner
        case windows
        case msync
        case d3dmetal
        case runtime
        case macos
        case chip
        case windowAfterSeconds = "window_after_s"
        case durationSeconds = "duration_s"
        case fps
        case stalls
        case exit
        case crash
        case notes
        case host
    }

    struct FrameRate: Codable, Equatable, Sendable {
        var avg: Double
        /// The slowest one per cent of the per-second samples.
        var low1: Double
        var samples: Int
    }

    struct Stall: Codable, Equatable, Sendable {
        var at: Double
        var duration: Double
        /// What got it moving again, when something did.
        var unwedged: String?

        enum CodingKeys: String, CodingKey {
            case at = "at_s"
            case duration = "for_s"
            case unwedged
        }
    }

    struct Exit: Codable, Equatable, Sendable {
        var kind: Kind
        /// The process's status as Steam recorded it, absent when Steam never
        /// tracked an exit.
        var code: Int?

        /// How a run ended, decided from what the client and Steam's own log
        /// say — never from a window disappearing.
        enum Kind: String, Codable, Sendable {
            /// The game's process exited with status 0.
            case user
            /// The client raised an error for the game action and no process
            /// exit followed: Steam ended the run itself.
            case steamTerminate = "steam-terminate"
            /// A non-zero exit status, or an unhandled exception in the Wine
            /// log during the run.
            case crash
            /// The app killed the game (the stall watchdog).
            case watchdog
            /// Sevoflurane quit, and the teardown that follows took the
            /// bottle — and the game in it — down.
            case appQuit = "app-quit"
            /// The run closed without the app learning an exit — the client
            /// went away before it recorded one.
            case unknown
        }
    }

    /// Wine's unhandled-exception record for the run (`err:seh`, always on).
    struct Crash: Codable, Equatable, Sendable {
        /// The NT status, `0xc0000005` and friends.
        var code: String
        var flags: String?
        var address: String?
        /// The faulting module, when the trail names one.
        var module: String?
    }

    struct Host: Codable, Equatable, Sendable {
        var thermal: String
        var load: Double
    }

    /// The level-0 summary: one line naming the game, what it ran on, how
    /// long it lasted and how it ended.
    var summary: String {
        var parts = [name.map { "\($0) (\(appid))" } ?? "app \(appid)", engine, renderer]
        if let durationSeconds { parts.append(Self.duration(durationSeconds)) }
        parts.append(exitSummary)
        return parts.joined(separator: " · ")
    }

    private var exitSummary: String {
        guard let exit else { return "still running" }
        let code = exit.code.map { " \($0)" } ?? ""
        return switch exit.kind {
        case .user: "exited normally"
        case .crash: "crashed — exit\(code)"
        case .steamTerminate: "stopped by Steam"
        case .watchdog: "killed after a stall"
        case .appQuit: "ended when Sevoflurane quit"
        case .unknown: "ended, exit unknown"
        }
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 90
            ? "ran \(Int(seconds.rounded())) s"
            : "ran \(Int((seconds / 60).rounded())) min"
    }
}

/// The run records on disk: one JSON Lines file per month under
/// `~/Library/Application Support/Sevoflurane/Runs`, months before the current
/// one compressed, twelve kept, and `open/` beside them holding the launches
/// that have been armed and not yet recorded.
///
/// JSON Lines rather than one document: a record is appended by a process
/// that may be killed at any moment, and a truncated last line costs one
/// record instead of the file.
///
/// Every entry point takes the directory to work in, defaulting to the one
/// the app and the CLI share, so a test can drive a whole recorder without
/// writing into it.
nonisolated enum RunLog {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/Runs")

    /// How many months are kept.
    static let monthsKept = 12

    /// A month's file, whether or not it exists.
    static func url(forMonth date: Date, in root: URL = root) -> URL {
        root.appendingPathComponent("\(month(of: date)).jsonl")
    }

    /// Appends one record. Two games can end at the same moment, and a
    /// seek-to-end followed by a write is not atomic against another one, so
    /// every append goes through one queue.
    static func append(_ record: RunRecord, in root: URL = root) {
        guard let line = try? encoder.encode(record) else { return }
        writes.sync {
            let manager = FileManager.default
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)
            let url = url(forMonth: .now, in: root)
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line + Data("\n".utf8))
        }
    }

    private static let writes = DispatchQueue(label: "sevo.runlog")

    // MARK: - Runs that are still open

    /// A launch that has been armed and not yet closed, as it sits on disk.
    ///
    /// The in-memory recorder dies with its process, and a game does not: a
    /// force-quit under a running game would otherwise leave nothing for the
    /// next launch of the app to write. One file per app id, removed when the
    /// run is recorded.
    struct ArmedRun: Codable, Sendable {
        var record: RunRecord
        /// When the run was armed, wall clock — the elapsed time of a run
        /// that outlived the app cannot come off a monotonic clock.
        var started: Date
        var wineLogOffset: UInt64
        var steamLogOffset: UInt64
        /// The client's error for this game action, when it showed one.
        var steamError: String?
        /// Steam's process log for the engine that booted the client, so a
        /// reattached run reads its exit from the same bottle it armed
        /// against. Absent for a run armed before this was recorded.
        var steamLog: String?
    }

    /// Where armed runs are parked. A directory rather than a file, so one
    /// game's arming never rewrites another's.
    static func openRoot(in root: URL = root) -> URL {
        root.appendingPathComponent("open")
    }

    /// Writes an armed run, replacing whatever this app id had.
    static func arm(_ run: ArmedRun, in root: URL = root) {
        guard let data = try? encoder.encode(run) else { return }
        writes.sync {
            try? FileManager.default
                .createDirectory(at: openRoot(in: root), withIntermediateDirectories: true)
            try? data.write(to: openURL(forApp: run.record.appid, in: root), options: .atomic)
        }
    }

    /// Forgets an armed run — it has been recorded, or nothing is left that
    /// could say more about it.
    static func disarm(appID: Int, in root: URL = root) {
        writes.sync {
            try? FileManager.default.removeItem(at: openURL(forApp: appID, in: root))
        }
    }

    /// Every run left armed, oldest app id first.
    static func armedRuns(in root: URL = root) -> [ArmedRun] {
        let open = openRoot(in: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: open.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: open.appendingPathComponent(name))
            else { return nil }
            return try? decoder.decode(ArmedRun.self, from: data)
        }
    }

    private static func openURL(forApp appID: Int, in root: URL) -> URL {
        openRoot(in: root).appendingPathComponent("\(appID).json")
    }

    /// Every record of a month, oldest first.
    static func records(inMonth date: Date, in root: URL = root) -> [RunRecord] {
        records(in: url(forMonth: date, in: root))
    }

    /// The most recent records across as many months as it takes, oldest
    /// first.
    ///
    /// By when each launch began, not by when its record was appended: a game
    /// still up when the app quits is written after games that started and
    /// ended while it ran.
    static func recent(_ limit: Int, in root: URL = root) -> [RunRecord] {
        var found: [RunRecord] = []
        for url in monthFiles(in: root).reversed() {
            found = records(in: url) + found
            if found.count >= limit { break }
        }
        return Array(found.sorted { $0.t < $1.t }.suffix(limit))
    }

    /// Compresses every month before this one and drops all but the newest
    /// ``monthsKept``. Cheap enough to run at each app start; it does nothing
    /// on the second call of a month.
    static func groom(in root: URL = root) {
        let manager = FileManager.default
        let current = month(of: .now)
        for url in monthFiles(in: root) where url.pathExtension == "jsonl" {
            guard url.deletingPathExtension().lastPathComponent != current,
                  let data = try? Data(contentsOf: url),
                  let compressed = try? (data as NSData).compressed(using: .zlib) else { continue }
            let target = url.appendingPathExtension(compressedExtension)
            guard (try? compressed.write(to: target)) != nil else { continue }
            try? manager.removeItem(at: url)
        }
        let files = monthFiles(in: root)
        guard files.count > monthsKept else { return }
        for url in files.prefix(files.count - monthsKept) {
            try? manager.removeItem(at: url)
        }
    }

    /// A month's records, from its plain file or its compressed one.
    private static func records(in url: URL) -> [RunRecord] {
        let manager = FileManager.default
        var data: Data?
        if manager.fileExists(atPath: url.path) {
            data = try? Data(contentsOf: url)
        } else {
            let compressed = url.appendingPathExtension(compressedExtension)
            data = (try? Data(contentsOf: compressed))
                .flatMap { try? ($0 as NSData).decompressed(using: .zlib) as Data }
        }
        guard let data else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(RunRecord.self, from: Data($0))
        }
    }

    /// Every month's file, oldest first — the names sort chronologically.
    private static func monthFiles(in root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".jsonl.\(compressedExtension)") }
            .sorted()
            .map { root.appendingPathComponent($0) }
    }

    /// Raw zlib, which `NSData` compresses and decompresses without a
    /// subprocess. A month of records is small; the compression is what keeps
    /// a year of them from being a year of files anyone has to think about.
    private static let compressedExtension = "z"

    private static func month(of date: Date) -> String {
        monthStamp.string(from: date)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// The month a file is named for, in local time: a month boundary is the
    /// one the person reading the directory lives in.
    private static let monthStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// A launch in progress and everything about the machine that was true when
/// it started. `Sendable` so closing one can leave the caller's actor: it
/// reads the tails of two logs, which is disk work.
nonisolated struct RunInProgress: Sendable {
    let started: ContinuousClock.Instant
    var record: RunRecord
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
        record.crash = WineExceptionTrail.lastException(in: wineTail)
        let notes = WineExceptionTrail.notes(in: wineTail)
        record.notes = notes.isEmpty ? nil : notes
        record.exit = RunRecord.Exit(
            kind: kind ?? Self.kind(
                code: exit?.code, crashed: record.crash != nil, steamError: steamError,
                unrecorded: unrecorded,
            ),
            code: exit?.code,
        )
        RunLog.append(record, in: runsRoot)
        RunRecorder.log("run recorded — \(record.summary)")
    }

    /// How a run ended, from what the client and Steam's log actually say.
    private static func kind(
        code: Int?, crashed: Bool, steamError: String?, unrecorded: RunRecord.Exit.Kind,
    ) -> RunRecord.Exit.Kind {
        if let code { return code == 0 && !crashed ? .user : .crash }
        if crashed { return .crash }
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

    /// A launch in progress and everything about the machine that was true
    /// when it started. `Sendable` so closing one can leave the main actor:
    /// it reads the tails of two logs, which is disk work.
    typealias OpenRun = RunInProgress

    init(
        runs: URL = RunLog.root,
        wineLog: URL = WineLog.fileURL,
        processLog: URL? = nil,
    ) {
        self.runs = runs
        self.wineLog = wineLog
        self.processLogOverride = processLog
    }

    /// A launch of `appID` has begun. Re-arming an app that is already open
    /// closes the old run: the client has told us a new one started, so
    /// whatever the old one did, it is over and nobody said how.
    func arm(appID: Int) {
        guard appID != 0 else { return }
        if open[appID] != nil { close(appID: appID, kind: .unknown) }
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
            renderer: selection.renderer.rawValue,
            runner: values.runner ?? GameRunner.wine,
            windows: GameConfig.windows(bottle: SteamBottle.name, game: appID).value.rawValue,
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
        if !hasGroomed {
            hasGroomed = true
            Task.detached(name: "Groom the run records") { [runs] in RunLog.groom(in: runs) }
        }
    }

    /// One of the launch's processes reached the Mac driver, named by the
    /// dock shim's chronicle.
    func noteExecutable(_ exe: String, forApp appID: Int) {
        guard open[appID]?.record.exe == nil else { return }
        open[appID]?.record.exe = exe
        persist(appID: appID)
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

    /// The client says the app is no longer running. The record is written on
    /// the closing queue: finishing it reads the tails of two logs, which is
    /// disk work the caller should not wait on.
    func close(appID: Int, kind: RunRecord.Exit.Kind? = nil) {
        guard let run = open.removeValue(forKey: appID) else { return }
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
        for run in open.values {
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

/// Steam's own record of the processes it started for a game
/// (`<Steam>/logs/gameprocess_log.txt`). It is where a game's exit status
/// exists: games are `CreateProcess`ed by `Steam.exe` inside the bottle, so
/// the app has no pid to wait on.
///
/// The pids in it are the bottle's Windows pids, which nothing on the macOS
/// side shares, so a process is identified by the executable of the command
/// line it was added with.
nonisolated enum SteamGameProcessLog {
    struct Exit: Equatable, Sendable {
        let pid: Int
        let code: Int
        /// The executable Steam started, lower case, when the line named one.
        let executable: String?
    }

    /// Crash handlers and reporters Steam tracks beside the game. They exit 0
    /// after the game they were watching has already died, so an exit taken
    /// from one of them says nothing about the run.
    static let helperExecutables = [
        "unitycrashhandler64.exe", "unitycrashhandler32.exe",
        "steamerrorreporter64.exe", "steamerrorreporter.exe",
    ]

    /// The exit that describes the run: the recorded executable's if it is
    /// there, otherwise the last that is not a crash handler's, otherwise the
    /// last of any.
    static func exit(forApp appID: Int, running exe: String?, in text: String) -> Exit? {
        let exits = exits(forApp: appID, in: text)
        if let exe = exe?.lowercased(),
           let match = exits.last(where: { $0.executable == exe }) { return match }
        if let match = exits.last(where: {
            $0.executable.map { !helperExecutables.contains($0) } ?? false
        }) { return match }
        return exits.last
    }

    /// Whether the log has this app in it at all. Steam rewrites the file at
    /// each client start, so an app with no line of its own belongs to a
    /// client session that is over.
    static func tracks(app appID: Int, in text: String) -> Bool {
        text.split(whereSeparator: \.isNewline)
            .contains { body(of: $0, forApp: appID) != nil }
    }

    /// Every process Steam stopped tracking for this app, in order, named by
    /// the command line it was added with.
    static func exits(forApp appID: Int, in text: String) -> [Exit] {
        var executables: [Int: String] = [:]
        var exits: [Exit] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let rest = body(of: line, forApp: appID) else { continue }
            if let match = rest.firstMatch(of: added) {
                executables[Int(match.output.1) ?? 0] = executable(fromCommandLine: match.output.2)
            } else if let match = rest.firstMatch(of: removed) {
                let pid = Int(match.output.1) ?? 0
                exits.append(
                    Exit(pid: pid, code: Int(match.output.2) ?? 0, executable: executables[pid]),
                )
            }
        }
        return exits
    }

    /// What the game is built on, told by the processes Steam tracked for it
    /// and by the game's own executable.
    static func runtime(forApp appID: Int, in text: String, exe: String?) -> String? {
        var names = exits(forApp: appID, in: text).compactMap(\.executable)
        if let exe { names.append(exe.lowercased()) }
        if names.contains(where: { $0.contains("unitycrashhandler") }) { return "unity" }
        if names.contains(where: { $0.contains("-win64-shipping") || $0.contains("-win32-shipping") }) {
            return "unreal"
        }
        return nil
    }

    /// The part of an `AppID <id> …` line after the app id, for this app.
    private static func body(of line: Substring, forApp appID: Int) -> Substring? {
        guard let start = line.range(of: "AppID \(appID) ") else { return nil }
        return line[start.upperBound...]
    }

    /// The executable of a tracked process's command line, which Steam wraps
    /// in quotes it also doubles.
    private static func executable(fromCommandLine command: Substring) -> String? {
        let unquoted = command.drop { $0 == "\"" }
        guard let end = unquoted.range(of: ".exe", options: .caseInsensitive) else { return nil }
        let path = unquoted[..<end.upperBound]
        let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last
        return name.map { $0.lowercased() }
    }

    // `nonisolated(unsafe)`: `Regex` is not `Sendable`, and a regex built from
    // a literal carries no transform that could hold state.
    private nonisolated(unsafe) static let added = /adding PID (\d+) as a tracked process (.*)/
    private nonisolated(unsafe) static let removed = /no longer tracking PID (\d+), exit code (-?\d+)/
}

/// What the Wine log gained during a run, read for the two things it can say
/// on its own: an unhandled exception, and the renderer complaining.
nonisolated enum WineExceptionTrail {
    /// The last unhandled exception in the text — the one that ended the
    /// process, since Wine terminates it on the spot.
    static func lastException(in text: String) -> RunRecord.Crash? {
        var found: RunRecord.Crash?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: unhandled) else { continue }
            found = RunRecord.Crash(
                code: "0x\(match.output.1)",
                flags: "0x\(match.output.2)",
                address: String(match.output.3),
                module: nil,
            )
        }
        return found
    }

    /// The renderer's own complaints, deduplicated with a count. DXMT writes
    /// these whatever `WINEDEBUG` says, and each one is a Direct3D call that
    /// did not do what the game asked.
    static func notes(in text: String) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let marker = markers.first(where: { line.contains($0) }) else { continue }
            let note = String(
                line[(line.range(of: marker)?.lowerBound ?? line.startIndex)...],
            ).trimmingCharacters(in: .whitespaces)
            if counts[note] == nil { order.append(note) }
            counts[note, default: 0] += 1
        }
        return order.prefix(maximumNotes).map { note in
            let count = counts[note] ?? 1
            return count > 1 ? "\(note) ×\(count)" : note
        }
    }

    private static let markers = ["Not supported feature:", "Shader not found?"]
    private static let maximumNotes = 8

    /// `dlls/ntdll/unix/thread.c`'s last word before it terminates the
    /// process; `err:seh` is in the always-on channels.
    private nonisolated(unsafe) static let unhandled =
        /Unhandled exception code ([0-9a-fA-F]+) flags ([0-9a-fA-F]+) addr (0x[0-9a-fA-F]+)/
}
