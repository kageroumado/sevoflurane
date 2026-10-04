import Foundation
import Testing
@testable import Sevoflurane

/// The badge ladder and the source parsers, on fixtures shaped like the live
/// answers of the real endpoints (`sevo app compat`).
struct GameCompatTests {
    private func antiCheat(_ engines: [String], status: String = "Supported") -> GameCompatRecord.AntiCheat {
        GameCompatRecord.AntiCheat(
            engines: engines, status: status, notes: [],
            sourceURL: URL(string: "https://areweanticheatyet.com")!,
        )
    }

    private func wiki(
        native: String? = nil, rosetta2: String? = nil, crossover: String? = nil,
        wine: String? = nil, parallels: String? = nil,
    ) -> GameCompatRecord.WikiTiers {
        GameCompatRecord.WikiTiers(
            native: native, rosetta2: rosetta2, crossover: crossover, wine: wine, parallels: parallels,
            pageURL: URL(string: "https://www.applegamingwiki.com/wiki/X")!,
        )
    }

    private func proton(_ tier: String, confidence: String = "strong", total: Int = 100) -> GameCompatRecord.ProtonSummary {
        GameCompatRecord.ProtonSummary(
            tier: tier, confidence: confidence, total: total,
            sourceURL: URL(string: "https://www.protondb.com/app/1")!,
        )
    }

    private func community(_ verdict: String, runs: Int = 12, installs: Int = 4) -> GameCompatRecord.Community {
        GameCompatRecord.Community(
            verdict: verdict, runs: runs, installs: installs, engine: "dormison-b1", medianFPS: 58,
            pageURL: URL(string: "https://kagerou.glass/sevoflurane/games/1-x")!,
        )
    }

    // MARK: - The Mac badge

    @Test
    func `kernel anti-cheat with no Mac evidence is unsupported`() {
        let badge = GameCompatVerdict.mac(
            antiCheat: antiCheat(["nProtect GameGuard"], status: "Running"), wiki: nil, proton: proton("gold"),
        )
        #expect(badge.state == .unsupported)
        #expect(badge.reason.contains("nProtect GameGuard"))
    }

    @Test
    func `Mac evidence outranks the anti-cheat veto but stops at playable`() {
        // GTA V: CrossOver perfect on the wiki, BattlEye on AWACY.
        let badge = GameCompatVerdict.mac(
            antiCheat: antiCheat(["BattlEye"], status: "Denied"),
            wiki: wiki(crossover: "perfect", wine: "perfect"), proton: proton("gold"),
        )
        #expect(badge.state == .playable)
        #expect(badge.reason.contains("Online play"))
    }

