import Foundation

/// Where Steam's CDN serves a game's box art, found through the client's own
/// art cache.
///
/// Discord fetches an activity's picture from a public URL through its media
/// proxy, and Steam's CDN has one for every store game. Current clients cache
/// each asset under its content hash,
/// `librarycache/<appid>/<sha1>/library_600x900.jpg`, and the CDN serves a
/// recent game's art under that hash,
/// `store_item_assets/steam/apps/<appid>/<sha1>/library_600x900.jpg`; an
/// older game's is also served without the hash, which is all a flat cache
/// can point at. A hashed asset keeps its cached name on the CDN
/// (`library_capsule.jpg` stays `library_capsule.jpg`). The vertical capsule
/// is the box art; the store header stands in where a game has none.
nonisolated enum SteamArtwork {
    static let cdn = URL(string: "https://shared.steamstatic.com/store_item_assets/steam/apps/")!

    /// The vertical capsule's cached names, in both layouts.
    private static let capsuleNames = ["library_600x900.jpg", "library_capsule.jpg"]

    /// The URLs the game's box art may be served at, best first: the capsule
    /// under each hash the cache holds it under, by its cached name, the
    /// capsule without a hash, then the header the same two ways.
    static func coverCandidates(appID: Int, cache: URL = SteamBottle.libraryCache) -> [URL] {
        let app = cdn.appendingPathComponent(String(appID))
        let hashed = hashedAssets(appID: appID, cache: cache)
        var candidates: [URL] = []
        for (hash, names) in hashed {
            for name in capsuleNames where names.contains(name) {
                candidates.append(app.appendingPathComponent("\(hash)/\(name)"))
            }
        }
        candidates.append(app.appendingPathComponent("library_600x900.jpg"))
        for (hash, names) in hashed where names.contains("library_header.jpg") {
            candidates.append(app.appendingPathComponent("\(hash)/header.jpg"))
        }
        candidates.append(app.appendingPathComponent("header.jpg"))
        return candidates
    }

    /// The first of the game's ``coverCandidates(appID:cache:)`` the CDN
    /// serves, or `nil` when it serves none. Each `HEAD` waits 4 s at most:
    /// this runs between a game's window coming up and its status appearing.
    static func cover(
        appID: Int, cache: URL = SteamBottle.libraryCache, session: URLSession = .shared,
    ) async -> URL? {
        for candidate in coverCandidates(appID: appID, cache: cache) {
            var request = URLRequest(url: candidate, timeoutInterval: 4)
            request.httpMethod = "HEAD"
            guard let (_, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            return candidate
        }
        return nil
    }

    /// The game's content-addressed cache directories with their asset
    /// names, sorted by hash.
    private static func hashedAssets(appID: Int, cache: URL) -> [(hash: String, names: Set<String>)] {
        let manager = FileManager.default
        let appDirectory = cache.appendingPathComponent(String(appID))
        let entries = (try? manager.contentsOfDirectory(
            at: appDirectory, includingPropertiesForKeys: [.isDirectoryKey],
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { directory in
                let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
                return (directory.lastPathComponent, Set(names.map { $0.lowercased() }))
            }
    }
}
