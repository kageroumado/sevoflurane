import Foundation
import Testing
@testable import Sevoflurane

/// When the app speaks up after a run, and when it holds its tongue.
@MainActor
struct CrashPromptTests {
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

    /// A prompt that counts what it would have shown.
    private final class Shown {
        var records: [RunRecord] = []
    }

    private static func prompt(defaults: UserDefaults = freshDefaults()) -> (CrashPrompt, Shown) {
        let shown = Shown()
        let prompt = CrashPrompt(defaults: defaults) { shown.records.append($0) }
        return (prompt, shown)
    }

    private static func freshDefaults() -> UserDefaults {
        let suite = "CrashPromptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test
    func `a crash and a watchdog kill are the endings that prompt`() {
        #expect(CrashPromptPolicy.deserves(Self.record(exit: RunRecord.Exit(kind: .crash, code: 1))))
        #expect(CrashPromptPolicy.deserves(Self.record(exit: RunRecord.Exit(kind: .crash, code: nil))))
        #expect(CrashPromptPolicy.deserves(Self.record(exit: RunRecord.Exit(kind: .watchdog, code: nil))))
        for kind in [RunRecord.Exit.Kind.user, .steamTerminate, .appQuit, .unknown] {
            #expect(!CrashPromptPolicy.deserves(Self.record(exit: RunRecord.Exit(kind: kind, code: 0))))
        }
        #expect(!CrashPromptPolicy.deserves(Self.record(exit: nil)))
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
        let model = CrashPromptModel(record: record, upload: ReportUpload(installToken: "t", version: "1+1"))
        #expect(model.title == "Totally Accurate Battle Simulator stopped unexpectedly.")
        #expect(model.known?.id == "unity-exit-1-no-window")
        #expect(model.knownSentence?.contains("Player.log") == true)
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

        let closed = Closed()
        let previous = RunRecorder.didClose
        defer { RunRecorder.didClose = previous }
        RunRecorder.didClose = { closed.append($0) }

        // Armed first, so the log Steam writes during the run is the tail the
        // closing reads — the order a real launch happens in.
        RunRecorder(runs: root, wineLog: wine, processLog: processLog).arm(appID: 367_520)
        try Data("""
        [2026-09-18 03:10:01] AppID 367520 adding PID 1400 as a tracked process ""C:\\game.exe""
        [2026-09-18 03:11:42] AppID 367520 no longer tracking PID 1400, exit code 3
        
        """.utf8).write(to: processLog)
        RunRecorder(runs: root, wineLog: wine, processLog: processLog).reattach()

        var record: RunRecord?
        for _ in 0 ..< 100 {
            if let first = closed.first { record = first; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let crashed = try #require(record)
        #expect(crashed.exit?.kind == .crash)
        #expect(crashed.exit?.code == 3)

        let (prompt, shown) = Self.prompt()
        #expect(prompt.offer(crashed))
        #expect(shown.records.count == 1)
    }

    /// The records the recorder's hook handed over, from whichever queue it
    /// fired on.
    private final class Closed: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [RunRecord] = []

        func append(_ record: RunRecord) {
            lock.withLock { records.append(record) }
        }

        var first: RunRecord? {
            lock.withLock { records.first }
        }
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
