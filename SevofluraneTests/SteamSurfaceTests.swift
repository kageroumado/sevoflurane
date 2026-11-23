import Foundation
import Testing
@testable import Sevoflurane

/// The catalog of Steam internals and the probes that answer for each entry
/// from a client's files, run here against small made-up bundles.
struct SteamSurfaceTests {
    private typealias Entry = SteamSurface.Entry

    private func answer(_ entry: Entry, script: String, style: String = "") -> (SteamSurface.Status, String) {
        SteamSurface.answer(for: entry, in: SteamUIBundle(script: script, style: style))
    }

    private func entry(for call: SteamSurface.Call) throws -> Entry {
        try #require(SteamSurface.calls.first { $0.name == call.path })
    }

    // MARK: - The catalog

    @Test
    func `every entry has a name, a use and one place in the list`() {
        var seen: Set<String> = []
        for entry in SteamSurface.catalog {
            #expect(!entry.name.isEmpty)
            #expect(!entry.use.isEmpty, "\(entry.name) says nothing of its use")
            #expect(seen.insert("\(entry.kind.rawValue) \(entry.name)").inserted, "\(entry.name) is listed twice")
        }
    }

    @Test
    func `every kind has entries`() {
        for kind in SteamSurface.Kind.allCases {
            #expect(!SteamSurface.entries(of: kind).isEmpty, "no \(kind.rawValue) entry")
        }
    }

    @Test
    func `every call has its entry and builds its own JavaScript`() {
        #expect(SteamSurface.calls.map(\.name) == SteamSurface.Call.allCases.map(\.path))
        #expect(SteamSurface.Call.terminateApp.invocation("\"730\"", "false") == "SteamClient.Apps.TerminateApp(\"730\", false)")
        #expect(SteamSurface.Call.reconnect.invocation() == "SteamClient.User.Reconnect()")
    }

    @Test
    func `a popup name is whole or the start of a longer one`() {
        #expect(SteamSurface.Popup.desktop.isWholeName)
        #expect(!SteamSurface.Popup.contextMenu.isWholeName)
        #expect(SteamWindowRole(popupName: "SP Desktop_uid0") == .desktop)
        #expect(SteamWindowRole(popupName: "contextmenu_12") == .menu)
    }

    // MARK: - Calls

    @Test
    func `a call Steam's own code makes with the same arguments is found`() throws {
        let script = #"function a(e){SteamClient.Apps.RunGame(e.GetGameID(),"",-1,u.s7X)}"#
        let (status, detail) = try answer(entry(for: .runGame), script: script)
        #expect(status == .found)
        #expect(detail.contains("Steam passes 4"))
    }

    @Test
    func `an argument Steam added makes the call changed`() throws {
        let script = "case 3:SteamClient.Installs.OpenInstallWizard([Number(et)],o.Oy,{bSkipEULA:!1});return;"
        let (status, detail) = try answer(entry(for: .openInstallWizard), script: script)
        #expect(status == .changed)
        #expect(detail.contains("the app passes 2"))
        #expect(detail.contains("Steam's own code passes 3"))
    }

    @Test
    func `an argument Steam dropped makes the call changed`() throws {
        let script = "SteamClient.Apps.TerminateApp(e.gameid)"
        let (status, _) = try answer(entry(for: .terminateApp), script: script)
        #expect(status == .changed)
    }

    @Test
    func `a call reached through an optional link or another window counts`() throws {
        let optional = "xe?SteamClient.Apps?.AddShortcut(xe.strAppName,xe.strExePath,xe.strArguments,xe.strCmdline).then(f):0"
        #expect(try answer(entry(for: .addShortcut), script: optional).0 == .found)
        let popup = "Bt.SteamClient.Apps.VerifyApp(n)"
        #expect(try answer(entry(for: .verifyApp), script: popup).0 == .found)
    }

    @Test
    func `a method of the same name on another object is not the call`() throws {
        let script = "this.m_store.RunGame(a,b,c,d);n.xm.Reconnect()"
        #expect(try answer(entry(for: .runGame), script: script).0 == .missing)
        #expect(try answer(entry(for: .reconnect), script: script).0 == .missing)
    }

