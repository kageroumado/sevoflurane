import Darwin
import Foundation
import Testing
@testable import Sevoflurane

/// A game that keeps a worker spinning on every processor: how its busy threads
/// are counted, what a run keeps of them, and when the app offers to limit the
/// processors it sees.
@MainActor
struct ThreadSpinTests {
    private let manager = FileManager.default

    private static func record(
        t: String = "2026-09-28T10:00:00Z",
        appid: Int = 310_360,
        threads: RunRecord.Threads? = RunRecord.Threads(busy: 15, processors: 16, samples: 30),
        durationSeconds: Double = 600,
        exit: RunRecord.Exit = RunRecord.Exit(kind: .user, code: 0),
    ) -> RunRecord {
        RunRecord(
            t: t,
            appid: appid,
            name: "Higurashi Hou",
            engine: "dormison-r20",
            renderer: "dxmt",
            runner: "wine",
            windows: "fixed",
            msync: true,
            macos: "27.0",
            durationSeconds: durationSeconds,
            exit: exit,
            threads: threads,
            host: RunRecord.Host(thermal: "nominal", load: 1.2),
        )
    }

    private static func freshDefaults() -> UserDefaults {
        let suite = "ThreadSpinTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A settings store whose game level says `processors`, for every game these tests use.
    private static func settings(processors: Int? = 0) -> InMemorySettingsEnvironment {
        var values = ConfigValues()
        values.processors = processors
        return InMemorySettingsEnvironment(seed: [
            .game(310_360, bottle: SteamBottle.name): values,
            .game(508_440, bottle: SteamBottle.name): values,
        ])
    }

    /// A panel that counts the causes it would have shown.
    private final class Shown {
        var causes: [[RunDiagnosis.Cause]] = []
    }

    private static func prompt(
        defaults: UserDefaults = freshDefaults(), settings: InMemorySettingsEnvironment = settings(),
    ) -> (RunDiagnosisPrompt, Shown) {
        let shown = Shown()
        let prompt = RunDiagnosisPrompt(defaults: defaults, settings: settings, suggested: { [] }) {
            shown.causes.append($1.map(\.cause))
        }
        return (prompt, shown)
    }

    private static func model(
        _ record: RunRecord, defaults: UserDefaults = freshDefaults(),
        settings: InMemorySettingsEnvironment = settings(), ledger: URL? = nil,
    ) -> RunDiagnosisModel {
        RunDiagnosisModel(
            record: record,
            findings: RunDiagnosis.findings(for: record, in: RunDiagnosis.Context(current: ConfigValues(processors: 0))),
            defaults: defaults, settings: settings, ledger: ledger,
        )
    }

    // MARK: - Counting

    @Test
    func `a thread at sixty per cent of a core or more is busy`() {
        #expect(ThreadActivity.busyCount([890, 770, 600, 599, 0, 12]) == 3)
        #expect(ThreadActivity.busyCount([]) == 0)
        #expect(ThreadActivity.busyCount([1000, 1000], threshold: 1001) == 0)
    }

    @Test
    func `this process's threads can be listed and read`() throws {
        let usages = try #require(ThreadActivity.usages(pid: getpid()))
        #expect(!usages.isEmpty)
        #expect(usages.allSatisfy { $0 >= 0 })
        #expect(ThreadActivity.busyThreads(pid: pid_t.max) == nil)
    }

    // MARK: - What a run keeps

    @Test
    func `a run keeps the median of its focused samples once it has five`() throws {
        #expect(RunRecord.Threads(samples: [15, 14, 15, 15], processors: 16) == nil)
        let odd = try #require(RunRecord.Threads(samples: [15, 2, 14, 15, 16], processors: 16))
        #expect(odd.busy == 15)
        #expect(odd.samples == 5)
        #expect(odd.processors == 16)
        let even = try #require(RunRecord.Threads(samples: [1, 2, 3, 4, 5, 6], processors: 10))
        #expect(even.busy == 4)
    }

    @Test
    func `the busy threads survive a round trip and stay out of the shared run`() throws {
        let record = Self.record()
        let encoded = try JSONEncoder().encode(record)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let threads = try #require(json["threads"] as? [String: Any])
        #expect(threads["busy"] as? Int == 15)
        #expect(threads["processors"] as? Int == 16)
        #expect(threads["samples"] as? Int == 30)
        #expect(try JSONDecoder().decode(RunRecord.self, from: encoded) == record)

        let shared = try #require(SharedRun(record: record, appVersion: "1.0 (1)"))
        let sharedJSON = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as? [String: Any],
        )
        #expect(sharedJSON["threads"] == nil)
    }

