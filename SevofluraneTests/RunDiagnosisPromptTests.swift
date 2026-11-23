import Foundation
import Testing
@testable import Sevoflurane

/// When the panel about a run opens and when it stays shut, on the records
/// the recorder closes.
///
/// Serialized: several of these install `RunRecorder.didClose`, which is one static hook.
@MainActor
@Suite(.serialized)
struct RunDiagnosisPromptTests {
    private static func record(
        t: String = "2026-09-18T10:00:00Z",
        appid: Int = 508_440,
        exit: RunRecord.Exit? = RunRecord.Exit(kind: .crash, code: 1),
    ) -> RunRecord {
        RunRecord(
            t: t,
            appid: appid,
            name: "Totally Accurate Battle Simulator",
            engine: "dormison-r11",
            renderer: "dxmt",
            runner: "wine",
            windows: "fixed",
            msync: true,
            macos: "27.0",
            durationSeconds: 2.5,
            exit: exit,
            host: RunRecord.Host(thermal: "nominal", load: 1.2),
        )
    }

    /// A panel that counts what it would have shown.
    private final class Shown {
        var records: [RunRecord] = []
        var causes: [[RunDiagnosis.Cause]] = []
    }

    private static func prompt(
        defaults: UserDefaults = freshDefaults(), suggested: [SuggestedFix] = [],
    ) -> (RunDiagnosisPrompt, Shown) {
        let shown = Shown()
        let settings = InMemorySettingsEnvironment(seed: [.bottle(SteamBottle.name): ConfigValues()])
        let prompt = RunDiagnosisPrompt(defaults: defaults, settings: settings, suggested: { suggested }) {
            shown.records.append($0)
            shown.causes.append($1.map(\.cause))
        }
        return (prompt, shown)
    }

    /// Whether a panel opens for `record` with nothing muted.
    private static func raises(_ record: RunRecord) -> Bool {
        !RunDiagnosis.raised(RunDiagnosis.findings(for: record)).isEmpty
    }

    private static func freshDefaults() -> UserDefaults {
        let suite = "RunDiagnosisPromptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test
    func `a crash and a watchdog kill are the endings that prompt`() {
        #expect(Self.raises(Self.record(exit: RunRecord.Exit(kind: .crash, code: 1))))
        #expect(Self.raises(Self.record(exit: RunRecord.Exit(kind: .crash, code: nil))))
        #expect(Self.raises(Self.record(exit: RunRecord.Exit(kind: .watchdog, code: nil))))
        for kind in [
            RunRecord.Exit.Kind.user, .crashAtExit, .stopped, .stoppedByTool, .steamTerminate, .appQuit, .unknown,
            .endedNotResponding,
        ] {
            #expect(!Self.raises(Self.record(exit: RunRecord.Exit(kind: kind, code: 0))))
        }
        #expect(!Self.raises(Self.record(exit: nil)))
    }

    @Test
    func `exit status 1 eight seconds in with no window is offered as a quit while starting`() {
        var record = Self.record(exit: RunRecord.Exit(kind: .exitError, code: 1))
        record.durationSeconds = 8
        #expect(Self.raises(record))
        let (prompt, shown) = Self.prompt()
        #expect(prompt.offer(record))
        #expect(shown.records.count == 1)
        #expect(shown.causes == [[.quitWhileStarting]])
        #expect(RunDiagnosis.findings(for: record).first?.sentence
            == "Totally Accurate Battle Simulator quit with an error while starting.")
        // A window shown, but gone again within the first seconds, is still starting.
        record.windowAfterSeconds = 3
        #expect(Self.raises(record))
    }

    @Test
    func `exit status 1 after ten minutes of play is never mentioned`() {
        var record = Self.record(exit: RunRecord.Exit(kind: .exitError, code: 1))
        record.windowAfterSeconds = 4
        record.durationSeconds = 600
        #expect(!Self.raises(record))
        let (prompt, shown) = Self.prompt()
        #expect(!prompt.offer(record))
        #expect(shown.records.isEmpty)
    }

    @Test
    func `a crash keeps the crash wording and opens on the report`() {
        let record = Self.record()
        let findings = RunDiagnosis.findings(for: record)
        #expect(findings.first?.sentence == "Totally Accurate Battle Simulator stopped unexpectedly.")
        let model = RunDiagnosisModel(
            record: record, findings: findings,
            report: ReportSendModel(record: record, upload: ReportUpload(installToken: "t", version: "1+1")),
            defaults: Self.freshDefaults(), settings: InMemorySettingsEnvironment(), ledger: nil,
        )
        #expect(model.face == .report)
        #expect(model.opensOnReport)
        #expect(!model.canStopAsking)
    }

