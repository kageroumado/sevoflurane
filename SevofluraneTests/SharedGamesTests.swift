import Foundation
import Testing
@testable import Sevoflurane

/// Games linked from another bottle, as the active bottle's library lists them.
struct SharedGamesTests {
    @Test
    func `a link whose source bottle lost the game is still listed, so it can be removed`() throws {
        let steamapps = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-games-tests-\(UUID().uuidString)/steamapps")
        let common = steamapps.appendingPathComponent("common")
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: steamapps.deletingLastPathComponent()) }
        let manifest = """
        "AppState"
        {
            "appid"     "480"
            "name"      "Spacewar"
            "installdir"        "Spacewar"
            "SizeOnDisk"        "1024"
        }
        """
        try Data(manifest.utf8).write(to: steamapps.appendingPathComponent("appmanifest_480.acf"))
        let gone = steamapps.deletingLastPathComponent().appendingPathComponent("other-bottle/common/Spacewar")
        try FileManager.default.createSymbolicLink(
            at: common.appendingPathComponent("Spacewar"), withDestinationURL: gone,
        )

        let games = SharedGames.installedGames(in: steamapps)

        #expect(games.map(\.appID) == [480])
    }

    @Test
    func `a game with no folder at all is not listed`() throws {
        let steamapps = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-games-tests-\(UUID().uuidString)/steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: steamapps.deletingLastPathComponent()) }
        let manifest = "\"appid\" \"480\"\n\"name\" \"Spacewar\"\n\"installdir\" \"Spacewar\"\n"
        try Data(manifest.utf8).write(to: steamapps.appendingPathComponent("appmanifest_480.acf"))

        #expect(SharedGames.installedGames(in: steamapps).isEmpty)
    }
}
