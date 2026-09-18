import Foundation
import Testing
@testable import Sevoflurane

/// The per-game fix table: what it matches, what it recommends, and that it
/// only ever recommends.
struct KnownFixesTests {
    @Test
    func `a fix matches its own app and nothing else`() {
        let recommendation = KnownFixes.recommended(for: 1_962_700)
        #expect(recommendation.value(for: \.renderer) == .d3dmetal)
        #expect(KnownFixes.recommended(for: 7).isEmpty)
    }

    @Test
    func `an executable pattern matches the games it is about`() {
        #expect(KnownFix.matches(pattern: "nw.exe", name: "nw.exe"))
        #expect(!KnownFix.matches(pattern: "nw.exe", name: "new.exe"))
        #expect(KnownFix.matches(pattern: "*-win64-shipping.exe", name: "game-win64-shipping.exe"))
        #expect(!KnownFix.matches(pattern: "*-win64-shipping.exe", name: "game-win32-shipping.exe"))
        let byExe = KnownFixes.recommended(for: 424_242, exes: ["nw.exe"])
        #expect(byExe.value(for: \.runner) == GameRunner.nwjs)
    }

    @Test
    func `every entry carries a reason and sets something`() {
        for fix in KnownFixes.all {
            #expect(!fix.reason.isEmpty)
            #expect(fix.values.hasSettings)
            #expect(fix.appID != nil || fix.exePattern != nil)
        }
    }

    @Test
    func `a recommendation is a value to read, never one already applied`() {
        // Nothing the table says reaches a game's file on its own: the store
        // is what the materializer reads, and the table is not in it.
        let recommendation = KnownFixes.recommended(for: 339_800)
        #expect(recommendation.value(for: \.emulateModeset) == true)
        #expect(GameConfig.game(339_800).emulateModeset == nil)
    }

    @Test
    func `using every recommendation keeps what the fix does not name`() {
        var mine = ConfigValues.empty
        mine.windows = .all
        let merged = KnownFixes.recommended(for: 1_962_700).applied(to: mine)
        #expect(merged.renderer == .d3dmetal)
        #expect(merged.windows == .all)
    }
}