    @Test
    func `a call only the app makes is unchecked, and one Steam stopped making is missing`() throws {
        #expect(try answer(entry(for: .specifyCompatTool), script: "m.SpecifyCompatTool({appid:y})").0 == .unchecked)
        #expect(try answer(entry(for: .runGame), script: "function nothing(){}").0 == .missing)
    }

    @Test
    func `a call the app only routes is found with any argument count`() throws {
        let script = "SteamClient.System.OpenFileDialog({strTitle:e,rgFilters:t},n,r)"
        #expect(try answer(entry(for: .openFileDialog), script: script).0 == .found)
    }

    @Test
    func `a registration's handler is read where Steam defines it`() throws {
        let unchanged = """
        class a{Init(){this.h.Add(SteamClient.Apps.RegisterForGameActionStart(this.OnGameActionStart))}\
        OnGameActionStart(et,me,Te,Fe){this.Go(et)}}
        """
        let (status, detail) = try answer(entry(for: .registerForGameActionStart), script: unchanged)
        #expect(status == .found)
        #expect(detail.contains("handlers take 4"))

        let grown = unchanged.replacingOccurrences(of: "(et,me,Te,Fe){", with: "(et,me,Te,Fe,Ge,He){")
        let (changed, why) = try answer(entry(for: .registerForGameActionStart), script: grown)
        #expect(changed == .changed)
        #expect(why.contains("take 6"))
    }

    @Test
    func `a handler written in place is counted`() throws {
        let script = "SteamClient.Overlay.RegisterForOverlayActivated((e,t,n,r,i)=>{this.Set(e,t,n)})"
        let (status, detail) = try answer(entry(for: .registerForOverlayActivated), script: script)
        #expect(status == .changed)
        #expect(detail.contains("take 5"))
    }

    // MARK: - Globals and members

    @Test
    func `a global is found by its assignment, never by a comparison`() {
        let global = Entry(.global, "appStore", "the library", .global)
        #expect(answer(global, script: "function hs(){return ws=new ms,window.appStore=ws,ws}").0 == .found)
        #expect(answer(global, script: "(self.appStore=self.appStore||[]).push(1)").0 == .found)
        #expect(answer(global, script: "if(window.appStore==null)return").0 == .missing)
        #expect(answer(global, script: "window.myappStore=1").0 == .missing)
    }

    @Test
    func `a member is found as a whole name`() {
        let member = Entry(.member, "m_mapPopups", "every popup", .identifier(passes: nil))
        #expect(answer(member, script: "this.m_mapPopups=new Map;").0 == .found)
        #expect(answer(member, script: "this.m_mapPopupsByName=new Map;").0 == .missing)
    }

    @Test
    func `a method that takes the app's arguments is found`() {
        let method = Entry(.member, "ShowFriendChatDialogWhenReady", "opening a chat", .identifier(passes: 4))
        let (status, detail) = answer(method, script: "class U{ShowFriendChatDialogWhenReady(O,v,z=!0,p=!0){return 1}}")
        #expect(status == .found)
        #expect(detail.contains("(O,v,z=!0,p=!0)"))
    }

    @Test
    func `a method that requires more than the app passes is changed`() {
        let method = Entry(.member, "ShowFriendChatDialogWhenReady", "opening a chat", .identifier(passes: 4))
        let (status, detail) = answer(method, script: "class U{ShowFriendChatDialogWhenReady(O,v,z,p,q){return 1}}")
        #expect(status == .changed)
        #expect(detail.contains("the app passes 4"))
    }

    @Test
    func `a method defined as an arrow field is read`() {
        let method = Entry(.member, "RemoveModal", "dismissing a modal", .identifier(passes: 1))
        #expect(answer(method, script: "class M{RemoveModal=(a,b)=>{this.x(a)}}").0 == .changed)
        #expect(answer(method, script: "class M{RemoveModal=a=>{this.x(a)}}").0 == .found)
        // A call through a dot defines nothing.
        #expect(answer(method, script: "n.RemoveModal(a,b,c);").0 == .found)
    }

