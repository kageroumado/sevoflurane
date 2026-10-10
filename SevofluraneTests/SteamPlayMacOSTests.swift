import Foundation
import JavaScriptCore
import Testing
@testable import Sevoflurane

/// Native macOS builds through the bottle's Steam: the compatibility tool's
/// files, the mappings in `config.vdf`, the client's Steam Play switch, and
/// the choice the game page offers.
@MainActor
struct SteamPlayMacOSTests {
    // MARK: - Text KeyValues

    @Test
    func `text KeyValues reads nested tables, escapes and comments`() throws {
        let text = """
        // written by Steam
        "Root"
        {
        \t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
        \t"Inner" [$WIN32]
        \t{
        \t\t"quote"\t"say \\"hi\\""
        \t}
        }
        """
        let root = try #require(TextKeyValues.parse(text))
        #expect(root.at(["Root", "path"])?.string == "C:\\Program Files (x86)\\Steam")
        #expect(root.at(["root", "inner", "QUOTE"])?.string == "say \"hi\"")
        #expect(TextKeyValues.parse("\"a\" { \"b\" \"c\"") == nil)
        #expect(TextKeyValues.parse("\"a\" } ") == nil)
    }

    // MARK: - The tool's files

    @Test
    func `the tool declares a macOS build run from Windows Steam through the engine's launcher`() throws {
        let tool = try #require(TextKeyValues.parse(SteamPlayMacOS.compatibilityToolVDF))
        let entry = try #require(tool.at(["compatibilitytools", "compat_tools", SteamPlayMacOS.toolName]))
        #expect(entry["install_path"]?.string == ".")
        #expect(entry["display_name"]?.string == SteamPlayMacOS.displayName)
        #expect(entry["from_oslist"]?.string == "macos")
        #expect(entry["to_oslist"]?.string == "windows")
        let manifest = try #require(TextKeyValues.parse(SteamPlayMacOS.toolManifestVDF))
        #expect(manifest.at(["manifest", "version"])?.string == "2")
        #expect(manifest.at(["manifest", "commandline"])?.string == "/sevo-native.exe %verb%")
    }