    @Test
    func `columns that disagree give the better tier capped at playable and name both`() {
        // The Sims 4: CrossOver crashes at boot, Wine is perfect.
        let sims = GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "unplayable", wine: "perfect"), proton: nil)
        #expect(sims.state == .playable)
        #expect(sims.reason.contains("Wine perfect"))
        #expect(sims.reason.contains("CrossOver as crashing at boot"))
        // Red Dead Redemption 2: the other way round.
        let rdr2 = GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "perfect", wine: "unplayable"), proton: nil)
        #expect(rdr2.state == .playable)
        // Two passes that disagree withhold Verified too.
        let split = GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "playable", wine: "perfect"), proton: nil)
        #expect(split.state == .playable)
    }

    @Test
    func `two failures that disagree stay unsupported`() {
        let badge = GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "menu", wine: "unplayable"), proton: nil)
        #expect(badge.state == .unsupported)
        #expect(badge.reason.contains("crashing at the menu"))
    }

    @Test
    func `columns that agree give their tier`() {
        let badge = GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "perfect", wine: "perfect"), proton: nil)
        #expect(badge.state == .verified)
        #expect(badge.reason.contains("Wine and CrossOver perfect"))
    }

    @Test
    func `one rated column answers alone`() {
        let crossover = GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "perfect"), proton: proton("borked"))
        #expect(crossover.state == .verified)
        #expect(crossover.reason.contains("CrossOver"))
        let wine = GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "unknown", wine: "playable"), proton: nil)
        #expect(wine.state == .playable)
        #expect(wine.reason.contains("Wine"))
    }

    @Test
    func `Sevoflurane's own runs outrank every other source`() {
        let perfect = GameCompatVerdict.mac(
            antiCheat: nil, wiki: wiki(crossover: "unplayable", wine: "unplayable"), proton: proton("borked"),
            community: community("perfect"),
        )
        #expect(perfect.state == .verified)
        #expect(perfect.reason.contains("Sevoflurane players"))
        #expect(perfect.reason.contains("12 runs on 4 Macs"))
        let crashes = GameCompatVerdict.mac(
            antiCheat: nil, wiki: wiki(wine: "perfect"), proton: nil, community: community("unplayable"),
        )
        #expect(crashes.state == .unsupported)
        let glitches = GameCompatVerdict.mac(antiCheat: nil, wiki: nil, proton: nil, community: community("runs"))
        #expect(glitches.state == .playable)
    }

    @Test
    func `the community's own runs still leave anti-cheat its caveat`() {
        let badge = GameCompatVerdict.mac(
            antiCheat: antiCheat(["Easy Anti-Cheat"]), wiki: nil, proton: nil, community: community("perfect"),
        )
        #expect(badge.state == .playable)
        #expect(badge.reason.contains("Online play"))
    }

    @Test
    func `a community summary without enough runs yields to the wiki`() {
        let badge = GameCompatVerdict.mac(
            antiCheat: nil, wiki: wiki(wine: "perfect"), proton: nil, community: community("unknown", runs: 2, installs: 1),
        )
        #expect(badge.state == .verified)
        #expect(badge.reason.contains("AppleGamingWiki"))
    }

    @Test
    func `every ProtonDB tier counts and none yields verified`() {
        for tier in ["platinum", "gold", "silver", "bronze"] {
            let badge = GameCompatVerdict.mac(antiCheat: nil, wiki: nil, proton: proton(tier))
            #expect(badge.state == .playable)
            #expect(badge.reason.contains("Untested on a Mac"))
        }
        #expect(GameCompatVerdict.mac(antiCheat: nil, wiki: nil, proton: proton("silver")).reason.contains("with issues"))
        let borked = GameCompatVerdict.mac(antiCheat: nil, wiki: nil, proton: proton("borked"))
        #expect(borked.state == .unsupported)
        #expect(borked.reason.contains("Untested on a Mac"))
        let weak = GameCompatVerdict.mac(antiCheat: nil, wiki: nil, proton: proton("gold", confidence: "inadequate"))
        #expect(weak.state == .unknown)
        #expect(weak.reason == "No Mac reports yet.")
        let pending = GameCompatVerdict.mac(antiCheat: nil, wiki: nil, proton: proton("pending"))
        #expect(pending.state == .unknown)
    }

    @Test
    func `a native build leaves the Windows verdict alone`() {
        let badge = GameCompatVerdict.mac(
            antiCheat: nil, wiki: wiki(native: "perfect", rosetta2: "perfect", crossover: "unknown"), proton: nil,
        )
        #expect(badge.state == .unknown)
        #expect(!badge.reason.contains("native"))
    }

    // MARK: - The native badge

    @Test
    func `the native badge reads the wiki's native column, then Rosetta 2's`() {
        let perfect = GameCompatVerdict.native(wiki: wiki(native: "perfect", wine: "unplayable"), hasMacBuild: true)
        #expect(perfect?.state == .verified)
        #expect(perfect?.label == "Perfect")
        let rosetta = GameCompatVerdict.native(wiki: wiki(native: "na", rosetta2: "playable"), hasMacBuild: false)
        #expect(rosetta?.state == .playable)
        #expect(rosetta?.reason.contains("Rosetta 2") == true)
        // A 32-bit Mac build that stopped running on current macOS.
        let dead = GameCompatVerdict.native(wiki: wiki(native: "unplayable"), hasMacBuild: true)
        #expect(dead?.state == .unsupported)
        #expect(dead?.label == "Broken")
    }

    @Test
    func `a macOS build nobody rated reads as available, and no build as none`() {
        let listed = GameCompatVerdict.native(wiki: wiki(native: "unknown"), hasMacBuild: true)
        #expect(listed?.state == .unknown)
        #expect(listed?.label == "Available")
        #expect(GameCompatVerdict.native(wiki: nil, hasMacBuild: false) == nil)
        #expect(GameCompatVerdict.native(wiki: wiki(wine: "perfect"), hasMacBuild: false) == nil)
    }

    // MARK: - The anti-cheat badge

    @Test
    func `anti-cheat badge states`() {
        #expect(GameCompatVerdict.antiCheat(nil).state == .unknown)
        #expect(GameCompatVerdict.antiCheat(nil).label == "None known")
        let eac = GameCompatVerdict.antiCheat(antiCheat(["Easy Anti-Cheat"], status: "Supported"))
        #expect(eac.state == .unsupported)
        #expect(eac.label == "Easy Anti-Cheat")
        let vac = GameCompatVerdict.antiCheat(antiCheat(["VAC"], status: "Supported"))
        #expect(vac.state == .playable)
        let denied = GameCompatVerdict.antiCheat(antiCheat(["Custom"], status: "Denied"))
        #expect(denied.state == .unsupported)
        let planned = GameCompatVerdict.antiCheat(antiCheat(["Custom"], status: "Planned"))
        #expect(planned.state == .unknown)
    }

    // MARK: - Titles

    @Test
    func `title normalization folds the differences between the wikis and Steam`() {
        #expect(GameCompatTitles.normalize("Baba Is You") == GameCompatTitles.normalize("Baba is You"))
        #expect(GameCompatTitles.normalize("Command & Conquer 3") == GameCompatTitles.normalize("Command and Conquer 3"))
        #expect(GameCompatTitles.normalize("ELDEN RING™") == "elden ring")
        #expect(GameCompatTitles.normalize("The Witcher® 3: Wild Hunt") == "witcher 3 wild hunt")
        #expect(GameCompatTitles.normalize("Tom Clancy's Rainbow Six® Siege") == "tom clancys rainbow six siege")
        #expect(GameCompatTitles.normalize("Pokémon") == "pokemon")
    }

    // MARK: - Parsers

    @Test
    func `AWACY parses mixed store ids and indexes by app id and title`() throws {
        let json = """
        [{"name":"Elden Ring","slug":"elden-ring","status":"Supported","anticheats":["Easy Anti-Cheat"],
          "notes":[["Offline works.",null]],"storeIds":{"steam":"1245620","epic":{"namespace":"x","slug":"y"}}},
         {"name":"VALORANT","slug":"valorant","status":"Denied","anticheats":["Vanguard"],"notes":[],"storeIds":{}}]
        """
        let index = try GameCompatSources.AntiCheatIndex(data: Data(json.utf8))
        let elden = try #require(index.lookup(appID: 1_245_620, name: "whatever"))
        #expect(elden.engines == ["Easy Anti-Cheat"])
        #expect(elden.notes == ["Offline works."])
        #expect(elden.sourceURL.absoluteString == "https://areweanticheatyet.com/game/elden-ring")
        let valorant = try #require(index.lookup(appID: 0, name: "Valorant"))
        #expect(valorant.status == "Denied")
        #expect(index.lookup(appID: 1, name: "Nothing") == nil)
    }

    @Test
    func `the wiki export is read by display key and filtered to the vocabulary`() throws {
        let json = """
        [{"Page":"Cyberpunk 2077","native":"perfect","rosetta 2":"na","crossover":"Perfect","wine":"perfect","parallels":"runs"},
         {"Page":"Odd Game","native":"","rosetta 2":"good","crossover":"doesn’t work","wine":null,"parallels":"playable \\u007f&#039;uniq--ref&#039;\\u007f"}]
        """
        let index = try GameCompatSources.WikiIndex(data: Data(json.utf8))
        let cyberpunk = try #require(index.lookup(title: "Cyberpunk 2077"))
        #expect(cyberpunk.crossover == "perfect")
        #expect(cyberpunk.rosetta2 == "na")
        #expect(cyberpunk.pageURL.absoluteString == "https://www.applegamingwiki.com/wiki/Cyberpunk_2077")
        let odd = try #require(index.lookup(title: "odd game"))
        #expect(odd.native == nil)
        #expect(odd.rosetta2 == nil)
        #expect(odd.crossover == nil)
        #expect(odd.parallels == nil)
    }

    @Test
    func `a wiki page titled with a number is kept`() throws {
        let json = #"[{"Page":5,"native":"na","rosetta 2":"na","crossover":"perfect","wine":"perfect","parallels":"na"}]"#
        let index = try GameCompatSources.WikiIndex(data: Data(json.utf8))
        #expect(index.lookup(title: "5")?.crossover == "perfect")
    }

    @Test
    func `the community summary parses, and a game with no runs reads as absent`() throws {
        let json = """
        {"appid":1962700,"engine":"dormison-r1","runs":3,"installs":1,"verdict":"unknown","total_runs":3,
         "fps":{"median_avg":57.6,"median_low1":41,"runs":3,"installs":1},
         "url":"https://kagerou.glass/sevoflurane/games/1962700-subnautica-2","game":{"appid":1962700}}
        """
        let summary = try #require(GameCompatSources.community(data: Data(json.utf8)))
        #expect(summary.verdict == "unknown")
        #expect(summary.runs == 3)
        #expect(summary.medianFPS == 57.6)
        #expect(summary.pageURL.absoluteString == "https://kagerou.glass/sevoflurane/games/1962700-subnautica-2")
        #expect(GameCompatSources.community(data: Data("{}".utf8)) == nil)
    }

    @Test
    func `ProtonDB and PCGamingWiki answers parse, and a 404 page reads as absent`() {
        let summary = GameCompatSources.protonSummary(
            appID: 1_091_500,
            data: Data(#"{"bestReportedTier":"platinum","confidence":"strong","score":0.76,"tier":"gold","total":2704,"trendingTier":"platinum"}"#.utf8),
        )
        #expect(summary?.tier == "gold")
        #expect(summary?.total == 2704)
        #expect(GameCompatSources.protonSummary(appID: 1, data: Data("<!doctype html>".utf8)) == nil)
        #expect(GameCompatSources.protonSummary(appID: 1, data: Data("{}".utf8)) == nil)
        let title = GameCompatSources.pcGamingWikiTitle(
            data: Data(#"{"idlookup":[{"title":{"Page":"Cyberpunk 2077"}}]}"#.utf8),
        )
        #expect(title == "Cyberpunk 2077")
        #expect(GameCompatSources.pcGamingWikiTitle(data: Data(#"{"idlookup":[]}"#.utf8)) == nil)
    }

    @Test
    func `the record round-trips as the JSON the page reads`() throws {
        let record = GameCompatRecord(
            appID: 1, name: "X", antiCheat: nil, wiki: wiki(native: "perfect", crossover: "perfect"), proton: proton("gold"),
            community: community("playable"), hasMacBuild: true,
            deckCategory: 3,
            mac: GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "perfect"), proton: nil),
            nativeBadge: GameCompatVerdict.native(wiki: wiki(native: "perfect"), hasMacBuild: true),
            antiCheatBadge: GameCompatVerdict.antiCheat(nil), fetchedAt: Date(timeIntervalSince1970: 0),
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mac = try #require(object["mac"] as? [String: Any])
        #expect(mac["state"] as? String == "verified")
        #expect((object["nativeBadge"] as? [String: Any])?["label"] as? String == "Perfect")
        #expect((object["community"] as? [String: Any])?["verdict"] as? String == "playable")
        #expect((object["wiki"] as? [String: Any])?["pageURL"] as? String == "https://www.applegamingwiki.com/wiki/X")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(GameCompatRecord.self, from: data) == record)
    }
}

