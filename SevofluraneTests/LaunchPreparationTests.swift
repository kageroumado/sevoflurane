import Foundation
import Synchronization
import Testing
@testable import Sevoflurane

/// A launch waits for its preparation, so a game's first process reads the
/// settings its first launch was given; and a preparation that outlasts its
/// budget leaves the game undecided for the next launch.
struct LaunchPreparationTests {
    private static let appID = 480

    /// The fix the launches below are given: a processor cap, which the
    /// game's env file carries as `SEVO_CPU_COUNT`.
    private static let fix: KnownFix = {
        var values = ConfigValues.empty
        values.processors = 4
        return KnownFix(appID: appID, exePattern: nil, title: "Cap", values: values, reason: "Why.")
    }()

    /// The game's own values, as the launch and its preparation share them.
    private final class Settings: Sendable {
        let values = Mutex(ConfigValues.empty)

        var current: ConfigValues {
            values.withLock { $0 }
        }
    }

    /// A first launch's preparation, against a ledger in `root` and the
    /// game's values in `settings`, after `delay` of slow disk.
    private static func prepare(
        root: URL, settings: Settings, delay: TimeInterval, gate: LaunchPreparation.Gate,
    ) -> AppliedFixes? {
        Thread.sleep(forTimeInterval: delay)
        return FixLedger.apply(
            appID: appID, enabled: true, hasRunRecord: false, own: settings.current,
            fixes: [fix], in: root, committing: gate.commit,
        ) { values in settings.values.withLock { $0 = values } }
    }

    /// The env file's lines at the moment the launch spawns its process.
    private static func linesAtSpawn(_ settings: Settings) -> [String] {
        ConfigMaterializer.gameLines(appID, settings.current, engine: URL(filePath: "/nonexistent"))
    }

    private final class Flag: Sendable {
        let value = Mutex(false)
    }

    private static func ledger() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "launch-prep-\(UUID().uuidString)")
    }

    @Test
    func `the first process reads the settings its first launch was given`() async {
        let root = Self.ledger()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = Settings()

        let outcome = await LaunchPreparation.run(within: .seconds(5)) { gate in
            Self.prepare(root: root, settings: settings, delay: 0.2, gate: gate)
        }

        guard case let .finished(fixes) = outcome else {
            Issue.record("the launch went on without its preparation")
            return
        }
        #expect(fixes?.fixes.map(\.title) == ["Cap"])
        #expect(Self.linesAtSpawn(settings).contains("SEVO_CPU_COUNT=4"))
        #expect(FixLedger.record(for: Self.appID, in: root) != nil)
    }

    @Test
    func `a preparation past its budget leaves the game undecided`() async throws {
        let root = Self.ledger()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = Settings()
        let done = Flag()

        let outcome = await LaunchPreparation.run(within: .milliseconds(50)) { gate in
            let fixes = Self.prepare(root: root, settings: settings, delay: 0.4, gate: gate)
            done.value.withLock { $0 = true }
            return fixes
        }

        guard case .abandoned = outcome else {
            Issue.record("the launch waited past its budget")
            return
        }
        #expect(!Self.linesAtSpawn(settings).contains("SEVO_CPU_COUNT=4"))
        // The preparation runs on, and writes nothing once the launch has gone.
        let deadline = ContinuousClock.now + .seconds(5)
        while !done.value.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(done.value.withLock { $0 })
        #expect(FixLedger.record(for: Self.appID, in: root) == nil)
        #expect(settings.current == .empty)
    }

    @Test
    func `a write under way when the budget ends is waited for`() async {
        let settings = Settings()

        let outcome = await LaunchPreparation.run(within: .milliseconds(50)) { gate in
            guard gate.commit() else { return false }
            Thread.sleep(forTimeInterval: 0.3)
            settings.values.withLock { $0.processors = 4 }
            return true
        }

        guard case .finished(true) = outcome else {
            Issue.record("the launch went on halfway through a write")
            return
        }
        #expect(Self.linesAtSpawn(settings).contains("SEVO_CPU_COUNT=4"))
    }
}
