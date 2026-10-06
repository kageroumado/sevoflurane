import CryptoKit
import Foundation
import Testing
@testable import Sevoflurane

/// The served fix list, its signature and the values it may carry, its merge
/// under the built-in table, the first-launch decision, and applying and
/// undoing a fix on a game's own values.
struct FixListTests {
    private static let served = Data("""
    {"serial": 3, "issued": "2026-10-06T00:00:00Z", "fixes": [
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

    private static let now = Date(timeIntervalSince1970: 1_791_244_800) // 2026-10-06T00:00:00Z

    /// What this Mac makes of `body` as the server serves it after `kagerou
    /// sevostats publish-fixes`, having taken serial `highest` before.
    private static func verdict(
        _ body: Data, by key: Curve25519.Signing.PrivateKey = key, highest: Int = 0,
    ) throws -> FixList.Verdict {
        let signature = try key.signature(for: body).base64EncodedData()
        return FixList.verdict(on: body, signature: signature, highestSerial: highest, key: Self.key.publicKey, now: now)
    }

    /// The entries of a list this Mac takes; none for one it refuses.
    private static func signed(_ body: Data) throws -> [KnownFix] {
        guard case let .taken(list) = try verdict(body) else { return [] }
        return list.fixes
    }

    /// The five built-in entries as `kagerou sevostats publish-fixes` built
    /// and signed them on the admin's Mac with the real fixes key, serial 1.
    private static let adminSigned = Data(base64Encoded: [
        "eyJmaXhlcyI6W3siYXBwaWQiOjE5NjI3MDAsImlkIjoxLCJyZWFzb24iOiJTdWJuYXV0aWNhIDIgcmVuZGVycyB3aXRoIERpcmVj",
        "dDNEIDEyLCBhbmQgRDNETWV0YWwgaXMgdGhlIG9ubHkgbGF5ZXIgaGVyZSB0aGF0IGFuc3dlcnMgaXQuIiwidGl0bGUiOiJTdWJu",
        "YXV0aWNhIDIiLCJ2YWx1ZXMiOnsicmVuZGVyZXIiOiJkM2RtZXRhbCJ9fSx7ImFwcGlkIjozMzk4MDAsImlkIjoyLCJyZWFzb24i",
        "OiJXaXRob3V0IGZha2VkIG1vZGUgY2hhbmdlcyB0aGUgZ2FtZSBpcyBvZmZlcmVkIHRoZSBkaXNwbGF5J3MgMTY6OSBtb2RlcyBh",
        "bG9uZTsgd2l0aCB0aGVtIHdpbjMydSBhZGRzIDI2IHZpcnR1YWwgbW9kZXMsIHRoZSA0OjMgb25lcyB0aGlzIGdhbWUgbG9va3Mg",
        "Zm9yIGluY2x1ZGVkLiIsInRpdGxlIjoiSHVuaWVQb3AiLCJ2YWx1ZXMiOnsiZW11bGF0ZU1vZGVzZXQiOnRydWV9fSx7ImFwcGlk",
        "IjozMTAzNjAsImlkIjozLCJyZWFzb24iOiJVbml0eSA1IHN0YXJ0cyBhIHdvcmtlciBwZXIgcHJvY2Vzc29yIGFuZCBrZWVwcyBl",
        "dmVyeSBvbmUgc3Bpbm5pbmcgdW5kZXIgUm9zZXR0YTogb24gYSAxNi1jb3JlIE00IE1heCB0aGUgZ2FtZSB1c2VkIDEzNTcgJSBD",
        "UFUgYXQgNTQgZnBzLCBzdGFsbGluZyBzZXZlcmFsIHRpbWVzIGEgc2Vjb25kLCBhbmQgdG9sZCBvZiA4IHByb2Nlc3NvcnMsIDE4",
        "NCAlIGF0IDExNyBmcHMuIiwidGl0bGUiOiJIaWd1cmFzaGkgV2hlbiBUaGV5IENyeSBIb3UgLSBDaC4xIE9uaWtha3VzaGkiLCJ2",
        "YWx1ZXMiOnsicHJvY2Vzc29ycyI6OH19LHsiYXBwaWQiOjE5MzM2NjAsImlkIjo0LCJyZWFzb24iOiJBbiBSUEcgTWFrZXIgTVYg",
        "Z2FtZSBvbiBOVy5qczogdGhlIG5hdGl2ZSBtYWNPUyBydW50aW1lIHJ1bnMgaXQgb3V0c2lkZSB0aGUgYm90dGxlLCB3aXRoIGl0",
        "cyBhY2hpZXZlbWVudHMgY2FycmllZCBieSBhIHN0dWIuIiwidGl0bGUiOiJEZW1vbnMgUm9vdHMiLCJ2YWx1ZXMiOnsicnVubmVy",
        "IjoibndqcyJ9fSx7ImV4ZSI6Im53LmV4ZSIsImlkIjo1LCJyZWFzb24iOiJUaGUgZ2FtZSBpcyBOVy5qczogdGhlIG5hdGl2ZSBt",
        "YWNPUyBydW50aW1lIHJ1bnMgaXQgb3V0c2lkZSB0aGUgYm90dGxlLCBhdCB0aGUgc3BlZWQgb2YgYSBNYWMgYnJvd3NlciByYXRo",
        "ZXIgdGhhbiBvZiBSb3NldHRhLiIsInRpdGxlIjoiTlcuanMgZ2FtZXMiLCJ2YWx1ZXMiOnsicnVubmVyIjoibndqcyJ9fV0sImlz",
        "c3VlZCI6IjIwMjYtMTAtMDZUMDE6MDk6NDVaIiwic2VyaWFsIjoxfQo=",
    ].joined())!

    private static let adminSignature =
        Data("V1Xcm8wFfJlMxJ/cKwhM74F53cBLZnuOTVyx8Y3GrbN8lgVRSWS+p/Ya6KOiwYlXmNCZ7XO1qAyCigerHgitBQ==".utf8)

    @Test
    func `a served entry this version cannot read is left out alone`() throws {
        let fixes = try Self.signed(Self.served)
        #expect(fixes.map(\.title) == ["Subnautica 2", "Subnautica 2", "Unreal"])
        #expect(fixes[2].exePattern == "game-win64-shipping.exe")
        #expect(try Self.verdict(Data("not json".utf8)) == .malformed)
    }

    @Test
    func `the list the admin's Mac signed verifies with the pinned key`() {
        let verdict = FixList.verdict(
            on: Self.adminSigned, signature: Self.adminSignature, highestSerial: 1, now: Self.now,
        )
        guard case let .taken(list) = verdict else {
            Issue.record("refused: \(verdict)")
            return
        }
        #expect(list.serial == 1)
        #expect(list.fixes.count == KnownFixes.all.count)
        #expect(FixList.merged(builtIn: KnownFixes.all, served: list.fixes) == KnownFixes.all)
    }

    @Test
    func `a list without the fixes key's signature is ignored`() throws {
        #expect(try Self.verdict(Self.served, by: Curve25519.Signing.PrivateKey()) == .unsigned)
        #expect(FixList.verdict(
            on: Self.served, signature: Data("not a signature".utf8), highestSerial: 0, key: Self.key.publicKey,
        ) == .unsigned)
        var tampered = Self.served
        tampered.append(contentsOf: Data(" ".utf8))
        let signature = try Self.key.signature(for: Self.served).base64EncodedData()
        #expect(FixList.verdict(on: tampered, signature: signature, highestSerial: 0, key: Self.key.publicKey) == .unsigned)
        // The pinned key is a real one, and the test key is not it.
        #expect(FixList.pinnedKey != nil)
        #expect(FixList.verdict(on: Self.served, signature: signature, highestSerial: 0) == .unsigned)
    }

    @Test
    func `an older list is refused and the same one taken again`() throws {
        #expect(try Self.verdict(Self.served, highest: 4) == .older(serial: 3, highest: 4))
        guard case let .taken(again) = try Self.verdict(Self.served, highest: 3) else {
            Issue.record("the list already taken was refused")
            return
        }
        #expect(again.serial == 3)
        let tomorrow = Data(#"{"serial": 9, "issued": "2026-10-08T00:00:00Z", "fixes": []}"#.utf8)
        #expect(try Self.verdict(tomorrow) == .fromTheFuture(Date(timeIntervalSince1970: 1_791_417_600)))
        let unnumbered = Data(#"{"fixes": []}"#.utf8)
        #expect(try Self.verdict(unnumbered) == .malformed)
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
        {"serial": 1, "issued": "2026-10-06T00:00:00Z", "fixes": [
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
