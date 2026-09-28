import Darwin
import Foundation
import Testing
@testable import Sevoflurane

/// A game that keeps a worker spinning on every processor: how its busy threads
/// are counted, what a run keeps of them, and when the app offers to limit the
/// processors it sees.
///
/// Serialized: one test installs `RunRecorder.didClose`, which is one static hook.
@MainActor
@Suite(.serialized)
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

    /// Prompts that count what they would have shown.
    private final class Shown {
        var crashes: [RunRecord] = []
        var spins: [ThreadSpinDiagnosis.Suggestion] = []
    }

    private static func prompts(
        defaults: UserDefaults = freshDefaults(), settings: InMemorySettingsEnvironment = settings(),
    ) -> (CrashPrompt, ThreadSpinPrompt, Shown) {
        let shown = Shown()
        let crash = CrashPrompt(defaults: defaults) { shown.crashes.append($0) }
        let spin = ThreadSpinPrompt(defaults: defaults, settings: settings) { shown.spins.append($1) }
        return (crash, spin, shown)
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
    func `a game with a cap, a short run, or a game asked about is left alone`() {
        #expect(ThreadSpinDiagnosis.suggestion(for: Self.record(), currentCap: 8) == nil)
        let short = Self.record(threads: RunRecord.Threads(busy: 15, processors: 16, samples: 9))
        #expect(ThreadSpinDiagnosis.suggestion(for: short, currentCap: nil) == nil)
        // The samples decide, whatever the frame trace counted as gameplay.
        let measured = Self.record(threads: RunRecord.Threads(busy: 15, processors: 16, samples: 23), durationSeconds: 25)
        #expect(ThreadSpinDiagnosis.suggestion(for: measured, currentCap: nil)?.cap == 8)
        #expect(ThreadSpinDiagnosis.suggestion(for: Self.record(), currentCap: nil, asks: false) == nil)
    }

    @Test
    func `the cap is half the processors, from two to eight`() {
        #expect(ThreadSpinDiagnosis.cap(for: 32) == 8)
        #expect(ThreadSpinDiagnosis.cap(for: 12) == 6)
        #expect(ThreadSpinDiagnosis.cap(for: 3) == 2)
    }

    // MARK: - The offer

    @Test
    func `a spinning run that ended normally opens the offer once`() {
        let (crash, spin, shown) = Self.prompts()
        let run = Self.record()
        crash.offerAfterClose(run, spin: spin)
        crash.offerAfterClose(run, spin: spin)
        #expect(shown.crashes.isEmpty)
        #expect(shown.spins == [ThreadSpinDiagnosis.Suggestion(busy: 15, processors: 16, cap: 8)])
    }

    @Test
    func `a crash takes the run, on its first closing and its second`() {
        let (crash, spin, shown) = Self.prompts()
        let run = Self.record(exit: RunRecord.Exit(kind: .crash, code: 3))
        crash.offerAfterClose(run, spin: spin)
        crash.offerAfterClose(run, spin: spin)
        #expect(shown.crashes.count == 1)
        #expect(shown.spins.isEmpty)
        #expect(ThreadSpinPromptPolicy.suggestion(for: run, crashShown: true, currentCap: 0, asks: true) == nil)
        #expect(ThreadSpinPromptPolicy.suggestion(for: run, crashShown: false, currentCap: 0, asks: true) != nil)
    }

    @Test
    func `a game already capped is not offered`() {
        let (crash, spin, shown) = Self.prompts(settings: Self.settings(processors: 8))
        crash.offerAfterClose(Self.record(), spin: spin)
        #expect(shown.spins.isEmpty)
    }

    @Test
    func `don't ask for this game keeps the offer for other games`() {
        let defaults = Self.freshDefaults()
        let model = ThreadSpinPromptModel(
            record: Self.record(), suggestion: .init(busy: 15, processors: 16, cap: 8),
            defaults: defaults, settings: Self.settings(),
        )
        model.stopAsking()
        #expect(!Preferences.asksAboutThreadSpin(forApp: 310_360, in: defaults))
        #expect(Preferences.asksAboutThreadSpin(forApp: 508_440, in: defaults))

        let (crash, spin, shown) = Self.prompts(defaults: defaults)
        crash.offerAfterClose(Self.record(), spin: spin)
        crash.offerAfterClose(Self.record(appid: 508_440), spin: spin)
        #expect(shown.spins.count == 1)
    }

    @Test
    func `limiting writes the cap into the game's own settings`() {
        let settings = Self.settings()
        var finished = false
        let model = ThreadSpinPromptModel(
            record: Self.record(), suggestion: .init(busy: 15, processors: 16, cap: 8),
            defaults: Self.freshDefaults(), settings: settings,
        )
        model.onFinish = { finished = true }
        #expect(model.title == "Higurashi Hou kept 15 threads busy the whole time")
        #expect(model.limitTitle == "Limit to 8 Processors")
        #expect(model.body.contains("Telling the game it has 8 processors lets them sleep."))
        model.limit()
        #expect(settings.values(.game(310_360, bottle: SteamBottle.name)).processors == 8)
        #expect(finished)
    }
}