    @Test
    func `never ask again on the report turns the report's panel off`() {
        let defaults = Self.freshDefaults()
        let record = Self.record()
        let model = RunDiagnosisModel(
            record: record, findings: RunDiagnosis.findings(for: record),
            report: ReportSendModel(record: record, upload: ReportUpload(installToken: "t", version: "1+1")),
            defaults: defaults, settings: InMemorySettingsEnvironment(), ledger: nil,
        )
        var finished = 0
        model.onFinish = { finished += 1 }
        model.report.neverAskAgain = true
        model.dismiss()
        #expect(finished == 1)
        #expect(!Preferences.asksAfterCrash(in: defaults))
        let (prompt, shown) = Self.prompt(defaults: defaults)
        #expect(!prompt.offer(Self.record(t: "2026-09-18T11:00:00Z")))
        #expect(shown.records.isEmpty)
    }

    @Test
    func `a suggested fix leads the panel of a crashed run, with the crash left to it`() {
        let suggestion = SuggestedFix(
            fix: KnownFix(
                appID: 508_440, exePattern: nil, title: "TABS", values: ConfigValues(renderer: .d3dmetal),
                reason: "Measured.",
            ),
            evidence: FixEvidence(
                macs: 2, without: .init(values: ConfigValues(renderer: .dxmt), runs: 15, failed: 11),
                with: .init(values: nil, runs: 6, failed: 0),
            ),
        )
        let (prompt, shown) = Self.prompt(suggested: [suggestion])
        #expect(prompt.offer(Self.record()))
        #expect(shown.causes == [[.suggestedFix]])
        // A run that ended well reads no suggestion.
        #expect(!prompt.offer(Self.record(t: "2026-09-18T12:00:00Z", exit: RunRecord.Exit(kind: .user, code: 0))))
    }

    @Test
    func `a run that exited normally is never mentioned`() {
        let (prompt, shown) = Self.prompt()
        #expect(!prompt.offer(Self.record(exit: RunRecord.Exit(kind: .user, code: 0))))
        #expect(shown.records.isEmpty)
    }

    @Test
    func `a crash is offered once per run, and another run is another offer`() {
        let (prompt, shown) = Self.prompt()
        let run = Self.record()
        #expect(prompt.offer(run))
        #expect(!prompt.offer(run))
        #expect(prompt.offer(Self.record(t: "2026-09-18T10:05:00Z")))
        #expect(prompt.offer(Self.record(appid: 1_250_650)))
        #expect(shown.records.count == 3)
    }

    @Test
    func `never ask again is honored`() {
        let defaults = Self.freshDefaults()
        #expect(Preferences.asksAfterCrash(in: defaults))
        defaults.set(false, forKey: Preferences.asksAfterCrashKey)
        let (prompt, shown) = Self.prompt(defaults: defaults)
        #expect(!prompt.offer(Self.record()))
        #expect(shown.records.isEmpty)
    }

    @Test
    func `the panel names the game and the known failure`() {
        var record = Self.record()
        record.runtime = "unity"
        let first = RunDiagnosis.findings(for: record).first
        #expect(first?.cause == .unityStartup)
        #expect(first?.sentence == "Totally Accurate Battle Simulator failed while starting and never drew a window.")
        #expect(first?.evidence.contains("Player.log") == true)
    }

