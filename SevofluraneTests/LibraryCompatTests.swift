import Foundation
import JavaScriptCore
import Testing
@testable import Sevoflurane

/// The library's bulk verdicts and the "Plays on Mac" filter.
@MainActor
struct LibraryCompatTests {
    private let page = URL(string: "https://example.com/x")!

    private func wiki(native: String? = nil, crossover: String? = nil, wine: String? = nil) -> GameCompatRecord.WikiTiers {
        GameCompatRecord.WikiTiers(native: native, rosetta2: nil, crossover: crossover, wine: wine, parallels: nil, pageURL: page)
    }

    private func antiCheat(_ engines: [String], status: String) -> GameCompatRecord.AntiCheat {
        GameCompatRecord.AntiCheat(engines: engines, status: status, notes: [], sourceURL: page)
    }

    private func community(_ verdict: String) -> GameCompatRecord.Community {
        GameCompatRecord.Community(verdict: verdict, runs: 9, installs: 3, engine: nil, medianFPS: nil, pageURL: page)
    }

    // MARK: - Summaries

    @Test
    func `a summary carries the strip's state and whether the macOS build plays`() throws {
        let sims = GameCompatVerdict.summary(
            appID: 1222670, antiCheat: nil, wiki: wiki(native: "perfect", crossover: "unplayable", wine: "perfect"),
            proton: nil, community: nil, hasMacBuild: true, architectures: nil,
        )
        #expect(sims == GameCompatSummary(appID: 1222670, state: .playable, native: true, macRunnable: true, macEvidence: true))
        #expect(sims.playsOnMac)
        // A macOS build Steam lists and nobody rated is "Available", which
        // the filter does not count: plenty of those are 32-bit.
        let unrated = GameCompatVerdict.summary(
            appID: 2, antiCheat: nil, wiki: nil, proton: nil, community: nil, hasMacBuild: true, architectures: nil,
        )
        #expect(unrated == GameCompatSummary(appID: 2, state: .unknown, native: false))
        #expect(!unrated.playsOnMac)
        let broken = GameCompatVerdict.summary(
            appID: 3, antiCheat: nil, wiki: wiki(wine: "unplayable"), proton: nil, community: nil,
            hasMacBuild: false, architectures: nil,
        )
        #expect(broken.state == .unsupported)
        #expect(!broken.playsOnMac)
        // ProtonDB alone is Linux evidence: the badge says Playable, the Apple filter leaves it out.
        let linuxOnly = try GameCompatVerdict.summary(
            appID: 4, antiCheat: nil, wiki: nil,
            proton: GameCompatRecord.ProtonSummary(tier: "silver", confidence: "good", total: 40, sourceURL: #require(URL(string: "https://www.protondb.com/app/4"))),
            community: nil, hasMacBuild: false, architectures: nil,
        )
        #expect(linuxOnly.state == .playable)
        #expect(!linuxOnly.playsOnMac)
        // An unrated macOS build with a 64-bit slice runs.
        let universal = GameCompatVerdict.summary(
            appID: 5, antiCheat: nil, wiki: nil, proton: nil, community: nil, hasMacBuild: true,
            architectures: GameCompatRecord.MacArchitectures(intel32: nil, intel64: true, arm: true),
        )
        #expect(universal.playsOnMac)
    }

    @Test
    func `ProtonDB is asked only when nothing Mac-side has a verdict`() {
        #expect(GameCompatBatch.needsProton(antiCheat: nil, wiki: nil, community: nil))
        #expect(GameCompatBatch.needsProton(antiCheat: nil, wiki: wiki(native: "perfect"), community: community("unknown")))
        #expect(!GameCompatBatch.needsProton(antiCheat: nil, wiki: wiki(wine: "runs"), community: nil))
        #expect(!GameCompatBatch.needsProton(antiCheat: nil, wiki: nil, community: community("perfect")))
        #expect(!GameCompatBatch.needsProton(antiCheat: antiCheat(["BattlEye"], status: "Denied"), wiki: nil, community: nil))
        #expect(GameCompatBatch.needsProton(antiCheat: antiCheat(["Custom"], status: "Supported"), wiki: nil, community: nil))
    }

    // MARK: - The batch endpoint

    @Test
    func `the batch request keeps one entry per game and skips the malformed`() {
        let body = Data(#"{"apps":[[570,"Dota 2"],[570,"again"],["x","bad"],[-1,"neg"],[730],[1222670,"The Sims™ 4"]]}"#.utf8)
        #expect(GameCompatBatch.games(fromRequest: body) == [
            .init(appID: 570, name: "Dota 2"), .init(appID: 730, name: ""), .init(appID: 1222670, name: "The Sims™ 4"),
        ])
        #expect(GameCompatBatch.games(fromRequest: Data("nope".utf8)).isEmpty)
        #expect(GameCompatBatch.games(fromRequest: Data(#"{"apps":{}}"#.utf8)).isEmpty)
    }