    // MARK: - Class maps and markers

    private let strip = Entry(
        .classMap, "the Deck strip", "placing the strip",
        .classMap(signature: ["DeckVerifiedInfo"], limit: 400), tokens: ["DeckVerifiedInfo", "Container"],
    )

    @Test
    func `a class map with its signature and keys is found`() {
        let script = #"76052:(we=>{we.exports={Container:"_1a",DeckVerifiedInfo:"IIJ","duration-app-launch":"800ms"}}),"#
        let (status, detail) = answer(strip, script: script)
        #expect(status == .found)
        #expect(detail.contains("3 classes"))
    }

    @Test
    func `a module signature that is gone makes the class map missing`() {
        let script = #"76052:(we=>{we.exports={Container:"_1a",DeckCompatInfo:"IIJ"}}),"#
        let (status, detail) = answer(strip, script: script)
        #expect(status == .missing)
        #expect(detail.contains("DeckVerifiedInfo"))
    }

    @Test
    func `a class map that lost a key the app reads is changed`() {
        let script = #"76052:(we=>{we.exports={Wrapper:"_1a",DeckVerifiedInfo:"IIJ"}}),"#
        let (status, detail) = answer(strip, script: script)
        #expect(status == .changed)
        #expect(detail.contains("Container"))
    }

    @Test
    func `a class map past the length the app reads is changed`() {
        let padding = (0 ..< 60).map { "Key\($0):\"_class\($0)\"" }.joined(separator: ",")
        let script = "76052:(we=>{we.exports={Container:\"_1a\",DeckVerifiedInfo:\"IIJ\",\(padding)}}),"
        #expect(answer(strip, script: script).0 == .changed)
    }

    @Test
    func `the key of some other object is not the class map`() {
        let script = #"render(){return{DeckVerifiedInfo:"x",children:{a:1}}}"#
        #expect(answer(strip, script: script).0 == .missing)
    }

