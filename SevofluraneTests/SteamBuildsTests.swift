import Foundation
import JavaScriptCore
import Testing
@testable import Sevoflurane

/// The two builds of Steam's UI: a made-up webpack bundle and a made-up
/// bundle of ES modules, each shaped like the client it stands for, read by
/// the audit's probes in Swift and by the page's resolver in JavaScriptCore.
@MainActor
struct SteamBuildsTests {
    // MARK: - A bundle of ES modules

    /// The library's chunk: each component the scripts read a class beside,
    /// minified the way the public beta of 2026-11-23 writes them.
    private static let mainChunk = #"""
    import{Tn as gt,Ka as ob}from"./chunk~shared.js?contenthash=1";
    var FBn=`cPlayButtonContainer-`,zBn=`cPlayButton-`,IBn=`cButtonChild-`,RBn=`cStreamingSelector-`;
    var PG=class extends q.Component{render(){let{overview:e,bShowStreamingSelector:r,bShowingPlayBar:s}=this.props,g=r&&e.per_client_data.length>1;return(0,Y.jsxs)(B,{className:U(n,f&&`cLongButton-`,FBn,!p&&`cDisabled-`,ee&&`cGreen-`,g&&`cShowingStreaming-`,s&&`cPlayBarShowing-`),children:[(0,Y.jsxs)(bc,{noFocusRing:!0,className:U(zBn,IBn,!S&&`cNoAction-`),ref:this.m_elActionButtonRef,onClick:te}),g&&(0,Y.jsx)(dVn,{overview:e,onClick:this.ShowStreamingMenu})]})}};
    function dVn(e){return(0,Y.jsxs)(bc,{noFocusRing:!0,className:U(RBn,IBn),onMouseUp:u,onClick:d,"aria-label":A(`#GameAction_PlayFrom`)})}
    function fVn(e){return(0,Y.jsxs)(aa,{label:A(`#GameAction_PlayFrom`),children:[]})}
    var xVn=`cAppDetailsButton-`,LG=class extends q.PureComponent{render(){let{className:e,...t}=this.props;return(0,Y.jsx)(W,{className:U(xVn,e),...t,children:this.props.children})}};function EVn(e){return(0,Y.jsx)(LG,{...e})}
    var VG=`cGameStat-`,iHn=`cGameStatIcon-`,HG=`cGameStatRight-`,zG=`cPlayBarLabel-`,UG=`cPlayBarDetailLabel-`,cHn=`cClickablePlayBarItem-`,IVn=`cGameStatsSection-`;
    function wWn(e){let i=yA();return(0,Y.jsxs)(`div`,{className:U(VG,aHn),onClick:()=>i.MyAchievements(t.unAppID),children:[(0,Y.jsx)(`div`,{className:U(iHn,rHn)}),(0,Y.jsxs)(`div`,{className:U(HG,void 0),children:[(0,Y.jsx)(`div`,{className:U(zG,void 0),children:A(`#AppDetails_SectionTitle_Achievements`)}),(0,Y.jsxs)(`div`,{className:oHn,children:[(0,Y.jsxs)(`div`,{className:U(UG,sHn),children:[1,`/`,2]})]})]})]})}
    function iK(e){return(0,Y.jsx)(rK,{classNames:U(eHn),force_icon:!0,icon:(0,Y.jsx)(Na,{}),label:A(`#AppDetails_SectionTitle_CloudStatus`),children:(0,Y.jsx)(EVn,{className:cHn,children:nK(e)})})}
    var BWn=class extends q.Component{render(){let o=this.BUserHasContentToClaim(this.props.details.unAppID);return(0,Y.jsxs)(`div`,{className:IVn,children:[o&&(0,Y.jsx)(aK,{...this.props})]})}};
    var g9t=`cSearchContainer-`;
    var Sea=class extends q.Component{render(){return(0,Y.jsxs)(`div`,{className:U(g9t,!t&&`cContainerHide-`),onKeyDown:this.OnKeyDown,ref:this.m_containerDivRef,tabIndex:-1,children:[(0,Y.jsx)(Bs,{placeholder:A(`#FilterEdit_SearchPrompt`)}),(0,Y.jsxs)(`div`,{className:U(`cAdvancedSearchContainer-`,!n&&`cSearchDisabled-`),children:[(0,Y.jsx)(lc,{toolTipContent:A(`#FilterEdit_AdvancedTooltip`)})]})]})}};
    var jUr=`cRowOuter-`,WUr=`cGameListEntryContainer-`;
    var oWr=V(function(e){let{item:t,strCollectionId:i}=e,_=U(jUr,c&&`cHoverOverlay-`),y=U(g&&`cCloudError-`,WUr);return(0,Y.jsx)(GZ,{appid:t.appid,children:(0,Y.jsx)(KJ,{strCollectionId:i,className:_,children:(0,Y.jsxs)(WJ,{className:y,appid:t.appid,strCollectionId:i,includeMultiSelect:!0,children:[(0,Y.jsx)(aWr,{item:t})]})})})});
    var IZi=`cLibraryItemBox-`,DQi=`cDraggable-`;
    var l7=V(function(e){let{app:r}=e,Ee=U(IZi,T,we,o&&`cShowAsHovered-`),De=U(DQi,t&&`cShort-`);return(0,Y.jsx)(W5,{role:ve,autoFocus:!1,className:Ee,onClick:_e,onContextMenu:ye,hoverDelay:300,onOKButton:_e,children:ke})});
    var aYi=`cBar-`,sYi=`cViewFiltersBar-`,uYi=`cFilters-`,dYi=`cCheckboxWithImage-`;
    var CYi=V(function(e){return(0,Y.jsxs)(`div`,{className:aYi,children:[(0,Y.jsx)(`div`,{className:sYi,children:(0,Y.jsxs)(`div`,{className:U(uYi,_&&`cFilterDisabled-`),children:[S&&(0,Y.jsxs)(lc,{toolTipContent:A(C?`#GameList_View_Platform_Linux`:`#GameList_View_Platform_Apple`),className:U(`cCheckboxWithImage-`,y&&`cFilterDisabled-`,w&&`cActive-`)}),(0,Y.jsx)(lc,{toolTipContent:A(`#GameList_View_SortByRecent`),className:U(dYi,_&&`cFilterDisabled-`,v&&`cActive-`)})]})})]})});
    function yur(e){let{overview:t,details:n,workshopVisible:r,marketPresence:i}=e;return(0,Y.jsx)(_J,{links:o,...e})}
    function Sur(e){return(0,Y.jsx)(B,{role:`link`,className:U(pur),children:e.label})}
    function Rya(e){let{appId:t}=e,o=[];return o.push({title:A(`#AppProperties_GeneralPage`)}),gt()&&o.push({title:A(`#AppProperties_CompatibilityPage`),route:Z.AppProperties.Compatibility()}),o}
    export{Rya as t};
    """#

    /// The entry script: its imports, and the chunk it loads on demand.
    private static let entryScript = #"""
    const __vite__mapDeps=(i,m=__vite__mapDeps,d=(m.f||(m.f=["./chunk~main.js?contenthash=2","./chunk~shared.js?contenthash=1","./css/chunk~main.css?contenthash=3"])))=>i.map(i=>d[i]);
    import{o as e,t}from"./chunk~shared.js?contenthash=1";var ca=J.lazy(()=>re(()=>import(`./chunk~main.js?contenthash=2`).then(e=>e.t),__vite__mapDeps([0,1,2])));
    """#

    private static let page = #"""
    <!doctype html><html><head><link rel="modulepreload" href="/chunk~shared.js?contenthash=1"><script type="module" src="/library.js?contenthash=0"></script></head></html>
    """#

    /// The class every recipe reads from ``mainChunk``.
    private static let expected: [String: String] = [
        "play.PlayButton": "cPlayButton-", "play.ButtonChild": "cButtonChild-",
        "play.ShowingStreaming": "cShowingStreaming-", "play.StreamingSelector": "cStreamingSelector-",
        "bar.GameStatsSection": "cGameStatsSection-", "bar.GameStat": "cGameStat-", "bar.GameStatIcon": "cGameStatIcon-",
        "bar.GameStatRight": "cGameStatRight-", "bar.PlayBarLabel": "cPlayBarLabel-",
        "bar.PlayBarDetailLabel": "cPlayBarDetailLabel-", "bar.ClickablePlayBarItem": "cClickablePlayBarItem-",
        "button.AppDetailsButton": "cAppDetailsButton-",
        "search.Container": "cSearchContainer-", "search.AdvancedSearchContainer": "cAdvancedSearchContainer-",
        "row.GameListEntryContainer": "cGameListEntryContainer-", "tile.LibraryItemBox": "cLibraryItemBox-",
        "filters.ViewFiltersBar": "cViewFiltersBar-", "filters.Filters": "cFilters-",
        "filters.CheckboxWithImage": "cCheckboxWithImage-", "filters.Active": "cActive-",
    ]

    private static func modulesBundle(main: String = mainChunk, styled: [String]? = nil) -> SteamUIBundle {
        let classes = styled ?? Array(expected.values)
        return SteamUIBundle(
            scripts: [
                .init(path: "chunk~main.js", text: main),
                .init(path: "chunk~shared.js", text: "function IsPlatformLinux(){return Config$1.PLATFORM==`linux`}export{IsPlatformLinux as Tn};"),
                .init(path: "library.js", text: entryScript),
            ],
            styles: [.init(path: "css/chunk~main.css", text: classes.map { ".\($0){display:flex}" }.joined())],
            version: "11255874", page: .init(path: "index.html", text: page),
        )
    }

    private static let webpackBundle = SteamUIBundle(
        scripts: [.init(
            path: "sp.js",
            text: #"(self.webpackChunksteamui=self.webpackChunksteamui||[]).push([[1],{76052:(we=>{we.exports={Container:"_1a",DeckVerifiedInfo:"IIJ"}})}]);"#,
        )],
        page: .init(path: "index.html", text: #"<html><script src="/sp.js"></script></html>"#),
    )

    private func entry(_ group: SteamSurface.ClassGroup) throws -> SteamSurface.Entry {
        try #require(SteamSurface.classMaps.first { $0.name == group.name })
    }

    private func registry() throws -> SteamSurface.Entry {
        try #require(SteamSurface.globals.first { $0.name == SteamSurface.webpackRegistry })
    }

    // MARK: - Which build

    @Test
    func `a bundle is webpack by its registry and ES modules by the page's entry script`() {
        #expect(Self.webpackBundle.build == .webpack)
        #expect(Self.modulesBundle().build == .modules)
        #expect(Self.modulesBundle().entry?.path == "library.js")
        #expect(SteamUIBundle(script: "function nothing(){}").build == nil)
        // A page with no module script is no build of ES modules, whatever its chunks hold.
        let pageless = SteamUIBundle(scripts: [.init(path: "library.js", text: Self.entryScript)])
        #expect(pageless.build == nil)
    }

    @Test
    func `the entry script's chunks are told apart: imported before it runs, or loaded on demand`() {
        let links = SteamUIBundle.File(path: "library.js", text: Self.entryScript).chunkLinks
        #expect(links.imported == ["./chunk~shared.js?contenthash=1"])
        #expect(links.onDemand == ["./chunk~main.js?contenthash=2"])
    }

    // MARK: - The audit, on ES modules

    @Test
    func `every class map has its counterpart in a bundle of ES modules`() throws {
        let bundle = Self.modulesBundle()
        for group in SteamSurface.ClassGroup.allCases {
            let (status, detail) = try SteamSurface.answer(for: entry(group), in: bundle)
            #expect(status == .found, "\(group.rawValue): \(detail)")
            #expect(detail.hasPrefix("ES modules: "))
        }
        let (status, detail) = try SteamSurface.answer(for: registry(), in: bundle)
        #expect(status == .found)
        #expect(detail == "ES modules: library.js imports 1 chunk and names 1 more")
    }

    @Test
    func `each recipe reads its class from the chunk`() {
        let chunk = SteamUIBundle.File(path: "chunk~main.js", text: Self.mainChunk)
        for recipe in SteamSurface.classRecipes {
            let id = "\(recipe.group.rawValue).\(recipe.key)"
            #expect(chunk.className(for: recipe) == Self.expected[id], "\(id)")
        }
        #expect(SteamSurface.classRecipes.count == Self.expected.count)
    }

    @Test
    func `a bundle of ES modules that lacks a class's code makes its map missing`() throws {
        // The Play button's ref goes: nothing says where its classes are.
        let renamed = Self.mainChunk.replacingOccurrences(of: "ref:this.m_elActionButtonRef", with: "ref:this.m_ref")
        let (status, detail) = try SteamSurface.answer(for: entry(.play), in: Self.modulesBundle(main: renamed))
        #expect(status == .missing)
        #expect(detail.contains("PlayButton, ButtonChild"))
        // ShowingStreaming is drawn without, so its loss alone is not named.
        #expect(!detail.contains("ShowingStreaming"))
        // A map whose code is whole is read all the same.
        #expect(try SteamSurface.answer(for: entry(.bar), in: Self.modulesBundle(main: renamed)).0 == .found)

        let unlinked = Self.mainChunk.replacingOccurrences(of: "workshopVisible", with: "showWorkshop")
        #expect(try SteamSurface.answer(for: entry(.strip), in: Self.modulesBundle(main: unlinked)).0 == .missing)

        let empty = Self.modulesBundle(main: "export{};")
        for group in SteamSurface.ClassGroup.allCases {
            #expect(try SteamSurface.answer(for: entry(group), in: empty).0 == .missing, "\(group.rawValue)")
        }
    }

    @Test
    func `a class no style sheet styles makes its map changed`() throws {
        let styled = Self.expected.values.filter { $0 != "cFilters-" }
        let (status, detail) = try SteamSurface.answer(for: entry(.filters), in: Self.modulesBundle(styled: styled))
        #expect(status == .changed)
        #expect(detail.contains("Filters as cFilters-"))
    }

    @Test
    func `a page of ES modules with no entry script or no imports has no way to Steam's modules`() throws {
        let bundle = Self.modulesBundle()
        let alone = SteamUIBundle(
            scripts: [.init(path: "library.js", text: "var a=1;")], page: bundle.page,
        )
        #expect(alone.build == .modules)
        let (status, detail) = try SteamSurface.answer(for: registry(), in: alone)
        #expect(status == .missing)
        #expect(detail == "library.js imports no chunk")
    }

    @Test
    func `a webpack bundle is answered by the webpack probes`() throws {
        #expect(try SteamSurface.answer(for: entry(.strip), in: Self.webpackBundle).0 == .found)
        #expect(try SteamSurface.answer(for: entry(.play), in: Self.webpackBundle).0 == .missing)
        let (status, detail) = try SteamSurface.answer(for: registry(), in: Self.webpackBundle)
        #expect(status == .found)
        #expect(detail == "assigned in sp.js")
        // Neither build: nothing is found.
        let neither = SteamUIBundle(script: "function nothing(){}")
        #expect(try SteamSurface.answer(for: registry(), in: neither).0 == .missing)
        #expect(try SteamSurface.answer(for: entry(.strip), in: neither).0 == .missing)
    }

    // MARK: - The resolver, in JavaScriptCore

    /// A page with no Steam in it: timers, and a `fetch` that serves `files`.
    private static let browser = """
    var window = this;
    var timers = [];
    function setTimeout(f) { timers.push(f); return timers.length; }
    function clearTimeout() {}
    var files = {};
    var fetched = [];
    function fetch(url) {
      fetched.push(url);
      var text = files[url];
      return Promise.resolve({ ok: text !== undefined, text: function () { return Promise.resolve(text); } });
    }
    """

    private func context(_ scripts: String...) throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript: \(exception?.toString() ?? "?")")
        }
        for script in [Self.browser] + scripts { context.evaluateScript(script) }
        return context
    }

    /// Steam's page as a build of ES modules: the entry script in the
    /// document, the files behind `fetch`, and the shared chunk's exports
    /// as the module the entry imports.
    private static func modulesPage(main: String = mainChunk) -> String {
        """
        var document = { scripts: [{ type: "", src: "https://steamloopback.host/shim.js" },
          { type: "module", src: "https://steamloopback.host/library.js?contenthash=0" }] };
        files["https://steamloopback.host/library.js?contenthash=0"] = \(JSLiteral.string(entryScript));
        files["https://steamloopback.host/chunk~main.js?contenthash=2"] = \(JSLiteral.string(main));
        var Config = { PLATFORM: "windows" };
        function IsPlatformWindows() { return Config.PLATFORM == "windows"; }
        function IsPlatformLinux() { return Config.PLATFORM == "linux"; }
        var mobx = function () {};
        mobx.box = function (value) { return { get: function () { return value; }, set: function (v) { value = v; } }; };
        var imported = [];
        var __sevoSteamBuild = { importModule: function (url) {
          imported.push(url);
          return Promise.resolve({ Dn: IsPlatformWindows, Tn: IsPlatformLinux, Ma: Config, Ka: mobx });
        } };
        """
    }

    private static let resolver = SteamPageResolver.source + "\nvar steam = steamSurface(window);"

    @Test
    func `the resolver tells the build once: webpack by its registry, ES modules by the entry script`() throws {
        let neither = try context(Self.resolver)
        #expect(neither.evaluateScript("steam.build()")?.isNull == true)
        #expect(neither.evaluateScript("steam.ready()")?.toBool() == false)
        #expect(neither.evaluateScript("steam.classes(['play'])")?.isNull == true)

        let webpack = try context("var webpackChunksteamui = { push: function (entry) { var r = function () {}; r.m = {}; entry[2](r); } };", Self.resolver)
        #expect(webpack.evaluateScript("steam.build()")?.toString() == "webpack")
        #expect(webpack.evaluateScript("steam.ready()")?.toBool() == true)
        #expect(webpack.evaluateScript("fetched.length")?.toInt32() == 0)

        let modules = try context(Self.modulesPage(), Self.resolver)
        #expect(modules.evaluateScript("steam.build()")?.toString() == "modules")
        // Told once: a registry that turns up later changes nothing.
        modules.evaluateScript("var webpackChunksteamui = { push: function () {} };")
        #expect(modules.evaluateScript("steam.build()")?.toString() == "modules")
    }

    @Test
    func `on webpack the class maps are the modules' exports, found by their keys`() throws {
        let page = """
        var sources = {
          1: 'e.exports={Container:"a",DeckVerifiedInfo:"b"}',
          2: 'e.exports={PlayButtonContainer:"c",StreamingSelector:"d",PlayButton:"e"}',
          3: 'e.exports={ActionSection:"f",GameStatsSection:"g"}',
          4: 'e.exports={DeckVerifiedInfo:"long"}' + new Array(5000).join(" ")
        };
        var exported = {
          1: { Container: "a", DeckVerifiedInfo: "b" }, 2: { PlayButtonContainer: "c", StreamingSelector: "d", PlayButton: "e" },
          3: { ActionSection: "f", GameStatsSection: "g" }, 4: { DeckVerifiedInfo: "long", Container: "long" }
        };
        var pushes = 0;
        var webpackChunksteamui = { push: function (entry) {
          pushes++;
          var require = function (id) { return exported[id]; };
          require.m = sources;
          entry[2](require);
        } };
        """
        let context = try context(page, Self.resolver)
        #expect(context.evaluateScript("JSON.stringify(steam.classes(['play', 'bar'], ['button']))")?.toString()
            == #"{"play":{"PlayButtonContainer":"c","StreamingSelector":"d","PlayButton":"e"},"bar":{"ActionSection":"f","GameStatsSection":"g"}}"#)
        // A required map that no module holds: nothing, and asked again next time.
        #expect(context.evaluateScript("steam.classes(['search', 'row', 'tile'], ['filters'])")?.isNull == true)
        // The strip's map is read only from a short module.
        #expect(context.evaluateScript("steam.classes(['strip']).strip.Container")?.toString() == "a")
        #expect(context.evaluateScript("pushes")?.toInt32() == 1)
        // The strip goes after the info block's next sibling, or inside the block.
        context.evaluateScript("""
        var tabBar = { id: "tabs" };
        var container = { parentElement: { nextElementSibling: tabBar } };
        var page = { querySelector: function (selector) { return selector === ".a" ? container : null; } };
        """)
        #expect(context.evaluateScript("steam.stripSlot(page).after === tabBar")?.toBool() == true)
        context.evaluateScript("container.parentElement.nextElementSibling = null;")
        #expect(context.evaluateScript("steam.stripSlot(page).inside === container")?.toBool() == true)
        #expect(context.evaluateScript("steam.stripSlot({ querySelector: function () { return null; } })")?.isNull == true)
    }

    @Test
    func `on ES modules the classes are read from the chunk the entry script loads on demand`() throws {
        let context = try context(Self.modulesPage(), Self.resolver)
        // The first ask starts the reading; the answer is there once it is done.
        #expect(context.evaluateScript("steam.classes(['play', 'bar'], ['button'])")?.isNull == true)
        let classes = try #require(context.evaluateScript("JSON.stringify(steam.classes(['play', 'bar'], ['button']))")?.toString())
        let maps = try #require(JSONSerialization.jsonObject(with: Data(classes.utf8)) as? [String: [String: String]])
        for (id, name) in Self.expected {
            let parts = id.split(separator: ".").map(String.init)
            guard ["play", "bar", "button"].contains(parts[0]) else { continue }
            #expect(maps[parts[0]]?[parts[1]] == name, "\(id)")
        }
        #expect(context.evaluateScript("steam.classes(['search', 'row', 'tile'], ['filters']).filters.Active")?.toString() == "cActive-")
        // The entry script, then the one chunk that holds everything.
        #expect(context.evaluateScript("fetched.join()")?.toString()
            == "https://steamloopback.host/library.js?contenthash=0,https://steamloopback.host/chunk~main.js?contenthash=2")
    }

    @Test
    func `the page reads each class as the audit does`() throws {
        let context = try context(Self.resolver)
        context.setObject(Self.mainChunk, forKeyedSubscript: "chunk" as NSString)
        context.setObject(SteamSurface.classRecipesLiteral, forKeyedSubscript: "recipes" as NSString)
        let read = try #require(context.evaluateScript(
            "JSON.stringify(JSON.parse(recipes).map(function (r) { return steam.read.className(chunk, r); }))",
        )?.toString())
        let names = try #require(JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String])
        let chunk = SteamUIBundle.File(path: "chunk~main.js", text: Self.mainChunk)
        #expect(names.count == SteamSurface.classRecipes.count)
        #expect(names == SteamSurface.classRecipes.compactMap { chunk.className(for: $0) })

        // The same on code of other shapes: a literal, a constant, a call, and nothing to read.
        let shapes = [
            "x({className:`a-`,k:`#T`})", "var c=`b-`;x({className:c,k:`#T`})", "var c=`b-`,d=J(c,`e-`);x({className:d,k:`#T`})",
            "x({className:J(q&&`f-`,r),k:`#T`})", "x({className:J(),k:`#T`})", "x({className:this.props.name,k:`#T`})",
            "x({k:`#T`})", "x({className:`not a class`,k:`#T`})", "nothing",
        ]
        let recipe = SteamSurface.ClassRecipe(.row, "X", beside: "#T")
        try context.setObject(String(decoding: JSONEncoder().encode(recipe), as: UTF8.self), forKeyedSubscript: "recipe" as NSString)
        for shape in shapes {
            context.setObject(shape, forKeyedSubscript: "shape" as NSString)
            let answer = context.evaluateScript("steam.read.className(shape, JSON.parse(recipe))")
            let page: String? = answer?.isNull == true ? nil : answer?.toString()
            #expect(page == SteamUIBundle.File(path: "x.js", text: shape).className(for: recipe), "\(shape)")
        }
        let links = try #require(context.evaluateScript(
            "JSON.stringify(steam.read.links(\(JSLiteral.string(Self.entryScript)), 'https://h/library.js?x=1'))",
        )?.toString())
        #expect(links == #"{"imported":["https://h/chunk~shared.js?contenthash=1"],"onDemand":["https://h/chunk~main.js?contenthash=2"]}"#)
    }

    @Test
    func `a chunk that lacks a class's code leaves its map out, and the scripts draw nothing with it`() throws {
        let renamed = Self.mainChunk.replacingOccurrences(of: "ref:this.m_elActionButtonRef", with: "ref:this.m_ref")
            .replacingOccurrences(of: "PureComponent{render(){", with: "Component{render(){")
        let context = try context(Self.modulesPage(main: renamed), Self.resolver)
        context.evaluateScript("steam.classes(['row'])")
        // The Play button's classes are required by the version menu: no answer at all.
        #expect(context.evaluateScript("steam.classes(['play', 'bar'], ['button'])")?.isNull == true)
        // The compact button is optional: the play bar's map comes without it.
        #expect(context.evaluateScript("Object.keys(steam.classes(['bar'], ['button'])).join()")?.toString() == "bar")
        #expect(context.evaluateScript("steam.classes(['row']).row.GameListEntryContainer")?.toString() == "cGameListEntryContainer-")
    }

    @Test
    func `a chunk that will not load is asked for again only after a while`() throws {
        let context = try context(Self.modulesPage(), "var now = 1000000; Date.now = function () { return now; }; files = {};", Self.resolver)
        #expect(context.evaluateScript("steam.classes(['row'])")?.isNull == true)
        #expect(context.evaluateScript("steam.classes(['row'])")?.isNull == true)
        #expect(context.evaluateScript("fetched.length")?.toInt32() == 1)
        #expect(context.evaluateScript("__sevoSteamBuild.failure")?.toString() == "the entry script did not load")
        context.evaluateScript("now += 30000; steam.classes(['row'])")
        #expect(context.evaluateScript("fetched.length")?.toInt32() == 2)
    }

    // MARK: - Steam's modules on ES modules

    @Test
    func `on ES modules the Compatibility page is listed through the entry script's imports and the chunk's text`() throws {
        let page = Self.modulesPage() + """
        var platforms = { 1: ["windows", "osx"], 2: ["windows"] };
        var appDetailsStore = { GetAppDetails: function (id) { return platforms[id] ? { vecPlatforms: platforms[id] } : null; } };
        function Rya(appid) { appDetailsStore.GetAppDetails(appid); return IsPlatformLinux(); }
        function keyboard(appid) { appDetailsStore.GetAppDetails(appid); return IsPlatformLinux(); }
        """
        let context = try context(page)
        // The text and the modules arrive after the first ask.
        #expect(context.evaluateScript(SteamNativeBuilds.contextScript)?.toString() == "waiting")
        #expect(context.evaluateScript(SteamNativeBuilds.contextScript)?.toString() == "installed")
        #expect(context.evaluateScript("imported.join()")?.toString() == "https://steamloopback.host/chunk~shared.js?contenthash=1")
        #expect(context.evaluateScript("__sevoNativeBuilds.test")?.toString() == "IsPlatformLinux")
        #expect(context.evaluateScript("JSON.stringify(__sevoNativeBuilds.pages)")?.toString() == "[\"Rya\"]")
        #expect(context.evaluateScript("Rya(1)")?.toBool() == true)
        #expect(context.evaluateScript("Rya(2)")?.toBool() == false)
        #expect(context.evaluateScript("keyboard(1)")?.toBool() == false)
        #expect(context.evaluateScript("Config.PLATFORM")?.toString() == "windows")
    }

    @Test
    func `on ES modules a chunk without the page's label keeps native builds on and the platform alone`() throws {
        let unlabeled = Self.mainChunk.replacingOccurrences(of: "#AppProperties_CompatibilityPage", with: "#AppProperties_Other")
        let context = try context(Self.modulesPage(main: unlabeled), "var appDetailsStore = { GetAppDetails: function () { return null; } };")
        context.evaluateScript(SteamNativeBuilds.contextScript)
        #expect(context.evaluateScript(SteamNativeBuilds.contextScript)?.toString()
            == "installed without the Compatibility page: no function holds the page's label")
        #expect(context.evaluateScript("Config.PLATFORM")?.toString() == "windows")
    }

    @Test
    func `on ES modules the library's filter is found from the UI store and MobX from the entry script's imports`() throws {
        let page = Self.modulesPage() + """
        var stored = {};
        var localStorage = { getItem: function (k) { return k in stored ? stored[k] : null; }, setItem: function (k, v) { stored[k] = String(v); } };
        files["/__compat/batch"] = "";
        var answer = { pending: 0, apps: { "1": { p: true }, "2": { p: false } } };
        var page = fetch;
        fetch = function (url, options) {
          return url === "/__compat/batch" ? Promise.resolve({ ok: true, json: function () { return Promise.resolve(answer); } }) : page(url, options);
        };
        class Filter {
          MatchesImpl(app) { return true; }
          MatchesScoredImpl(app) { return 1; }
          get bIsEmpty() { return true; }
        }
        class LibraryFilter extends Filter {
          MatchesImpl(app) { return app.appid !== 99 && super.MatchesImpl(app); }
        }
        var uiStore = { collectionsAppFilter: new LibraryFilter() };
        uiStore.currentAppFilter = uiStore.collectionsAppFilter;
        var collectionStore = { allAppsCollection: { allApps: [
          { appid: 1, app_type: 1, display_name: "One" }, { appid: 2, app_type: 1, display_name: "Two" }
        ] } };
        """
        let context = try context(page)
        #expect(context.evaluateScript(SteamLibraryCompat.contextScript)?.toString() == "waiting")
        #expect(context.evaluateScript(SteamLibraryCompat.contextScript)?.toString() == "installed")
        #expect(context.evaluateScript("__sevoLibraryCompat.available")?.toBool() == true)
        context.evaluateScript("__sevoLibraryCompat.toggle()")
        #expect(context.evaluateScript("[1, 2].map(function (id) { return uiStore.collectionsAppFilter.MatchesImpl({ appid: id }); }).join()")?
            .toString() == "true,false")
        // Another instance of the class is a dynamic collection's, and untouched.
        #expect(context.evaluateScript("new LibraryFilter().MatchesImpl({ appid: 2 })")?.toBool() == true)
    }

    // MARK: - The strip's place on ES modules

    /// A game page as React draws it: the links bar's component, the
    /// element it draws, and a link inside, each with its fiber.
    private static let gamePage = """
    function El(name) { this.name = name; this.nodeType = 1; this.parentElement = null; this.inside = []; }
    El.prototype.contains = function (other) { return other === this || this.inside.indexOf(other) !== -1; };
    function fiber(node, props, parent) {
      var made = { stateNode: node, memoizedProps: props, return: parent || null, child: null };
      if (parent && !parent.child) parent.child = made;
      if (node && node.nodeType === 1) node["__reactFiber$abc"] = made;
      return made;
    }
    var pageElement = new El("page"), bar = new El("bar"), row = new El("row"), link = new El("link"), other = new El("other");
    bar.parentElement = pageElement; row.parentElement = bar; link.parentElement = row; bar.inside = [row, link];
    var pageFiber = fiber(pageElement, { className: "page" });
    var links = fiber(null, { overview: {}, details: {}, workshopVisible: false, marketPresence: true }, pageFiber);
    var barFiber = fiber(bar, { role: "region" }, fiber({ render: function () {} }, { links: [] }, links));
    var linkFiber = fiber(link, { role: "link" }, fiber(null, { label: "Store Page" }, fiber(row, {}, barFiber)));
    fiber(other, { role: "link" }, fiber(null, { label: "A news link" }, pageFiber));
    function documentOf(found) { return { querySelectorAll: function (selector) { return selector === '[role="link"]' ? found : []; } }; }
    """

    @Test
    func `on ES modules the strip goes after the element the links bar's component draws`() throws {
        let context = try context(Self.modulesPage(), Self.gamePage, Self.resolver)
        #expect(context.evaluateScript("steam.stripSlot(documentOf([other, link])).after === bar")?.toBool() == true)
        // A page with links and no links bar, and a page with none: no place, so no strip.
        #expect(context.evaluateScript("steam.stripSlot(documentOf([other]))")?.isNull == true)
        #expect(context.evaluateScript("steam.stripSlot(documentOf([]))")?.isNull == true)
        // Props of another name are another component.
        context.evaluateScript("delete links.memoizedProps.marketPresence;")
        #expect(context.evaluateScript("steam.stripSlot(documentOf([link]))")?.isNull == true)
        // Nothing was fetched to find it.
        #expect(context.evaluateScript("fetched.length")?.toInt32() == 0)
    }
}