    @Test
    func `the community database is asked a hundred games at a time`() throws {
        let base = try #require(URL(string: "https://kagerou.glass/api/sevoflurane/v1"))
        let requests = GameCompatBatch.communityRequests(base: base, appIDs: Array(1 ... 250))
        #expect(requests.map(\.appIDs.count) == [100, 100, 50])
        #expect(requests[0].url.absoluteString.hasPrefix("https://kagerou.glass/api/sevoflurane/v1/games?appids=1%2C2%2C3")
            || requests[0].url.absoluteString.hasPrefix("https://kagerou.glass/api/sevoflurane/v1/games?appids=1,2,3"))
        #expect(requests[2].appIDs.first == 201)
        #expect(GameCompatBatch.communityRequests(base: base, appIDs: []).isEmpty)
    }

    @Test
    func `a batch answer splits into the bodies the per-game endpoint returns`() throws {
        let answer = Data(#"{"570":{"verdict":"perfect","runs":5,"installs":2,"url":"https://kagerou.glass/g/570"},"oops":{}}"#.utf8)
        let bodies = try #require(GameCompatBatch.communityBodies(answer))
        #expect(Set(bodies.keys) == [570])
        let body = try #require(bodies[570])
        let summary = try #require(GameCompatSources.community(data: body))
        #expect(summary.verdict == "perfect")
        #expect(summary.runs == 5)
        #expect(GameCompatBatch.communityBodies(Data("[]".utf8)) == nil)
    }

    @Test
    func `the page's answer leaves out what draws nothing`() throws {
        let data = GameCompatBatch.answer([
            GameCompatSummary(appID: 1, state: .verified, native: false),
            GameCompatSummary(appID: 2, state: .unknown, native: false),
            GameCompatSummary(appID: 3, state: .unknown, native: true),
            GameCompatSummary(appID: 4, state: .unsupported, native: false),
        ], pending: 7)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["pending"] as? Int == 7)
        let apps = try #require(object["apps"] as? [String: [String: Any]])
        #expect(Set(apps.keys) == ["1", "3", "4"])
        #expect(apps["1"]?["s"] as? String == "verified")
        #expect(apps["3"]?["n"] as? Bool == true)
        #expect(apps["4"]?["s"] as? String == "unsupported")
    }

    // MARK: - The page scripts

    @Test
    func `the page scripts parse`() throws {
        let context = try #require(JSContext())
        for script in [
            SteamLibraryCompat.contextScript, SteamLibraryCompat.contextRemovalScript,
            SteamLibraryCompat.script, SteamLibraryCompat.removalScript,
            SteamCompatBadge.script, SteamCompatBadge.storeScript,
        ] {
            context.setObject(script, forKeyedSubscript: "source" as NSString)
            let result = context.evaluateScript("try { new Function(source); 'ok' } catch (e) { String(e) }")?.toString()
            #expect(result == "ok")
        }
    }

    @Test
    func `the desktop script finds Steam's classes by their keys and the app id on the fiber`() {
        let script = SteamLibraryCompat.script
        for key in ["AdvancedSearchContainer", "GameListEntryContainer", "LibraryItemBox", "__reactFiber$"] {
            #expect(script.contains(key))
        }
        #expect(script.contains("ctx.__sevoLibraryCompat"))
        #expect(script.contains("var PATHS"))
    }

    /// Steam's filter class, its library filter (a subclass that checks the
    /// app type first), MobX, webpack and the bridge, faked just enough for
    /// the context script to run in JavaScriptCore.
    private static let steam = """
    var window = this;
    var stored = {};
    var localStorage = { getItem: function (k) { return k in stored ? stored[k] : null; }, setItem: function (k, v) { stored[k] = String(v); } };
    var timers = [];
    function setTimeout(f, ms) { timers.push(ms); return timers.length; }
    function clearTimeout() {}
    var fetched = [];
    function fetch(url, options) {
      fetched.push({ url: url, body: JSON.parse(options.body) });
      return Promise.resolve({ ok: true, json: function () {
        return Promise.resolve({ pending: 2, apps: { "1": { s: "playable", n: false, p: true }, "3": { s: "unknown", n: true, p: true }, "4": { s: "unsupported", n: false } } });
      } });
    }
    class Filter {
      MatchesImpl(app) { return true; }
      MatchesScoredImpl(app) { return 1; }
      get bIsEmpty() { return true; }
    }
    class LibraryFilter extends Filter {
      MatchesImpl(app) { return app.appid !== 99 && super.MatchesImpl(app); }
    }
    var reads = 0;
    var mobx = function () {};
    mobx.box = function (value) { return { get: function () { reads++; return value; }, set: function (v) { value = v; } }; };
    var modules = { "10": 'x("Found SteamDeckUnsupported set in AppFilter")', "20": 'throw Error("[MobX] no")', "30": "other" };
    var exported = { "10": { E6: Filter, zG: LibraryFilter }, "20": { sH: mobx }, "30": {} };
    var webpackChunksteamui = { push: function (entry) {
      var require = function (id) { return exported[id]; };
      require.m = modules;
      entry[2](require);
    } };
    var uiStore = { collectionsAppFilter: new LibraryFilter() };
    uiStore.currentAppFilter = uiStore.collectionsAppFilter;
    var collectionStore = { allAppsCollection: { allApps: [
      { appid: 1, app_type: 1, display_name: "One" }, { appid: 2, app_type: 1, display_name: "Two" },
      { appid: 3, app_type: 1, display_name: "Three" }, { appid: 4, app_type: 1, display_name: "Four" },
      { appid: 5, app_type: 4, display_name: "A tool" }
    ] } };
    """

    @Test
    func `the chip filters the library's own filter and nothing else`() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.steam)
        #expect(context.evaluateScript(SteamLibraryCompat.contextScript)?.toString() == "installed")
        func js(_ source: String) -> String? { context.evaluateScript(source)?.toString() }
        #expect(js("__sevoLibraryCompat.available") == "true")
        // Games only, each once, named for the wiki.
        #expect(js("fetched[0].url") == "/__compat/batch")
        #expect(js("JSON.stringify(fetched[0].body.apps)") == #"[[1,"One"],[2,"Two"],[3,"Three"],[4,"Four"]]"#)
        #expect(js("__sevoLibraryCompat.pending") == "2")
        #expect(js("timers.indexOf(30000) >= 0") == "true")
        let library = "uiStore.collectionsAppFilter"
        // Off: Steam's own matching.
        #expect(js("[1,2,3,4].map(function (id) { return \(library).MatchesImpl({ appid: id }); }).join()") == "true,true,true,true")
        #expect(js("\(library).bIsEmpty") == "true")
        js("__sevoLibraryCompat.toggle()")
        #expect(js("localStorage.getItem('\(SteamLibraryCompat.storageKey)')") == "on")
        // On: Playable and a playing macOS build stay, the rest go.
        #expect(js("[1,2,3,4].map(function (id) { return \(library).MatchesImpl({ appid: id }); }).join()") == "true,false,true,false")
        #expect(js("\(library).MatchesScoredImpl({ appid: 2 })") == "0")
        #expect(js("\(library).MatchesScoredImpl({ appid: 1 })") == "1")
        #expect(js("\(library).bIsEmpty") == "false")
        // Steam's own rules still apply on top.
        #expect(js("\(library).MatchesImpl({ appid: 99 })") == "false")
        // A dynamic collection's filter is another instance, and untouched.
        #expect(js("new LibraryFilter().MatchesImpl({ appid: 2 })") == "true")
        #expect(js("new Filter().bIsEmpty") == "true")
        // Every match reads the box, which is what makes MobX recompute.
        #expect(js("var before = reads; \(library).MatchesImpl({ appid: 1 }); reads > before") == "true")
        // The Settings switch stands it all down.
        #expect(js(SteamLibraryCompat.contextRemovalScript) == "removed")
        #expect(js("\(library).MatchesImpl({ appid: 2 })") == "true")
        #expect(js(SteamLibraryCompat.contextScript) == "reapplied")
        #expect(js("\(library).MatchesImpl({ appid: 2 })") == "false")
    }

    @Test
    func `without MobX the filter stays Steam's own and the badges still have verdicts`() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.steam)
        context.evaluateScript(#"modules["20"] = "nothing here";"#)
        #expect(context.evaluateScript(SteamLibraryCompat.contextScript)?.toString() == "installed without the filter")
        #expect(context.evaluateScript("__sevoLibraryCompat.available")?.toBool() == false)
        context.evaluateScript("localStorage.setItem('\(SteamLibraryCompat.storageKey)', 'on'); __sevoLibraryCompat.toggle()")
        #expect(context.evaluateScript("uiStore.collectionsAppFilter.MatchesImpl({ appid: 2 })")?.toBool() == true)
        #expect(context.evaluateScript("Object.keys(__sevoLibraryCompat.verdicts).join()")?.toString() == "1,3,4")
    }

    @Test
    func `a library filter Steam makes after boot is patched at the next sync`() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.steam)
        context.evaluateScript("var now = 0; Date.now = function () { return now; }; var made = uiStore.collectionsAppFilter; uiStore.collectionsAppFilter = undefined;")
        #expect(context.evaluateScript(SteamLibraryCompat.contextScript)?.toString() == "installed without the filter")
        context.evaluateScript("uiStore.collectionsAppFilter = made; __sevoLibraryCompat.sync()")
        // Retries wait five seconds between scans of webpack's modules.
        #expect(context.evaluateScript("__sevoLibraryCompat.available")?.toBool() == false)
        context.evaluateScript("now = 5000; __sevoLibraryCompat.sync()")
        #expect(context.evaluateScript("__sevoLibraryCompat.available")?.toBool() == true)
        context.evaluateScript("__sevoLibraryCompat.toggle()")
        #expect(context.evaluateScript("uiStore.collectionsAppFilter.MatchesImpl({ appid: 2 })")?.toBool() == false)
    }

    @Test
    func `the chip remembers being on`() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.steam)
        context.evaluateScript("localStorage.setItem('\(SteamLibraryCompat.storageKey)', 'on')")
        context.evaluateScript(SteamLibraryCompat.contextScript)
        #expect(context.evaluateScript("__sevoLibraryCompat.isOn()")?.toBool() == true)
        #expect(context.evaluateScript("uiStore.collectionsAppFilter.MatchesImpl({ appid: 2 })")?.toBool() == false)
    }
}

