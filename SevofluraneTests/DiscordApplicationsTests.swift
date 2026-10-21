import Foundation
import Testing
@testable import Sevoflurane

/// How Discord's detectable-games database becomes the three lookups the app
/// makes of it.
///
/// The fixture is five entries in the shape Discord serves — one with a Steam
/// sku, one with aliases and a sku whose id is null, one with neither, and two
/// told apart by their executables — so the index is built from the same JSON
/// the network would hand over, without a network.
struct DiscordApplicationsTests {
    /// Five games as `applications/detectable` describes them, cut down to
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
        ],
        "executables": [
          {"is_launcher": false, "name": "subnautica2/binaries/win64/subnautica2-win64-shipping.exe", "os": "win32"},
          {"is_launcher": true, "name": "launcher.exe", "os": "win32"}
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
      },
      {
        "id": "1353836617093349476",
        "name": "Yandere School",
        "executables": [
          {"is_launcher": false, "name": "yandere school/yandereschool.exe", "os": "win32"},
          {"is_launcher": false, "name": "yandereschool", "os": "darwin"},
          {"is_launcher": false, "name": "wow.exe", "os": "win32"}
        ]
      },
      {
        "id": "356876176465199104",
        "name": "World of Warcraft",
        "executables": [
          {"is_launcher": false, "name": "_retail_/wow.exe", "os": "win32"},
          {"is_launcher": false, "name": ">hl2.exe", "os": "win32"},
          {"is_launcher": false, "name": "hl2.exe", "os": "win32", "arguments": "-game cstrike"}
        ]
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
    func `an executable resolves by the tail of its path`() throws {
        let index = try Self.index
        for path in [
            "/Users/someone/Games/Yandere School/YandereSchool.exe",
            #"C:\Games\Yandere School\YANDERESCHOOL.EXE"#,
        ] {
            let application = try #require(index.application(executable: path))
            #expect(application.id == "1353836617093349476")
            #expect(application.name == "Yandere School")
        }
        // Discord names the folder as well, so the file alone is not enough.
        #expect(index.application(executable: "/Games/Elsewhere/YandereSchool.exe") == nil)
    }

    @Test
    func `the longest tail Discord lists wins`() throws {
        let index = try Self.index
        #expect(index.application(executable: "/Games/WoW/_retail_/Wow.exe")?.name == "World of Warcraft")
        #expect(index.application(executable: "/Games/WoW/_classic_/Wow.exe")?.name == "Yandere School")
    }

    @Test
    func `only the windows executables the path alone identifies are kept`() throws {
        let index = try Self.index
        #expect(index.executables.keys.sorted() == [
            "_retail_/wow.exe",
            "subnautica2/binaries/win64/subnautica2-win64-shipping.exe",
            "wow.exe",
            "yandere school/yandereschool.exe",
        ])
        #expect(index.application(executable: "/Games/Subnautica/launcher.exe") == nil)
        #expect(index.application(executable: "/Games/Source/hl2.exe") == nil)
    }

    @Test
    func `a path's tails run from the longest to the file alone`() {
        #expect(DiscordApplications.pathTails(#"C:\Games\Yandere School\YandereSchool.exe"#) == [
            "games/yandere school/yandereschool.exe",
            "yandere school/yandereschool.exe",
            "yandereschool.exe",
        ])
        #expect(DiscordApplications.pathTails("/Users/a/Game.exe") == [
            "users/a/game.exe", "a/game.exe", "game.exe",
        ])
    }

    @Test
    func `an index in another format reads as absent`() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("da-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // Three tables and no format: the index as it was kept before executables.
        try Data(#"{"names":{"silksong":"1"},"steam":{},"titles":{"1":"Silksong"}}"#.utf8)
            .write(to: file)
        #expect(DiscordApplications.read(at: file) == nil)

        var index = try Self.index
        index.format = DiscordApplications.Index.currentFormat - 1
        try JSONEncoder().encode(index).write(to: file)
        #expect(DiscordApplications.read(at: file) == nil)

        index.format = DiscordApplications.Index.currentFormat
        try JSONEncoder().encode(index).write(to: file)
        #expect(DiscordApplications.read(at: file) == index)
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
        #expect(await applications.applicationID(
            executable: "/Games/Yandere School/YandereSchool.exe",
        )?.id == "1353836617093349476")
    }
}
