import Foundation
import Testing
@testable import Sevoflurane

/// The badge ladder and the source parsers, on fixtures shaped like the live
/// answers of 2026-09-07 (`sevo app compat` against the real endpoints).
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
        #expect(badge.reason.contains("online play"))
    }

    @Test
    func `a wiki crash outranks a pass in the other column`() {
        let badge = GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "unplayable", wine: "perfect"), proton: nil)
        #expect(badge.state == .unsupported)
        #expect(badge.reason.contains("CrossOver"))
    }

    @Test
    func `CrossOver perfect is verified`() {
        let badge = GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "perfect"), proton: proton("borked"))
        #expect(badge.state == .verified)
    }

    @Test
    func `Wine answers when CrossOver says nothing`() {
        let badge = GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "unknown", wine: "playable"), proton: nil)
        #expect(badge.state == .playable)
        #expect(badge.reason.contains("Wine"))
    }

    @Test
    func `ProtonDB alone never yields verified`() {
        let gold = GameCompatVerdict.mac(antiCheat: nil, wiki: nil, proton: proton("platinum"))
        #expect(gold.state == .playable)
        #expect(gold.reason.contains("Untested"))
        let borked = GameCompatVerdict.mac(antiCheat: nil, wiki: nil, proton: proton("borked"))
        #expect(borked.state == .unknown)
        let weak = GameCompatVerdict.mac(antiCheat: nil, wiki: nil, proton: proton("gold", confidence: "inadequate"))
        #expect(weak.state == .unknown)
        #expect(weak.reason == "No Mac reports yet.")
    }

    @Test
    func `a native build is named but is not a bottle verdict`() {
        let badge = GameCompatVerdict.mac(
            antiCheat: nil, wiki: wiki(native: "perfect", rosetta2: "perfect", crossover: "unknown"), proton: nil,
        )
        #expect(badge.state == .unknown)
        #expect(badge.reason.contains("native Mac version"))
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
            appID: 1, name: "X", antiCheat: nil, wiki: wiki(crossover: "perfect"), proton: proton("gold"),
            deckCategory: 3,
            mac: GameCompatVerdict.mac(antiCheat: nil, wiki: wiki(crossover: "perfect"), proton: nil),
            antiCheatBadge: GameCompatVerdict.antiCheat(nil), fetchedAt: Date(timeIntervalSince1970: 0),
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mac = try #require(object["mac"] as? [String: Any])
        #expect(mac["state"] as? String == "verified")
        #expect((object["wiki"] as? [String: Any])?["pageURL"] as? String == "https://www.applegamingwiki.com/wiki/X")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(GameCompatRecord.self, from: data) == record)
    }
}