    @Test
    func `the summary names busy threads from three`() {
        #expect(RunRecord.Threads(busy: 15, processors: 16, samples: 9).summary == "15 busy threads")
        #expect(RunRecord.Threads(busy: 2, processors: 16, samples: 9).summary == nil)
    }

    @Test
    func `the recorder counts busy threads only while the game has focus`() async throws {
        let root = manager.temporaryDirectory.appendingPathComponent("thread-spin-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let wine = root.appendingPathComponent("wine.log")
        try Data().write(to: wine)
        let recorder = RunRecorder(
            runs: root, wineLog: wine, processLog: root.appendingPathComponent("gameprocess_log.txt"),
        )
        let appID = 310_361
        recorder.arm(appID: appID)
        recorder.noteExecutable("higurashihou.exe", pid: getpid(), forApp: appID)
        let focused = GameObservation(focus: .focused, display: nil)
        let background = GameObservation(focus: .background, display: nil)
        for busy in [15, 14, 15, 16, 15] {
            recorder.sample(observing: { _ in focused }, busyThreads: { _ in busy })
        }
        recorder.sample(observing: { _ in background }, busyThreads: { _ in 0 })
        recorder.sample(observing: { _ in background }, busyThreads: { _ in 0 })
        recorder.close(appID: appID)

        var records: [RunRecord] = []
        for _ in 0 ..< 100 {
            records = RunLog.records(inMonth: .now, in: root)
            if !records.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let threads = try #require(records.first?.threads)
        #expect(threads.busy == 15)
        #expect(threads.samples == 5)
        #expect(threads.processors > 0)
        #expect(threads.processors <= ProcessInfo.processInfo.activeProcessorCount)
    }

    // MARK: - The diagnosis

    @Test
    func `fifteen busy of sixteen suggests eight`() {
        let suggestion = ThreadSpinDiagnosis.suggestion(for: Self.record(), currentCap: nil)
        #expect(suggestion == ThreadSpinDiagnosis.Suggestion(busy: 15, processors: 16, cap: 8))
    }

    @Test
    func `six busy of ten suggests five`() {
        let record = Self.record(threads: RunRecord.Threads(busy: 6, processors: 10, samples: 30))
        #expect(ThreadSpinDiagnosis.suggestion(for: record, currentCap: 0)?.cap == 5)
    }

    @Test
    func `quiet threads suggest nothing`() {
        let quiet = Self.record(threads: RunRecord.Threads(busy: 0, processors: 10, samples: 30))
        #expect(ThreadSpinDiagnosis.suggestion(for: quiet, currentCap: nil) == nil)
        let few = Self.record(threads: RunRecord.Threads(busy: 6, processors: 24, samples: 30))
        #expect(ThreadSpinDiagnosis.suggestion(for: few, currentCap: nil) == nil)
        #expect(ThreadSpinDiagnosis.suggestion(for: Self.record(threads: nil), currentCap: nil) == nil)
    }

    @Test
    func `a game with a cap or a short run is left alone`() {
        #expect(ThreadSpinDiagnosis.suggestion(for: Self.record(), currentCap: 8) == nil)
        let short = Self.record(threads: RunRecord.Threads(busy: 15, processors: 16, samples: 9))
        #expect(ThreadSpinDiagnosis.suggestion(for: short, currentCap: nil) == nil)
        // The samples decide, whatever the frame trace counted as gameplay.
        let measured = Self.record(threads: RunRecord.Threads(busy: 15, processors: 16, samples: 23), durationSeconds: 25)
        #expect(ThreadSpinDiagnosis.suggestion(for: measured, currentCap: nil)?.cap == 8)
    }

    @Test
    func `the cap is half the processors, from two to eight`() {
        #expect(ThreadSpinDiagnosis.cap(for: 32) == 8)
        #expect(ThreadSpinDiagnosis.cap(for: 12) == 6)
        #expect(ThreadSpinDiagnosis.cap(for: 3) == 2)
    }

    // MARK: - The offer

    @Test
    func `a spinning run that ended normally opens the panel once`() {
        let (prompt, shown) = Self.prompt()
        let run = Self.record()
        #expect(prompt.offer(run))
        #expect(!prompt.offer(run))
        #expect(shown.causes == [[.threadSpin]])
    }

    @Test
    func `a crash leads the panel and the processor limit is a row under it`() {
        let (prompt, shown) = Self.prompt()
        let run = Self.record(exit: RunRecord.Exit(kind: .crash, code: 3))
        #expect(prompt.offer(run))
        #expect(!prompt.offer(run))
        #expect(shown.causes == [[.crashed, .threadSpin]])
    }

    @Test
    func `a game already capped is not offered`() {
        let (prompt, shown) = Self.prompt(settings: Self.settings(processors: 8))
        #expect(!prompt.offer(Self.record()))
        #expect(shown.causes.isEmpty)
    }

    @Test
    func `don't show this again mutes the cause for this game and keeps it for others`() {
        let defaults = Self.freshDefaults()
        let model = Self.model(Self.record(), defaults: defaults)
        #expect(model.face == .findings)
        #expect(model.canStopAsking)
        model.stopsAsking = true
        model.notNow()
        #expect(Preferences.quietCauses(forApp: 310_360, in: defaults) == [.threadSpin])
        #expect(Preferences.quietCauses(forApp: 508_440, in: defaults).isEmpty)

        let (prompt, shown) = Self.prompt(defaults: defaults)
        #expect(!prompt.offer(Self.record()))
        #expect(prompt.offer(Self.record(appid: 508_440)))
        #expect(shown.causes.count == 1)
    }

    @Test
    func `not now without the mute changes nothing`() {
        let defaults = Self.freshDefaults()
        let settings = Self.settings()
        let model = Self.model(Self.record(), defaults: defaults, settings: settings)
        var finished = 0
        model.onFinish = { finished += 1 }
        model.dismiss()
        #expect(finished == 1)
        #expect(Preferences.quietCauses(forApp: 310_360, in: defaults).isEmpty)
        #expect(settings.updates.isEmpty)
    }

    @Test
    func `limiting writes the cap into the game's own settings, where Undo finds it`() throws {
        let ledger = manager.temporaryDirectory.appendingPathComponent("thread-spin-ledger-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: ledger) }
        let settings = Self.settings()
        var finished = false
        let model = Self.model(Self.record(), settings: settings, ledger: ledger)
        model.onFinish = { finished = true }
        #expect(model.headline.sentence == "Higurashi Hou kept 15 threads busy the whole time, which slows its picture.")
        #expect(model.headline.action?.label == "Limit to 8 Processors")
        model.perform(model.headline)
        let scope = SettingScope.game(310_360, bottle: SteamBottle.name)
        #expect(settings.values(scope).processors == 8)
        #expect(finished)
        #expect(model.taken == [.threadSpin])

        let recorded = try #require(FixLedger.record(for: 310_360, in: ledger))
        #expect(recorded.applied.processors == 8)
        #expect(recorded.previous.processors == 0)
        #expect(recorded.fixes.map(\.title) == ["Processor limit"])
        let undone = FixLedger.undo(recorded, own: settings.values(scope))
        #expect(undone.values.processors == 0)
    }

    @Test
    func `sending the report from a finding comes back to the finding`() {
        let model = Self.model(Self.record())
        var finished = 0
        model.onFinish = { finished += 1 }
        model.showReport()
        #expect(model.face == .report)
        // Escape on the report is Don't Send, which leaves the finding to answer.
        model.dismiss()
        #expect(model.face == .findings)
        #expect(finished == 0)
        model.dismiss()
        #expect(finished == 1)
    }
}