/// The switch over the strip. Turning it off has to reach the page already on
/// screen, and it must leave the injected script installed so turning it back
/// on needs nothing more than the script it already has.
@MainActor
@Suite(.serialized)
struct CompatibilityStripSwitchTests {
    @Test
    func `the strip is drawn until someone turns it off`() {
        let chosen = Preferences.compatibilityStrip
        defer { Preferences.compatibilityStrip = chosen }
        Preferences.shared.removeObject(forKey: "compatibilityStrip")
        #expect(Preferences.compatibilityStrip)
        Preferences.compatibilityStrip = false
        #expect(!Preferences.compatibilityStrip)
        Preferences.compatibilityStrip = true
        #expect(Preferences.compatibilityStrip)
    }

    @Test
    func `the store strip honors the switch and stays on the store`() {
        #expect(SteamCompatBadge.storeScript.contains("record.off"))
        #expect(SteamCompatBadge.storeScript.contains(#"location.hostname !== "store.steampowered.com""#))
        #expect(SteamCompatBadge.storeScript.contains("messageHandlers.\(SteamCompatBadge.storeHandler)"))
        // Both pages draw the same cells from the same record.
        for script in [SteamCompatBadge.script, SteamCompatBadge.storeScript] {
            #expect(script.contains(#"cell("Native on macOS", native)"#))
            #expect(script.contains("Sevoflurane players:"))
        }
    }

    @Test
    func `removal stands the script down rather than uninstalling it`() {
        #expect(SteamCompatBadge.script.contains("enabled: true"))
        #expect(SteamCompatBadge.removalScript.contains("__sevoCompat.enabled = false"))
        // It asks the script to redraw, which is what takes the strip off the
        // page that is open — a flag nobody acts on would change nothing
        // until the next navigation.
        #expect(SteamCompatBadge.removalScript.contains("__sevoCompat.apply()"))
        // And the observer that puts the strip back has to read the flag.
        #expect(SteamCompatBadge.script.contains("!window.__sevoCompat.enabled"))
    }
}