/// The library's bulk path asks for the same evidence the game's page does.
struct LibraryCompatLookupTests {
    @Test
    func `a 32-bit-only macOS build leaves the Mac filter once its architectures arrive`() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "compat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = GameCompatService(
            session: CompatStub.session(), cache: cache, appInfo: cache.appending(path: "appinfo.vdf"),
        )
        let game = GameCompatBatch.Game(appID: CompatStub.appID, name: CompatStub.title)

        let first = await service.summaries(for: [game])
        // Rated perfect on the wiki and nothing on disk yet: native until the
        // page says otherwise, with that page waiting in the queue.
        #expect(first.summaries == [GameCompatSummary(
            appID: CompatStub.appID, state: .unsupported, native: true, macRunnable: true, macEvidence: true,
        )])
        #expect(first.summaries.first?.playsOnMac == true)
        #expect(first.pending == 1)

        var latest = first
        let deadline = ContinuousClock.now + .seconds(15)
        while latest.pending > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            latest = await service.summaries(for: [game])
        }
        #expect(latest.pending == 0)
        #expect(latest.summaries == [GameCompatSummary(
            appID: CompatStub.appID, state: .unsupported, native: false, macRunnable: false, macEvidence: true,
        )])
        #expect(latest.summaries.first?.playsOnMac == false)
    }
}

/// The community sources as one game's answers: the wiki rates its macOS
/// build perfect and its Windows build unplayable, and PCGamingWiki's page
/// lists a 32-bit Intel build alone.
private final class CompatStub: URLProtocol {
    static let appID = 9_000_001
    static let title = "Old Mac Game"

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompatStub.self]
        return URLSession(configuration: configuration)
    }

    private static func body(for url: URL) -> String {
        let query = url.query ?? ""
        switch url.host {
        case "www.applegamingwiki.com":
            return #"[{"Page":"\#(title)","native":"perfect","rosetta 2":"na","crossover":"unplayable","wine":"unplayable","parallels":"na"}]"#
        case "www.pcgamingwiki.com" where query.contains("action=idlookup"):
            return #"{"idlookup":[{"title":{"Page":"\#(title)"}}]}"#
        case "www.pcgamingwiki.com" where query.contains("action=parse"):
            return #"{"parse":{"title":"\#(title)","pageid":1,"wikitext":"{{API\n|macos intel 32-bit app = true\n|macos intel 64-bit app = false\n|macos arm app = false\n}}"}}"#
        case "raw.githubusercontent.com":
            return "[]"
        default:
            return "{}"
        }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://stub.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body(for: url).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
