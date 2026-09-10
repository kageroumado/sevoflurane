import Foundation
import Testing
@testable import Sevoflurane

/// How Discord's detectable-games database becomes the two lookups the app
/// makes of it.
///
/// The fixture is three entries in the shape Discord serves — one with a Steam
/// sku, one with aliases and a sku whose id is null, one with neither — so the
/// index is built from the same JSON the network would hand over, without a
/// network.
struct DiscordApplicationsTests {
    /// Three games as `applications/detectable` describes them, cut down to
    /// the fields the index is built from.
    static let database = Data(#"""
    [
      {
        "id": "1505320535268261888",
        "name": "Subnautica 2",
        "aliases": [],
        "third_party_skus": [
          {"distributor": "xbox", "id": "9PJPCB188SVG"},
          {"distributor": "steam", "id": "1962700"}
        ]
      },
      {
        "id": "356875221078245376",
        "name": "Hollow Knight: Silksong",
        "aliases": ["Silksong", "Hollow Knight — Silksong"],
        "third_party_skus": [
          {"distributor": "battlenet", "id": null}
        ]
      },
      {
        "id": "999000111222333444",
        "name": "A Launcher Nobody Sells"
      }
    ]
    """#.utf8)

    static var index: DiscordApplications.Index {
        get throws {
            try #require(DiscordApplications.index(from: database))
        }
    }

    @Test
    func `a steam app id resolves to the game's application`() throws {
        let application = try #require(try Self.index.application(steamAppID: 1_962_700))
        #expect(application.id == "1505320535268261888")
        #expect(application.name == "Subnautica 2")
    }

    @Test
    func `a steam app id nobody claims resolves to nothing`() throws {
        let index = try Self.index
        #expect(index.application(steamAppID: 264_710) == nil)
    }

    @Test
    func `a name resolves however it is punctuated and cased`() throws {
        let index = try Self.index
        for spelling in [
            "Hollow Knight: Silksong",
            "hollow knight silksong",
            "HollowKnight:  Silksong!",
        ] {
            let application = try #require(index.application(named: spelling))
            #expect(application.id == "356875221078245376")
            #expect(application.name == "Hollow Knight: Silksong")
        }
    }

    @Test
    func `every alias resolves to the same application`() throws {
        let index = try Self.index
        #expect(index.application(named: "Silksong")?.id == "356875221078245376")
        #expect(index.application(named: "hollow knight — silksong")?.id == "356875221078245376")
    }

    @Test
    func `a game with no steam sku is still there by name`() throws {
        let index = try Self.index
        let application = try #require(index.application(named: "a launcher nobody sells"))
        #expect(application.id == "999000111222333444")
        #expect(index.steam.isEmpty == false)
        #expect(index.steam.values.contains("999000111222333444") == false)
    }

    @Test
    func `a name nobody uses resolves to nothing`() throws {
        let index = try Self.index
        #expect(index.application(named: "Subnautica") == nil)
    }

    @Test
    func `normalizing keeps letters and digits and drops the rest`() {
        #expect(DiscordApplications.normalized("Hollow Knight: Silksong") == "hollowknightsilksong")
        #expect(DiscordApplications.normalized("  Half-Life 2 ") == "halflife2")
        #expect(DiscordApplications.normalized("!?") == "")
    }

    @Test
    func `an index answers from disk without a download`() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("da-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let encoder = JSONEncoder()
        try encoder.encode(Self.index).write(to: file)

        // The database URL points at a file that does not exist, so a lookup
        // that answers proves the index on disk is what answered.
        let applications = DiscordApplications(
            databaseURL: URL(fileURLWithPath: "/nonexistent/detectable.json"), indexFile: file,
        )
        let application = try #require(await applications.applicationID(steamAppID: 1_962_700))
        #expect(application.name == "Subnautica 2")
        #expect(await applications.applicationID(named: "Silksong")?.id == "356875221078245376")
    }
}
