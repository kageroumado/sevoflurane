import Foundation
import Testing
@testable import Sevoflurane

/// The served fix list, its merge under the built-in table, the first-launch
/// decision, and applying and undoing a fix on a game's own values.
struct FixListTests {
    private static let served = Data("""
    {"fixes": [
      {"id": 1, "appid": 1962700, "title": "Subnautica 2", "values": {"renderer": "d3dmetal"}, "reason": "Seeded."},
      {"id": 2, "appid": 1962700, "title": "Subnautica 2", "values": {"renderer": "dxmt", "processors": 6},
       "reason": "Six is enough."},
      {"id": 3, "appid": 480, "title": "Spacewar", "values": {"renderer": "metal"}, "reason": "A later renderer."},
      {"id": 4, "exe": "Game-Win64-Shipping.exe", "title": "Unreal", "values": {"avx": false}, "reason": "Measured."},
      {"id": 5, "appid": 7, "title": "Nothing this version has", "values": {"someLaterKey": 1}, "reason": "Later."}
    ]}
    """.utf8)

    @Test
    func `a served entry this version cannot read is left out alone`() {
        let fixes = FixList.served(from: Self.served)
        #expect(fixes.map(\.title) == ["Subnautica 2", "Subnautica 2", "Unreal"])
        #expect(fixes[2].exePattern == "game-win64-shipping.exe")
        #expect(FixList.served(from: Data("not json".utf8)).isEmpty)
    }

    @Test
    func `the built-in table wins a key both set`() {
        let merged = FixList.merged(builtIn: KnownFixes.all, served: FixList.served(from: Self.served))
        // The seeded copy of a built-in entry adds nothing; the second keeps
        // only the key the built-in one does not set.
        #expect(merged.count == KnownFixes.all.count + 2)
        let recommendation = KnownFixes.recommended(for: 1_962_700, from: merged)
        #expect(recommendation.value(for: \.renderer) == .d3dmetal)
        #expect(recommendation.value(for: \.processors) == 6)
        let unreal = KnownFixes.recommended(for: 99, exes: ["game-win64-shipping.exe"], from: merged)
        #expect(unreal.value(for: \.avx) == false)
    }

    @Test
    func `only a first launch with the switch on is fixed`() {
        #expect(FixLedger.isFirstLaunch(enabled: true, hasRunRecord: false, wasDecided: false))
        #expect(!FixLedger.isFirstLaunch(enabled: false, hasRunRecord: false, wasDecided: false))
        #expect(!FixLedger.isFirstLaunch(enabled: true, hasRunRecord: true, wasDecided: false))
        #expect(!FixLedger.isFirstLaunch(enabled: true, hasRunRecord: false, wasDecided: true))
    }

    @Test
    func `a run record of the game is a launch before`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "fixlist-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!RunLog.hasRecord(forApp: 480, in: root))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"t\":\"2026-10-06T10:00:00Z\",\"appid\":480}\n".utf8)
            .write(to: root.appending(path: "2026-10.jsonl"))
        #expect(RunLog.hasRecord(forApp: 480, in: root))
        #expect(!RunLog.hasRecord(forApp: 481, in: root))
    }

    @Test
    func `a fix sets only what the game has no value of its own for`() throws {
        var own = ConfigValues.empty
        own.renderer = .dxvk
        own.dllOverrides = ["d3d9": "b"]
        own.exes = ["game.exe"]
        let fixes = [
            KnownFix(
                appID: 1, exePattern: nil, title: "First", values: ConfigValues(
                    renderer: .d3dmetal, emulateModeset: true, dllOverrides: ["d3d9": "n", "d3d11": "n,b"],
                ), reason: "One.",
            ),
            KnownFix(appID: 1, exePattern: nil, title: "Second", values: ConfigValues(emulateModeset: false), reason: "Two."),
            KnownFix(appID: 1, exePattern: nil, title: "Native", values: ConfigValues(runner: GameRunner.nwjs), reason: "Three."),
        ]
        let planned = try #require(FixLedger.plan(own: own, fixes: fixes))
        #expect(planned.values.renderer == .dxvk)
        #expect(planned.values.emulateModeset == true)
        #expect(planned.values.dllOverrides == ["d3d9": "b", "d3d11": "n,b"])
        #expect(planned.values.runner == nil)
        #expect(planned.values.exes == ["game.exe"])
        #expect(planned.record.fixes.map(\.title) == ["First"])
        #expect(planned.record.keys(in: planned.values) == ["dllOverrides", "emulateModeset"])
        #expect(planned.record.previous.dllOverrides == ["d3d9": "b"])
        #expect(planned.record.previous.emulateModeset == nil)
        #expect(FixLedger.plan(own: planned.values, fixes: fixes) == nil)
    }

    @Test
    func `undo puts every key back as it was`() throws {
        var own = ConfigValues.empty
        own.dllOverrides = ["d3d9": "b"]
        own.windows = .all
        let fix = KnownFix(
            appID: 1, exePattern: nil, title: "Fix",
            values: ConfigValues(renderer: .d3dmetal, dllOverrides: ["d3d11": "n,b"], processors: 8), reason: "Why.",
        )
        let planned = try #require(FixLedger.plan(own: own, fixes: [fix]))
        let undone = FixLedger.undo(planned.record, own: planned.values)
        #expect(undone.values == own)
        #expect(!undone.record.applied.hasSettings)
        #expect(undone.record.fixes.map(\.title) == ["Fix"])

        // One key at a time, and a value the player chose since stays theirs.
        var changed = planned.values
        changed.processors = 4
        let renderer = FixLedger.undo(planned.record, keys: ["renderer"], own: changed)
        #expect(renderer.values.renderer == nil)
        #expect(renderer.values.processors == 4)
        #expect(renderer.record.keys(in: renderer.values) == ["dllOverrides"])
        let rest = FixLedger.undo(renderer.record, own: renderer.values)
        #expect(rest.values.processors == 4)
        #expect(rest.values.dllOverrides == ["d3d9": "b"])
    }

    @Test
    func `the record survives the disk`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "fixlist-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fix = KnownFix(appID: 1, exePattern: nil, title: "Fix", values: ConfigValues(processors: 8), reason: "Why.")
        let planned = try #require(FixLedger.plan(own: .empty, fixes: [fix], date: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(FixLedger.record(for: 1, in: root) == nil)
        FixLedger.save(planned.record, for: 1, in: root)
        #expect(FixLedger.record(for: 1, in: root) == planned.record)
    }
}
