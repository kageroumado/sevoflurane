import Foundation
import Testing
@testable import Sevoflurane

/// Where the app points Discord for a game's box art.
struct SteamArtworkTests {
    @Test
    func `a hashed cache names the capsule and the header under their hashes first`() throws {
        let cache = try Self.makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.write("3263330/980d59d2591545e4ad39e47653bc9e5dd02eaa4c/library_600x900.jpg", in: cache)
        try Self.write("3263330/007ea9a1540b2263084c5ac56be606514786eb3d/library_header.jpg", in: cache)
        try Self.write("3263330/87f39b858f6340993f50e9a10305dde356a279a6/library_hero.jpg", in: cache)
        try Self.write("3263330/d8ee138edb1f0d1988131ed5018b9af7f0525b1d.jpg", in: cache)

        let app = "https://shared.steamstatic.com/store_item_assets/steam/apps/3263330/"
        #expect(SteamArtwork.coverCandidates(appID: 3_263_330, cache: cache).map(\.absoluteString) == [
            app + "980d59d2591545e4ad39e47653bc9e5dd02eaa4c/library_600x900.jpg",
            app + "library_600x900.jpg",
            app + "007ea9a1540b2263084c5ac56be606514786eb3d/header.jpg",
            app + "header.jpg",
        ])
    }

    @Test
    func `a flat or missing cache leaves the paths without a hash`() throws {
        let cache = try Self.makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.write("1086940/library_600x900.jpg", in: cache)

        let app = "https://shared.steamstatic.com/store_item_assets/steam/apps/"
        for appID in [1_086_940, 251_990] {
            #expect(SteamArtwork.coverCandidates(appID: appID, cache: cache).map(\.absoluteString) == [
                app + "\(appID)/library_600x900.jpg",
                app + "\(appID)/header.jpg",
            ])
        }
    }

    @Test
    func `the older capsule name counts as the capsule, served under that name`() throws {
        let cache = try Self.makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.write("4395870/90077bad1ad738a75eb45edca0447783004633a7/library_capsule.jpg", in: cache)

        let first = SteamArtwork.coverCandidates(appID: 4_395_870, cache: cache).first?.absoluteString
        #expect(first == "https://shared.steamstatic.com/store_item_assets/steam/apps/4395870/"
            + "90077bad1ad738a75eb45edca0447783004633a7/library_capsule.jpg")
    }

    private static func makeCache() throws -> URL {
        let cache = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("librarycache-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache
    }

    private static func write(_ path: String, in cache: URL) throws {
        let file = cache.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data().write(to: file)
    }
}