    /// The hook the app installs, exercised through the recorder that fires
    /// it: a launch whose process left with a non-zero status is closed as a
    /// crash, and the closing tells the prompt.
    @Test
    func `the recorder tells the prompt when a run closes as a crash`() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("crash-prompt-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let wine = root.appendingPathComponent("wine.log")
        try Data().write(to: wine)
        let processLog = root.appendingPathComponent("gameprocess_log.txt")

        let appID = 413_150
        let closed = Closed()
        let previous = RunRecorder.didClose
        defer { RunRecorder.didClose = previous }
        RunRecorder.didClose = { closed.append($0) }

        // Armed first, so the log Steam writes during the run is the tail the
        // closing reads — the order a real launch happens in.
        RunRecorder(runs: root, wineLog: wine, processLog: processLog).arm(appID: appID)
        try Data("""
        [2026-09-18 03:10:01] AppID 413150 adding PID 1400 as a tracked process ""C:\\game.exe""
        [2026-09-18 03:11:42] AppID 413150 no longer tracking PID 1400, exit code 3
        
        """.utf8).write(to: processLog)
        // The exception is what makes it a crash; the exit status alone would not.
        try Data("0128:err:seh:NtRaiseException Unhandled exception code c0000005 flags 0 addr 0x43a1c0\n".utf8)
            .write(to: wine)
        RunRecorder(runs: root, wineLog: wine, processLog: processLog).reattach()

        var record: RunRecord?
        for _ in 0 ..< 100 {
            if let mine = closed.first(forApp: appID) { record = mine; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let crashed = try #require(record)
        #expect(crashed.exit?.kind == .crash)
        #expect(crashed.exit?.code == 3)

        let (prompt, shown) = Self.prompt()
        #expect(prompt.offer(crashed))
        #expect(shown.records.count == 1)
    }

    /// The game's exception after the engine saw it close its windows is a
    /// crash on the way out; before, it is a crash. Both orders, through the
    /// recorder, as a launch writes them.
    @Test(arguments: [(413_153, true, RunRecord.Exit.Kind.crashAtExit), (413_154, false, .crash)])
    func `a crash after the game closed its windows is recorded as one on the way out`(
        appID: Int, closedFirst: Bool, expected: RunRecord.Exit.Kind,
    ) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("crash-prompt-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let wine = root.appendingPathComponent("wine.log")
        try Data().write(to: wine)
        let processLog = root.appendingPathComponent("gameprocess_log.txt")
        let closed = Closed()
        let previous = RunRecorder.didClose
        defer { RunRecorder.didClose = previous }
        RunRecorder.didClose = { closed.append($0) }

        RunRecorder(runs: root, wineLog: wine, processLog: processLog).arm(appID: appID)
        try Data("""
        [2026-09-26 00:26:01] AppID \(appID) adding PID 1400 as a tracked process ""C:\\game.exe""
        [2026-09-26 00:31:19] AppID \(appID) no longer tracking PID 1400, exit code -1073740791
        
        """.utf8).write(to: processLog)
        let marker = "sevo:exit pid=27651 wpid=0288 windows closed"
        let exception = "0288:0214:err:seh:NtRaiseException Unhandled exception code c0000409 flags 1 addr 0x6ffffdd96eb9"
        let trail = ["sevo:run pid=27651 exe=game.exe appid=\(appID) engine=dormison-r18"]
            + (closedFirst ? [marker, exception] : [exception, marker])
        try Data((trail.joined(separator: "\n") + "\n").utf8).write(to: wine)
        RunRecorder(runs: root, wineLog: wine, processLog: processLog).reattach()

        var record: RunRecord?
        for _ in 0 ..< 100 {
            if let mine = closed.first(forApp: appID) { record = mine; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let ended = try #require(record)
        #expect(ended.exit?.kind == expected)
        #expect(ended.crash?.code == "0xc0000409")
        #expect(Self.raises(ended) == (expected == .crash))
    }

    @Test(arguments: [
        (413_151, RunLog.StopSource?.some(.player), RunRecord.Exit.Kind.stopped),
        (413_153, .some(.tool), .stoppedByTool),
        (413_152, nil, .exitError),
    ])
    func `exit status 1 without an exception is a stop or an error, never a crash`(
        appID: Int, stopAsked: RunLog.StopSource?, expected: RunRecord.Exit.Kind,
    ) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("crash-prompt-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let wine = root.appendingPathComponent("wine.log")
        try Data().write(to: wine)
        let processLog = root.appendingPathComponent("gameprocess_log.txt")
        let closed = Closed()
        let previous = RunRecorder.didClose
        defer { RunRecorder.didClose = previous }
        RunRecorder.didClose = { closed.append($0) }

        RunRecorder(runs: root, wineLog: wine, processLog: processLog).arm(appID: appID)
        try Data("""
        [2026-09-18 03:10:01] AppID \(appID) adding PID 1400 as a tracked process ""C:\\game.exe""
        [2026-09-18 03:11:42] AppID \(appID) no longer tracking PID 1400, exit code 1
        
        """.utf8).write(to: processLog)
        if let stopAsked { RunLog.noteStopRequest(forApp: appID, by: stopAsked, in: root) }
        RunRecorder(runs: root, wineLog: wine, processLog: processLog).reattach()

        var record: RunRecord?
        for _ in 0 ..< 100 {
            if let mine = closed.first(forApp: appID) { record = mine; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let ended = try #require(record)
        #expect(ended.exit?.kind == expected)
        #expect(ended.crash == nil)
        // The error exit never showed a window, so it is offered as a quit
        // while starting; a stop never is.
        #expect(Self.raises(ended) == (expected == .exitError))
    }

    /// A game whose own crash handler exited with status 1 after the engine
    /// saw the exception: the line from a built engine, paired with the game
    /// by the `wpid=` of its `sevo:run` line.
    @Test
    func `a sevo crash line makes an exit status 1 a crash`() async throws {
        let ended = try await Self.close(appID: 413_170, exitCode: 1, wineLog: """
        sevo:run pid=77176 exe=crash.exe appid=413170 engine=dormison-r1 swift=d5fec381986d7002 wpid=0a3c
        sevo:crash wpid=0a3c code=c0000005 addr=00000001400014FE module=crash.exe
        """)
        #expect(ended.exit?.kind == .crash)
        #expect(ended.exit?.code == 1)
        #expect(ended.crash == RunRecord.Crash(code: "0xc0000005", address: "0x1400014fe", module: "crash.exe"))
        #expect(Self.raises(ended))
    }

    @Test
    func `another process's sevo crash line is not the game's`() async throws {
        let ended = try await Self.close(appID: 413_171, exitCode: 1, wineLog: """
        sevo:run pid=77176 exe=crash.exe appid=413171 engine=dormison-r1 swift=d5fec381986d7002 wpid=0a3c
        sevo:crash wpid=0b10 code=c0000005 addr=00000001400014FE module=UnityCrashHandler64.exe
        """)
        #expect(ended.exit?.kind == .exitError)
        #expect(ended.crash == nil)
    }

    /// The line Wine writes as it starts the debugger, the one sign an engine
    /// without `sevo:crash` leaves when the game's own filter exits first.
    @Test
    func `wine's unhandled page fault line makes an exit status 1 a crash`() async throws {
        let ended = try await Self.close(appID: 413_172, exitCode: 1, wineLog: """
        wine: Unhandled page fault on read access to 0000000000000010 at address 0x1400123A (thread 0124), \
        starting debugger...
        """)
        #expect(ended.exit?.kind == .crash)
        #expect(ended.crash?.code == "0xc0000005")
        #expect(ended.crash?.address == "0x1400123A")
        #expect(Self.raises(ended))
    }

    @Test
    func `an exception status as the exit code is a crash with that status`() async throws {
        let ended = try await Self.close(appID: 413_173, exitCode: -1_073_741_819, wineLog: "")
        #expect(ended.exit?.kind == .crash)
        #expect(ended.exit?.code == -1_073_741_819)
        #expect(ended.crash == RunRecord.Crash(code: "0xc0000005"))
        #expect(Self.raises(ended))
    }

    @Test
    func `an exception status after the game closed its windows is a crash on the way out`() async throws {
        let ended = try await Self.close(appID: 413_174, exitCode: -1_073_740_791, wineLog: """
        sevo:run pid=27651 exe=game.exe appid=413174 engine=dormison-r18 wpid=0288
        sevo:exit pid=27651 wpid=0288 windows closed
        """)
        #expect(ended.exit?.kind == .crashAtExit)
        #expect(ended.crash?.code == "0xc0000409")
        #expect(!Self.raises(ended))
    }

    @Test(arguments: [
        (-1_073_741_819, String?.some("0xc0000005")), (3_221_225_477, "0xc0000005"), (-1_073_740_791, "0xc0000409"),
        (-1, nil), (-1_073_741_510, nil), (1, nil), (3, nil), (0x4000_0000, nil),
    ])
    func `exit codes that are exception statuses`(code: Int, status: String?) {
        #expect(RunInProgress.exceptionStatus(code) == status)
    }

    /// Arms a run, lets Steam record `exitCode` with `wineLog` as what the
    /// Wine log gained, and answers the record the recorder closed.
    private static func close(appID: Int, exitCode: Int, wineLog: String) async throws -> RunRecord {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("crash-prompt-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let wine = root.appendingPathComponent("wine.log")
        try Data().write(to: wine)
        let processLog = root.appendingPathComponent("gameprocess_log.txt")
        let closed = Closed()
        let previous = RunRecorder.didClose
        defer { RunRecorder.didClose = previous }
        RunRecorder.didClose = { closed.append($0) }

        RunRecorder(runs: root, wineLog: wine, processLog: processLog).arm(appID: appID)
        try Data("""
        [2026-09-28 03:10:01] AppID \(appID) adding PID 1400 as a tracked process ""C:\\crash.exe""
        [2026-09-28 03:10:09] AppID \(appID) no longer tracking PID 1400, exit code \(exitCode)
        
        """.utf8).write(to: processLog)
        try Data((wineLog + "\n").utf8).write(to: wine)
        RunRecorder(runs: root, wineLog: wine, processLog: processLog).reattach()

        for _ in 0 ..< 100 {
            if let mine = closed.first(forApp: appID) { return mine }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return try #require(closed.first(forApp: appID))
    }

    /// The records the recorder's hook handed over, from whichever queue it
    /// fired on.
    private final class Closed: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [RunRecord] = []

        func append(_ record: RunRecord) {
            lock.withLock { records.append(record) }
        }

        /// Only this test's own run. `RunRecorder.didClose` is one hook for
        /// the whole process, so while this test holds it every suite closing
        /// a run in parallel arrives here too; the app id is what tells them
        /// apart.
        func first(forApp appID: Int) -> RunRecord? {
            lock.withLock { records.first { $0.appid == appID } }
        }
    }

    @Test
    func `a run that ended on a missing library keeps its name and says so`() async throws {
        let ended = try await Self.close(appID: 413_175, exitCode: -1_073_741_515, wineLog: #"""
        sevo:run pid=27651 exe=crash.exe appid=413175 engine=dormison-r18 wpid=0288
        0288:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\game\\crash.exe") not found
        """#)
        #expect(ended.exit?.kind == .crash)
        #expect(ended.missingDLL == "MSVCP140.dll")
        #expect(ended.driver == nil)
        #expect(RunDiagnosis.findings(for: ended).map(\.cause) == [.missingLibrary])
    }

    @Test
    func `a run that drew nothing after its kernel driver failed keeps the driver and says so`() async throws {
        let ended = try await Self.close(appID: 413_176, exitCode: 1, wineLog: #"""
        sevo:run pid=27651 exe=crash.exe appid=413176 engine=dormison-r18 wpid=0288
        0124:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Driver\\EasyAntiCheat": c0000142
        """#)
        #expect(ended.driver == "EasyAntiCheat.sys")
        #expect(RunDiagnosis.findings(for: ended).map(\.cause) == [.kernelDriver])
        let (prompt, shown) = Self.prompt()
        #expect(prompt.offer(ended))
        #expect(shown.causes == [[.kernelDriver]])

        let drew = try await Self.close(appID: 413_177, exitCode: 1, wineLog: #"""
        sevo:run pid=27651 exe=crash.exe appid=413177 engine=dormison-r18 wpid=0288
        0124:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Driver\\EasyAntiCheat": c0000142
        sevo:gfx pid=27651 first present +5210ms surface=0x1 layer=on-screen
        """#)
        #expect(drew.driver == nil)
    }

    @Test
    func `the helper's word of a failed driver goes into the open run, and nowhere without one`() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("run-diagnosis-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let wine = root.appendingPathComponent("wine.log")
        try Data().write(to: wine)
        let recorder = RunRecorder(runs: root, wineLog: wine, processLog: root.appendingPathComponent("p.txt"))
        #expect(recorder.noteKernelDriver("HoYoKProtect.sys", forApp: 413_178) == nil)
        recorder.arm(appID: 413_178)
        let open = try #require(recorder.noteKernelDriver("HoYoKProtect.sys", forApp: 413_178))
        #expect(open.driver == "HoYoKProtect.sys")
        #expect(open.exit == nil)
        #expect(RunDiagnosis.findings(for: open).map(\.cause) == [.kernelDriver])
        #expect(RunLog.armedRuns(in: root).first?.record.driver == "HoYoKProtect.sys")
    }

    @Test
    func `the install token is made once and kept`() {
        let defaults = Self.freshDefaults()
        let first = Preferences.installToken(in: defaults)
        #expect(first.count == 32)
        #expect(Preferences.installToken(in: defaults) == first)
        #expect(Preferences.installToken(in: Self.freshDefaults()) != first)
    }
}
