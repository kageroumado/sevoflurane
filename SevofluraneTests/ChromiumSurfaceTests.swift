import Foundation
import Testing
@testable import Sevoflurane

/// The audit that finds Steam's UI calling a Chromium API WebKit lacks, and
/// the shim's promise to supply the ones it claims.
struct ChromiumSurfaceTests {
    @Test
    func `an unguarded call to an API the shim does not supply is found`() {
        let source = #"function T(){y.queryLocalFonts().then(L)}function L(){}"#
        let findings = ChromiumSurface.audit(source, file: "sp.js")
        #expect(findings.map(\.api) == ["queryLocalFonts"])
        #expect(findings.first?.excerpt.contains("y.queryLocalFonts()") == true)
    }

    @Test
    func `a feature-detected call is left alone`() {
        // Steam's own color picker, verbatim shape.
        let eyeDropper = ##"ji=(0,M.useCallback)(async()=>{if(!("EyeDropper"in window)){alert(rt.Z.Localize("#Sale_EyeDropperError"));return}try{const An=(await new window.EyeDropper().open()).sRGBHex"##
        let typeofGuard = #"typeof w.showOpenFilePicker=="function"&&w.showOpenFilePicker({})"#
        let andGuard = #"n.scheduler&&n.scheduler.postTask&&n.scheduler.postTask(f)"#
        #expect(ChromiumSurface.audit(eyeDropper, file: "sp.js").isEmpty)
        #expect(ChromiumSurface.audit(typeofGuard, file: "sp.js").isEmpty)
        #expect(ChromiumSurface.audit(andGuard, file: "sp.js").isEmpty)
    }

    @Test
    func `an identifier that only ends in the name is not a call to it`() {
        #expect(ChromiumSurface.audit("o.myqueryLocalFonts(1)", file: "sp.js").isEmpty)
    }

    @Test
    func `the calls that broke the 2026-11-11 bundle are covered by the shim`() {
        // The three call sites in that bundle: the home page, menus, voice.
        let sources = [
            #"if(Zr){const Hn=Sr.requestIdleCallback(()=>Ui(!0),{timeout:1e3});return()=>Sr.cancelIdleCallback(Hn)}"#,
            #"function T(){y.requestIdleCallback(L,{timeout:M})}"#,
            #"new Promise(h=>{window.requestIdleCallback(()=>{this.m_promiseIdleContext=void 0},{timeout:d})})"#,
        ]
        for source in sources {
            #expect(ChromiumSurface.audit(source, file: "sp.js").isEmpty)
        }
    }

    @Test
    func `every API the audit counts as supplied is installed by the shim`() throws {
        let url = try #require(Bundle.main.url(forResource: "steamclient_shim", withExtension: "js"))
        let shim = try String(contentsOf: url, encoding: .utf8)
        for name in ChromiumSurface.suppliedByShim {
            #expect(shim.contains("w.\(name) = function"), "supplyChromiumSurface does not install \(name)")
        }
        let listed = Set(ChromiumSurface.chromiumOnly.map(\.name))
        #expect(ChromiumSurface.suppliedByShim.isSubset(of: listed))
    }

    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: SteamBottle.steamui.appendingPathComponent("sp.js").path,
    )))
    func `the installed Steam UI calls nothing the shim lacks`() {
        let findings = ChromiumSurface.audit(bundle: SteamBottle.steamui)
        #expect(findings.isEmpty, "\(findings.map(ChromiumSurface.sentence(for:)))")
    }

    @Test
    func `the page error a missing API throws names it`() {
        let detail = #"{"message":"Sr.requestIdleCallback is not a function. (In 'Sr.requestIdleCallback(()=>Ui(!0),{timeout:1e3})', 'Sr.requestIdleCallback' is undefined)","kind":"boundary"}"#
        #expect(PageErrorTriage.verdict(for: detail) == .missingChromiumAPI("requestIdleCallback"))
        let constructor = #"{"message":"window.EyeDropper is not a constructor","kind":"uncaught"}"#
        #expect(PageErrorTriage.verdict(for: constructor) == .missingChromiumAPI("EyeDropper"))
    }
}