    @Test
    func `registering writes the tool once, copies the launcher, and removes the test tool`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "steam-play-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let steam = root.appending(path: "Steam")
        let engine = root.appending(path: "engine")
        let legacy = SteamPlayMacOS.toolsDirectory(steamRoot: steam).appending(path: "sevo_macos")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)

        // An engine without the launcher still gets the tool's files.
        let first = SteamPlayMacOS.register(steamRoot: steam, engineRoot: engine)
        let tool = SteamPlayMacOS.toolDirectory(steamRoot: steam)
        #expect(first.contains("wrote compatibilitytool.vdf"))
        #expect(first.contains("wrote toolmanifest.vdf"))
        #expect(first.contains("removed the old tool sevo_macos"))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try String(contentsOf: tool.appending(path: "compatibilitytool.vdf"), encoding: .utf8)
            == SteamPlayMacOS.compatibilityToolVDF)
        #expect(!FileManager.default.fileExists(atPath: tool.appending(path: "sevo-native.exe").path))

        try Data("MZ launcher".utf8).write(to: engine.appending(path: "sevo-native.exe"))
        #expect(SteamPlayMacOS.register(steamRoot: steam, engineRoot: engine) == ["copied sevo-native.exe from the engine"])
        #expect(try Data(contentsOf: tool.appending(path: "sevo-native.exe")) == Data("MZ launcher".utf8))
        // Nothing changed, so nothing is written.
        #expect(SteamPlayMacOS.register(steamRoot: steam, engineRoot: engine).isEmpty)
    }

    // MARK: - Mappings

    private static let config = """
    "InstallConfigStore"
    {
    \t"Software"
    \t{
    \t\t"Valve"
    \t\t{
    \t\t\t"Steam"
    \t\t\t{
    \t\t\t\t"name"\t\t"sevo_macos"
    \t\t\t\t"CompatToolMapping"
    \t\t\t\t{
    \t\t\t\t\t"0"
    \t\t\t\t\t{
    \t\t\t\t\t\t"name"\t\t"proton_9"
    \t\t\t\t\t}
    \t\t\t\t\t"540610"
    \t\t\t\t\t{
    \t\t\t\t\t\t"name"\t\t"sevo_macos"
    \t\t\t\t\t\t"config"\t\t""
    \t\t\t\t\t\t"priority"\t\t"250"
    \t\t\t\t\t}
    \t\t\t\t\t"1309000"
    \t\t\t\t\t{
    \t\t\t\t\t\t"name"\t\t"sevoflurane_macos"
    \t\t\t\t\t\t"config"\t\t""
    \t\t\t\t\t\t"priority"\t\t"250"
    \t\t\t\t\t}
    \t\t\t\t\t"698780"
    \t\t\t\t\t{
    \t\t\t\t\t\t"name"\t\t""
    \t\t\t\t\t}
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t}
    }
    """

    @Test
    func `config vdf names each mapped game and its tool`() {
        #expect(SteamPlayMacOS.mappings(inConfig: Self.config) == [540_610: "sevo_macos", 1_309_000: "sevoflurane_macos"])
        #expect(SteamPlayMacOS.mappings(inConfig: "").isEmpty)
    }

    @Test
    func `mappings to the test tool move to the shipped one and nothing else changes`() throws {
        let migrated = try #require(SteamPlayMacOS.migratingMappings(inConfig: Self.config))
        #expect(SteamPlayMacOS.mappings(inConfig: migrated) == [540_610: "sevoflurane_macos", 1_309_000: "sevoflurane_macos"])
        // Only the mapping's value changes; the same name outside
        // CompatToolMapping is someone else's value.
        let mapping = "\"name\"\t\t\"%@\"\n\t\t\t\t\t\t\"config\""
        #expect(migrated == Self.config.replacingOccurrences(
            of: String(format: mapping, "sevo_macos"), with: String(format: mapping, "sevoflurane_macos"),
        ))
        #expect(migrated.contains("\t\t\t\t\"name\"\t\t\"sevo_macos\"\n\t\t\t\t\"CompatToolMapping\""))
        #expect(SteamPlayMacOS.migratingMappings(inConfig: migrated) == nil)
    }

    @Test
    func `migration rewrites config vdf on disk and reports how many games moved`() throws {
        let steam = FileManager.default.temporaryDirectory.appending(path: "steam-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: steam) }
        let url = SteamPlayMacOS.configURL(steamRoot: steam)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.config.write(to: url, atomically: true, encoding: .utf8)
        #expect(SteamPlayMacOS.migrateMappings(steamRoot: steam) == 1)
        #expect(SteamPlayMacOS.mappedApps(steamRoot: steam) == [540_610, 1_309_000])
        #expect(SteamPlayMacOS.migrateMappings(steamRoot: steam) == 0)
    }

    // MARK: - The client's switch

    @Test
    func `only an engine that declares the feature switches Steam Play on`() {
        #expect(Engine.features(inEngineInfo: ["features": ["env-files", "steam-play-macos"]]).contains(SteamPlayMacOS.feature))
        #expect(!Engine.features(inEngineInfo: ["features": ["env-files"]]).contains(SteamPlayMacOS.feature))
        #expect(Engine.features(inEngineInfo: [:]).isEmpty)
    }

    @Test
    func `steam exe gets its own env file with Steam Play on, and only then`() {
        let files = ["game.exe.env": ["# app 1", "SEVO_FPS=1"]]
        #expect(ConfigMaterializer.withClientFile(files, steamPlay: false) == files)
        let on = ConfigMaterializer.withClientFile(files, steamPlay: true)
        #expect(on["steam.exe.env"] == ["SEVO_STEAM_PLAY=1"])
        #expect(on["game.exe.env"] == files["game.exe.env"])
        // A game that ships a steam.exe keeps its lines; the switch is added once.
        let claimed = ["steam.exe.env": ["# app 7", "SEVO_STEAM_PLAY=1", "SEVO_FPS=1"]]
        #expect(ConfigMaterializer.withClientFile(claimed, steamPlay: true)["steam.exe.env"]
            == ["# app 7", "SEVO_FPS=1", "SEVO_STEAM_PLAY=1"])
    }

    @Test
    func `the library answer marks games set to their macOS build`() throws {
        let data = GameCompatBatch.answer([
            GameCompatSummary(appID: 1, state: .unknown, native: false),
            GameCompatSummary(appID: 2, state: .verified, native: false),
            GameCompatSummary(appID: 3, state: .unknown, native: false),
        ], pending: 0, macBuilds: [1, 2])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apps = try #require(object["apps"] as? [String: [String: Any]])
        #expect(Set(apps.keys) == ["1", "2"])
        #expect(apps["1"]?["m"] as? Bool == true)
        #expect(apps["2"]?["m"] as? Bool == true)
    }

    /// A 32-bit-only macOS build, or one rated broken beside an unsupported
    /// Windows build, stays out of the Apple filter however it is mapped.
    @Test
    func `a game set to its macOS build plays on this Mac only on the evidence`() throws {
        let data = GameCompatBatch.answer([
            GameCompatSummary(appID: 1, state: .unsupported, native: false),
            GameCompatSummary(appID: 2, state: .unknown, native: false, macRunnable: false),
            GameCompatSummary(appID: 3, state: .unknown, native: false, macRunnable: true),
            GameCompatSummary(appID: 4, state: .playable, native: false, macEvidence: true),
        ], pending: 0, macBuilds: [1, 2, 3])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apps = try #require(object["apps"] as? [String: [String: Any]])
        #expect(apps["1"]?["m"] as? Bool == true)
        #expect(apps["1"]?["p"] == nil)
        #expect(apps["2"]?["m"] as? Bool == true)
        #expect(apps["2"]?["p"] == nil)
        #expect(apps["3"]?["p"] as? Bool == true)
        #expect(apps["4"]?["p"] as? Bool == true)
        #expect(apps["4"]?["m"] == nil)
    }

    // MARK: - The choice on the game page

    /// Escape Dungeon 2's depots as the client's app cache lists them: one per
    /// platform and a DLC.
    private static let escapeDungeon: [String: SteamAppInfo.Value] = [
        "common": .table(["oslist": .string("windows,macos")]),
        "depots": .table([
            "baselanguages": .string("english,japanese"),
            "1309002": .table([
                "config": .table(["oslist": .string("windows")]),
                "manifests": .table(["public": .table(["size": .number(1_741_273_889), "download": .number(403_880_752)])]),
            ]),
            "1309003": .table([
                "config": .table(["oslist": .string("macos")]),
                "manifests": .table(["public": .table(["size": .number(1_765_620_218), "download": .number(411_993_712)])]),
            ]),
            "4045770": .table([
                "dlcappid": .number(4_045_770),
                "manifests": .table(["public": .table(["download": .number(1_416_577_616)])]),
            ]),
            "1309004": .table([
                "config": .table(["language": .string("japanese")]),
                "manifests": .table(["public": .table(["download": .number(5_000_000)])]),
            ]),
        ]),
    ]

    /// Doki Doki Literature Club: one depot that serves both platforms.
    private static let sharedDepot: [String: SteamAppInfo.Value] = [
        "common": .table(["oslist": .string("windows,macos")]),
        "depots": .table([
            "698781": .table(["manifests": .table(["public": .table(["download": .number(223_311_600)])])]),
        ]),
    ]

    private static func manifest(depots: [Int]) -> String {
        let entries = depots.map { "\t\t\"\($0)\"\n\t\t{\n\t\t\t\"manifest\"\t\t\"1\"\n\t\t}\n" }.joined()
        return "\"AppState\"\n{\n\t\"appid\"\t\t\"1\"\n\t\"InstalledDepots\"\n\t{\n\(entries)\t}\n}\n"
    }

    @Test
    func `each build's download counts the depots it needs and nothing optional`() {
        let depots = NativeBuildInfo.depots(inAppInfo: Self.escapeDungeon)
        #expect(depots.map(\.id) == [1_309_002, 1_309_003, 1_309_004, 4_045_770])
        #expect(NativeBuildInfo.download(for: .macos, depots: depots) == 411_993_712)
        #expect(NativeBuildInfo.download(for: .windows, depots: depots) == 403_880_752)
        #expect(!NativeBuildInfo.sameFiles(depots))
        let shared = NativeBuildInfo.depots(inAppInfo: Self.sharedDepot)
        #expect(NativeBuildInfo.download(for: .macos, depots: shared) == 223_311_600)
        #expect(NativeBuildInfo.sameFiles(shared))
    }

    @Test
    func `the installed build is read off the depots the manifest lists`() {
        let depots = NativeBuildInfo.depots(inAppInfo: Self.escapeDungeon)
        #expect(NativeBuildInfo.installedBuild(manifest: Self.manifest(depots: [1_309_003]), depots: depots) == .macos)
        #expect(NativeBuildInfo.installedBuild(manifest: Self.manifest(depots: [1_309_002, 4_045_770]), depots: depots) == .windows)
        #expect(NativeBuildInfo.installedBuild(manifest: Self.manifest(depots: []), depots: depots) == nil)
        let shared = NativeBuildInfo.depots(inAppInfo: Self.sharedDepot)
        #expect(NativeBuildInfo.installedBuild(manifest: Self.manifest(depots: [698_781]), depots: shared) == nil)
    }

    @Test
    func `the macOS build is suggested unless the Windows build is rated better`() {
        let perfect = GameCompatBadge(state: .verified, label: "Perfect", reason: "")
        let playable = GameCompatBadge(state: .playable, label: "Playable", reason: "")
        let broken = GameCompatBadge(state: .unsupported, label: "Broken", reason: "")
        let unknown = GameCompatBadge(state: .unknown, label: "Unknown", reason: "")
        #expect(NativeBuildInfo.recommendation(native: unknown, windows: unknown) == .macos)
        #expect(NativeBuildInfo.recommendation(native: playable, windows: playable) == .macos)
        #expect(NativeBuildInfo.recommendation(native: unknown, windows: playable) == .windows)
        #expect(NativeBuildInfo.recommendation(native: broken, windows: unknown) == .windows)
        #expect(NativeBuildInfo.recommendation(native: perfect, windows: playable) == .macos)
        #expect(NativeBuildInfo.macHint(perfect) == "Built for macOS · Perfect")
        #expect(NativeBuildInfo.macHint(unknown) == "Built for macOS")
        #expect(NativeBuildInfo.windowsHint(playable) == "Runs through Sevoflurane · Playable")
        #expect(NativeBuildInfo.windowsHint(nil) == "Runs through Sevoflurane")
    }

    @Test
    func `the page's answer puts the pieces together`() throws {
        let info = NativeBuildInfo.make(
            appID: 1_309_000, enabled: true, appInfo: Self.escapeDungeon,
            manifest: Self.manifest(depots: [1_309_003]), record: nil,
        )
        #expect(info.enabled && info.hasMacBuild && info.runnable && !info.sameFiles)
        #expect(info.installed == .macos)
        #expect(info.recommended == .macos)
        #expect(info.tool == "sevoflurane_macos")
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        #expect(json["macDownload"] as? Int == 411_993_712)
        #expect(json["installed"] as? String == "macos")
        let none = NativeBuildInfo.make(appID: 1, enabled: false, appInfo: nil, manifest: nil, record: nil)
        #expect(!none.hasMacBuild && none.macDownload == nil && none.installed == nil && !none.sameFiles)
    }

    // MARK: - The page scripts

    @Test
    func `the page scripts parse`() throws {
        let context = try #require(JSContext())
        for script in [
            SteamNativeBuilds.contextScript, SteamNativeBuilds.contextRemovalScript,
            SteamNativeBuilds.script, SteamNativeBuilds.removalScript,
            SteamLibraryCompat.script, SteamCompatBadge.script, SteamCompatBadge.storeScript,
        ] {
            context.setObject(script, forKeyedSubscript: "source" as NSString)
            let result = context.evaluateScript("try { new Function(source); 'ok' } catch (e) { String(e) }")?.toString()
            #expect(result == "ok")
        }
    }

    /// Steam's platform module, its properties page list and its details
    /// store, faked just enough for the context script to run. Module sources
    /// are the strings the script searches; `C` and `dt` are the functions
    /// those sources name, so the stack the getter reads is a real one.
    private static let steam = """
    var window = this;
    var TS = { PLATFORM: "windows" };
    var platformSource = 'r.d(t,{CI:()=>C,TS:()=>a.TS});function w(){return"windows"==a.TS.PLATFORM}function C(){return"linux"==a.TS.PLATFORM}';
    var pageSource = 'function dt(e){const{appId:t}=e,r=(0,p.T)(t);const o=[];return o.push({title:(0,A.we)("#AppProperties_GeneralPage")}),(0,f.CI)()&&o.push({title:(0,A.we)("#AppProperties_CompatibilityPage"),route:F.BV.AppProperties.Compatibility()}),o}';
    var modules = { 10: platformSource, 20: pageSource, 30: 'function other(){}' };
    var req = function (id) { if (String(id) === "10") return { TS: TS }; throw new Error("not loaded"); };
    req.m = modules;
    var webpackChunksteamui = { push: function (entry) { entry[2](req); } };
    var platforms = { 1: ["windows", "osx"], 2: ["windows"] };
    var appDetailsStore = { GetAppDetails: function (id) { return platforms[id] ? { vecPlatforms: platforms[id] } : null; } };
    function C() { return "linux" == TS.PLATFORM; }
    function dt(appid) { appDetailsStore.GetAppDetails(appid); return C(); }
    function keyboard(appid) { appDetailsStore.GetAppDetails(appid); return C(); }
    """

    @Test
    func `the Compatibility page is listed for a game with a macOS build and every other Linux test keeps its answer`() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.steam)
        #expect(context.evaluateScript(SteamNativeBuilds.contextScript)?.toString() == "installed")
        #expect(context.evaluateScript("JSON.stringify(window.__sevoNativeBuilds.pages)")?.toString() == "[\"dt\"]")
        // The page list, for a game with a macOS build and for one without.
        #expect(context.evaluateScript("dt(1)")?.toBool() == true)
        #expect(context.evaluateScript("dt(2)")?.toBool() == false)
        // The same test from anywhere else, and the platform read directly.
        #expect(context.evaluateScript("keyboard(1)")?.toBool() == false)
        #expect(context.evaluateScript("TS.PLATFORM")?.toString() == "windows")
        // Switched off, the page list goes back to Steam's rule.
        #expect(context.evaluateScript(SteamNativeBuilds.contextRemovalScript)?.toString() == "removed")
        #expect(context.evaluateScript("dt(1)")?.toBool() == false)
        #expect(context.evaluateScript(SteamNativeBuilds.contextScript)?.toString() == "reapplied")
        #expect(context.evaluateScript("dt(1)")?.toBool() == true)
    }

    /// The desktop window, Steam's client calls and its stores, faked just
    /// enough for the version menu to open and a choice to run. `mapping` is
    /// what `SpecifyCompatTool` does: reject, apply, or resolve without the
    /// details ever showing it.
    private static func desktop(mapping: String) -> String {
        """
        var window = this;
        var innerWidth = 1000, innerHeight = 800;
        var timers = [];
        function setTimeout(f) { timers.push(f); return timers.length; }
        function clearTimeout() {}
        function runTimers() { for (var i = 0; i < 50 && timers.length; i++) timers.shift()(); }
        function El() { this.innerHTML = ""; this.style = {}; this.dataset = {}; this.isConnected = false; }
        El.prototype.setAttribute = function () {};
        El.prototype.getBoundingClientRect = function () { return { left: 0, top: 0, bottom: 10 }; };
        El.prototype.querySelector = function (selector) {
          return this.innerHTML.indexOf(selector.slice(1)) !== -1 ? { focus: function () {} } : null;
        };
        El.prototype.remove = function () { this.isConnected = false; };
        var made = [];
        var document = {
          head: new El(), body: { appendChild: function (e) { e.isConnected = true; } },
          createElement: function () { var e = new El(); made.push(e); return e; },
          getElementById: function () { return null; },
          querySelectorAll: function () { return []; },
          addEventListener: function () {}
        };
        function MutationObserver() {} MutationObserver.prototype.observe = function () {};
        function addEventListener() {}
        var info = { enabled: true, hasMacBuild: true, runnable: true, sameFiles: false, installed: "windows",
          recommended: "macos", macHint: "", windowsHint: "", tool: "sevoflurane_macos" };
        function fetch() { return Promise.resolve({ ok: true, json: function () { return Promise.resolve(info); } }); }
        var detailsOf7 = { vecPlatforms: ["windows", "osx"], strCompatToolName: "" };
        var appDetailsStore = { GetAppDetails: function () { return detailsOf7; } };
        var appStore = { GetAppOverviewByAppID: function () { return { app_type: 1, display_name: "Seven", installed: false }; } };
        var MainWindowBrowserManager = { m_lastLocation: { pathname: "/library/app/7" } };
        var wizard = [];
        var invalidated = 0;
        var __sevoLibraryCompat = { invalidate: function () { invalidated++; } };
        var SteamClient = {
          Installs: { OpenInstallWizard: function (ids) { wizard.push(ids); } },
          Apps: { SpecifyCompatTool: function (appid, tool) {
            var mapping = \(JSLiteral.string(mapping));
            if (mapping === "reject") return Promise.reject(new Error("refused"));
            if (mapping === "apply") detailsOf7.strCompatToolName = tool;
            return Promise.resolve();
          } }
        };
        """
    }

    private static func openChooser(_ context: JSContext) {
        context.evaluateScript(SteamNativeBuilds.script)
        // A choice before the bridge has answered asks it and does nothing more.
        context.evaluateScript("__sevoNativeMenu.choose(7, 'windows', 'install');")
        // The answer is in; the Install menu opens under its button.
        context.evaluateScript("var anchor = new El(); anchor.isConnected = true;")
        context.evaluateScript("__sevoNativeMenu.openMenu(anchor, 7, info, 'install');")
    }

    @Test
    func `a platform change Steam refuses keeps the wizard closed and offers a retry`() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.desktop(mapping: "reject"))
        Self.openChooser(context)
        context.evaluateScript("__sevoNativeMenu.choose(7, 'macos', 'install');")
        context.evaluateScript("runTimers();")
        func js(_ source: String) -> String? { context.evaluateScript(source)?.toString() }
        #expect(js("wizard.length") == "0")
        #expect(js("invalidated") == "0")
        let panel = js("made.filter(function (e) { return e.isConnected; }).map(function (e) { return e.innerHTML; }).join()") ?? ""
        #expect(panel.contains("sevo-native-retry"))
        #expect(panel.contains(#"data-platform="macos" data-mode="install""#))
        #expect(panel.contains("Steam did not set the macOS version"))
    }

    @Test
    func `a platform change opens the wizard once the details show it`() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.desktop(mapping: "apply"))
        Self.openChooser(context)
        context.evaluateScript("__sevoNativeMenu.choose(7, 'macos', 'install');")
        func js(_ source: String) -> String? { context.evaluateScript(source)?.toString() }
        #expect(js("JSON.stringify(wizard)") == "[[7]]")
        #expect(js("invalidated") == "1")
        #expect(js("made.filter(function (e) { return e.isConnected; }).length") == "0")
    }

    @Test
    func `a platform change the details never show is a failure`() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.desktop(mapping: "silent"))
        Self.openChooser(context)
        context.evaluateScript("__sevoNativeMenu.choose(7, 'macos', 'install');")
        context.evaluateScript("runTimers();")
        func js(_ source: String) -> String? { context.evaluateScript(source)?.toString() }
        #expect(js("wizard.length") == "0")
        #expect(js("made.filter(function (e) { return e.isConnected; }).map(function (e) { return e.innerHTML; }).join()")?
            .contains("sevo-native-retry") == true)
    }

    @Test
    func `the switch menu marks the build on disk as installed, whatever the mapping`() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.desktop(mapping: "apply"))
        context.evaluateScript(SteamNativeBuilds.script)
        // Set to macOS while the Windows depots are still the ones on disk.
        context.evaluateScript("detailsOf7.strCompatToolName = 'sevoflurane_macos'; var anchor = new El(); anchor.isConnected = true;")
        context.evaluateScript("__sevoNativeMenu.openMenu(anchor, 7, info, 'switch');")
        let html = context.evaluateScript("made[made.length - 1].innerHTML")?.toString() ?? ""
        let windows = try #require(html.range(of: #"data-platform="windows""#))
        let installed = try #require(html.range(of: "Installed</span>"))
        #expect(installed.lowerBound > windows.lowerBound)
        #expect(html.contains(#"sevo-native-current" role="menuitemradio" tabindex="0" aria-checked="true" data-platform="macos""#))
    }

    @Test
    func `a Steam build without the shape leaves the platform alone`() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.steam)
        context.evaluateScript("modules[20] = 'function dt(e){return (0,f.CI)()}';")
        #expect(context.evaluateScript(SteamNativeBuilds.contextScript)?.toString() == "unavailable")
        #expect(context.evaluateScript("dt(1)")?.toBool() == false)
    }
}
