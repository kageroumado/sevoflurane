import CryptoKit
import Foundation
import Testing
@testable import Sevoflurane

/// The served fix list, its signature and the values it may carry, its merge
/// under the built-in table, the first-launch decision, and applying and
/// undoing a fix on a game's own values.
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

    /// Stands in for the fixes key, whose private half only the admin's Mac holds.
    private static let key = Curve25519.Signing.PrivateKey()

    /// `body` as the server serves it after `kagerou sevostats publish-fixes`.
    private static func signed(_ body: Data, by key: Curve25519.Signing.PrivateKey = key) throws -> [KnownFix] {
        let signature = try key.signature(for: body).base64EncodedData()
        return FixList.verified(body, signature: signature, key: Self.key.publicKey)
    }

    @Test
    func `a served entry this version cannot read is left out alone`() throws {
        let fixes = try Self.signed(Self.served)
        #expect(fixes.map(\.title) == ["Subnautica 2", "Subnautica 2", "Unreal"])
        #expect(fixes[2].exePattern == "game-win64-shipping.exe")
        #expect(try Self.signed(Data("not json".utf8)).isEmpty)
    }

    @Test
    func `a list without the fixes key's signature is ignored`() throws {
        #expect(try Self.signed(Self.served, by: Curve25519.Signing.PrivateKey()).isEmpty)
        #expect(FixList.verified(Self.served, signature: Data("not a signature".utf8), key: Self.key.publicKey).isEmpty)
        var tampered = Self.served
        tampered.append(contentsOf: Data(" ".utf8))
        let signature = try Self.key.signature(for: Self.served).base64EncodedData()
        #expect(FixList.verified(tampered, signature: signature, key: Self.key.publicKey).isEmpty)
        // The pinned key is a real one, and the test key is not it.
        #expect(FixList.pinnedKey != nil)
        #expect(FixList.verified(Self.served, signature: signature).isEmpty)
    }

    @Test
    func `the built-in table wins a key both set`() throws {
        let merged = try FixList.merged(builtIn: KnownFixes.all, served: Self.signed(Self.served))
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
    func `a value that could reach a file, the registry or the log as more than itself is dropped`() throws {
        let fixes = try Self.signed(Data(#"""
        {"fixes": [
          {"appid": 480, "title": "Spacewar\nfixes: forged line", "reason": "Why.\r\nAnother.",
           "values": {"upscaler": "x\nDYLD_INSERT_LIBRARIES=/tmp/a.dylib", "processors": 9999,
                      "dllOverrides": {"d3d11": "n,b", "..\\evil": "n", "Bad\"Name": "n", "x": "native"},
                      "tuningParameters": {"waitSpin": 1, "adaptive": true, "objectSpin": 1},
                      "program": {"path": "/tmp/a.exe", "arguments": [], "bottle": "Steam", "kind": "exe", "addedAt": 0},
                      "name": "Renamed", "avx": false}},
          {"exe": "../game.exe", "title": "Path", "reason": "Why.", "values": {"avx": false}},
          {"appid": 481, "title": "Package", "reason": "Why.", "values": {"upscaler": "../../shaders"}}
        ]}
        """#.utf8))
        #expect(fixes.count == 1)
        let fix = try #require(fixes.first)
        #expect(fix.title == "Spacewar fixes: forged line")
        #expect(fix.reason == "Why. Another.")
        #expect(fix.values.upscaler == nil)
        #expect(fix.values.processors == nil)
        #expect(fix.values.dllOverrides == ["d3d11": "n,b"])
        #expect(fix.values.tuningParameters == nil)
        #expect(fix.values.program == nil)
        #expect(fix.values.name == nil)
        #expect(fix.values.avx == false)
    }

    @Test
    func `a malformed DLL name is refused`() {
        #expect(FixValues.isValidDLL("d3d11"))
        #expect(FixValues.isValidDLL("xinput1_3"))
        for name in ["D3D11", "..", "a/b", #"a\b"#, "a b", "", String(repeating: "a", count: 65), "a\"b"] {
            #expect(!FixValues.isValidDLL(name), "\(name)")
        }
    }

    @Test
    func `a variable that steers the loader, Wine or the app, or names a path, is only offered`() {
        var values = ConfigValues.empty
        values.environment = [
            "DXVK_ASYNC": "1", "DYLD_INSERT_LIBRARIES": "x", "LD_PRELOAD": "x", "WINEDLLOVERRIDES": "d3d11=n",
            "WINEPREFIX": "x", "SEVO_CPU_COUNT": "2", "GAME_DATA": "/Users/me/x", "GAME_WIN": #"C:\x"#,
            "GAME_HOME": "~/x", "LINE": "a\nb", "1BAD": "x",
        ]
        values.runner = GameRunner.nwjs
        let offered = FixValues.admitted(values).environment ?? [:]
        // Reserved names and malformed ones never pass; the rest may be offered.
        #expect(offered["WINEPREFIX"] == nil)
        #expect(offered["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(offered["LINE"] == nil)
        #expect(offered["1BAD"] == nil)
        #expect(offered["LD_PRELOAD"] == "x")
        let automatic = FixValues.automatic(values)
        #expect(automatic.environment == ["DXVK_ASYNC": "1"])
        #expect(automatic.runner == nil)
        let fix = KnownFix(appID: 1, exePattern: nil, title: "Env", values: values, reason: "Why.")
        let planned = FixLedger.plan(own: .empty, fixes: [fix])
        #expect(planned?.values.environment == ["DXVK_ASYNC": "1"])
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