    @Test
    func `text is found whichever quote the bundle writes strings with`() {
        let name = Entry(.windowName, "SP Desktop", "the main window", .text(["\"SP Desktop\""]))
        #expect(answer(name, script: #"pB("SP Desktop",n,fB.DesktopUI,g,h)"#).0 == .found)
        #expect(answer(name, script: "pB(`SP Desktop`,n,fB.DesktopUI,g,h)").0 == .found)
        #expect(answer(name, script: "pB('SP Desktop',n,fB.DesktopUI,g,h)").0 == .found)
        let (status, detail) = answer(name, script: #"pB("SP DesktopLoginWindow",n)"#)
        #expect(status == .missing)
        #expect(detail.contains("SP Desktop"))
    }

    // MARK: - Classes

    @Test
    func `a class is found in a style sheet or a script, as a whole name`() {
        let area = Entry(.cssClass, "title-area", "the drag region", .cssClass)
        #expect(answer(area, script: "x", style: ".TitleBar.title-area{height:32px}").0 == .found)
        #expect(answer(area, script: #"className:"TitleBar title-area""#).0 == .found)
        #expect(answer(area, script: "x", style: ".title-area-highlight{opacity:0}").0 == .missing)
    }

    // MARK: - What the app answers

    @Test
    func `a window call the app does not answer is named`() {
        let window = SteamSurface.answeredSurfaces[0]
        let known = "Bt.SteamClient.Window.SetMinSize(a,b),n.SteamClient.Window?.Close(),SteamClient.Window.SetResizeGrip(8,8)"
        #expect(answer(window, script: known).0 == .found)
        let (status, detail) = answer(window, script: known + ";SteamClient.Window.SetTitlebarOverlay(!0)")
        #expect(status == .changed)
        #expect(detail.contains("SetTitlebarOverlay"))
    }

    @Test
    func `a browser view method the shim lacks is named`() throws {
        let methods = try #require(SteamSurface.answeredSurfaces.first { $0.name == "browser view methods" })
        #expect(answer(methods, script: "this.m_browserView.LoadURL(e),this.m_browser.GoBack()").0 == .found)
        let (status, detail) = answer(methods, script: "this.m_browserView.LoadURL(e),this.m_browserView.SetZoom(2)")
        #expect(status == .changed)
        #expect(detail.contains("SetZoom"))
    }

    @Test
    func `an event Steam waits for and the app never fires is named`() throws {
        let events = try #require(SteamSurface.answeredSurfaces.first { $0.name == "browser view events" })
        #expect(answer(events, script: #"e.on("finished-request",t),e.on("message",n)"#).0 == .found)
        let (status, detail) = answer(events, script: "e.on(`focus-changed`,r),e.SetFocus(!0)")
        #expect(status == .changed)
        #expect(detail.contains("focus-changed"))
    }

    @Test
    func `an unguarded Chromium call the shim lacks is missing`() throws {
        let chromium = try #require(SteamSurface.answeredSurfaces.first { $0.name == "Chromium-only APIs" })
        #expect(answer(chromium, script: "function T(){y.requestIdleCallback(L,{timeout:M})}").0 == .found)
        #expect(answer(chromium, script: "a(`EyeDropper`in window);new window.EyeDropper().open()").0 == .found)
        let (status, detail) = answer(chromium, script: "function T(){y.queryLocalFonts().then(L)}")
        #expect(status == .missing)
        #expect(detail.contains("queryLocalFonts"))
    }

    // MARK: - The report

    @Test
    func `the report counts each answer and prints only what is missing or changed`() throws {
        let entries = try [
            Entry(.global, "appStore", "the library", .global),
            Entry(.global, "uiStore", "the filters", .global),
            Entry(.windowName, "SP Desktop", "the main window", .text(["\"SP Desktop\""])),
            Entry(.constant, "EResult 52", "a canceled dialog", .unchecked("a number")),
            entry(for: .openInstallWizard),
        ]
        let bundle = SteamUIBundle(
            scripts: [.init(path: "sp.js", text: "window.appStore=a;SteamClient.Installs.OpenInstallWizard(a,b,c)")],
            version: "11229305",
        )
        let report = SteamSurface.audit(bundle, at: "/steamui", entries: entries)
        #expect(report.entries == 5)
        #expect(report.found == 1)
        #expect(report.missing == 2)
        #expect(report.changed == 1)
        #expect(report.unchecked == 1)
        #expect(report.lines.count == 4)
        #expect(report.lines[0].hasPrefix("missing  global  uiStore: "))
        #expect(report.lines[0].hasSuffix("(the filters)"))
        #expect(report.lines.last == "Steam UI 11229305: 5 entries, 1 found, 2 missing, 1 changed, 1 unchecked")

        let decoded = try JSONDecoder().decode(SteamSurface.Report.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
        #expect(decoded.findings.map(\.status) == [.found, .missing, .missing, .unchecked, .changed])
    }

    // MARK: - Reading a folder

    @Test
    func `a folder's scripts and style sheets are read, its string tables left out`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("steamui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for sub in ["css", "localization", "libraries"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data("window.appStore=1".utf8).write(to: folder.appendingPathComponent("sp.js"))
        try Data("var x".utf8).write(to: folder.appendingPathComponent("libraries/libraries~1.js"))
        try Data(".a{}".utf8).write(to: folder.appendingPathComponent("css/sp.css"))
        try Data("strings".utf8).write(to: folder.appendingPathComponent("localization/steamui_english-json.js"))
        try Data("11229305\n".utf8).write(to: folder.appendingPathComponent("changelist.txt"))

        let bundle = try SteamUIBundle(folder: folder)
        #expect(bundle.scripts.map(\.path) == ["libraries/libraries~1.js", "sp.js"])
        #expect(bundle.styles.map(\.path) == ["css/sp.css"])
        #expect(bundle.version == "11229305")
    }

    @Test
    func `a folder with no script is refused`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: SteamUIBundle.LoadFailure.noScripts(folder.path)) { try SteamUIBundle(folder: folder) }
    }
}
