import Foundation

/// The shape of the library's bulk question: the games it asks about, the
/// community database's batch endpoint, the per-app lookups that wait for
/// their turn, and the compact answer the page reads.
///
/// The whole-table sources (AppleGamingWiki, AreWeAntiCheatYet) and the
/// client's app cache cost nothing per game, and Sevoflurane's database
/// answers a hundred games a request. What remains per game is PCGamingWiki's
/// app-id-to-title bridge, asked only for a title the wiki does not know by
/// name, and ProtonDB, asked only when nothing Mac-side has a verdict, which
/// keeps the badge in the library the same as the strip on the game's page,
/// and PCGamingWiki's page for a macOS build that would otherwise count as
/// playing. All wait in a queue one second apart, PCGamingWiki's published
/// rate.
nonisolated enum GameCompatBatch {
    /// One game the library asks about: its app id and display name, the
    /// name being what the wiki joins on.
    struct Game: Equatable, Sendable {
        let appID: Int
        let name: String
    }

    /// One per-app lookup left for the queue.
    enum Lookup: Hashable, Sendable {
        /// PCGamingWiki's page title for the app.
        case title(Int)
        /// ProtonDB's summary for the app.
        case proton(Int)
        /// The architectures of the app's macOS build, from its PCGamingWiki
        /// page.
        case architecture(Int)
    }

    /// The most games one request may name; a library past this asks again.
    static let maxGames = 5000
    /// The most app ids the community database answers in one request.
    static let communityChunk = 100
    /// The pause between two queued lookups.
    static let lookupInterval: Duration = .seconds(1)

    /// The games in a `POST /__compat/batch` body, `{"apps": [[appid, "name"], …]}`.
    /// Entries off the shape are skipped, and the first of two with one id wins.
    static func games(fromRequest body: Data) -> [Game] {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let apps = object["apps"] as? [[Any]] else { return [] }
        var seen: Set<Int> = []
        var games: [Game] = []
        for entry in apps.prefix(maxGames) {
            guard let id = (entry.first as? NSNumber)?.intValue, id > 0, seen.insert(id).inserted else { continue }
            games.append(Game(appID: id, name: entry.count > 1 ? entry[1] as? String ?? "" : ""))
        }
        return games
    }

    /// The community database's batch requests for `appIDs`, a hundred apiece.
    static func communityRequests(base: URL, appIDs: [Int]) -> [(url: URL, appIDs: [Int])] {
        stride(from: 0, to: appIDs.count, by: communityChunk).compactMap { start in
            let chunk = Array(appIDs[start ..< min(start + communityChunk, appIDs.count)])
            var components = URLComponents(url: base.appendingPathComponent("games"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "appids", value: chunk.map(String.init).joined(separator: ","))]
            return components?.url.map { ($0, chunk) }
        }
    }

    /// Each game's summary out of a batch answer, `{"<appid>": {…}, …}`, as
    /// the body `GET /v1/games/<appid>` would have returned, so it is cached
    /// and read like one. `nil` when the answer is not that shape.
    static func communityBodies(_ data: Data) -> [Int: Data]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var bodies: [Int: Data] = [:]
        for (key, value) in object {
            guard let id = Int(key), JSONSerialization.isValidJSONObject(value),
                  let body = try? JSONSerialization.data(withJSONObject: value) else { continue }
            bodies[id] = body
        }
        return bodies
    }

    /// Whether ProtonDB's summary could change the game's verdict: only when
    /// Sevoflurane's players, the wiki and anti-cheat all leave it open.
    static func needsProton(
        antiCheat: GameCompatRecord.AntiCheat?,
        wiki: GameCompatRecord.WikiTiers?,
        community: GameCompatRecord.Community?,
    ) -> Bool {
        if let community, GameCompatVerdict.rank(community.verdict) != nil { return false }
        if let wiki, GameCompatVerdict.wikiEvidence(wiki) != nil { return false }
        return GameCompatVerdict.antiCheatBlocker(antiCheat) == nil
    }

    /// The page's answer: `{"pending": n, "apps": {"<appid>": {"s": state, "n": native}}}`.
    /// A game with nothing to draw (Unknown, no playable macOS build) is left
    /// out, which the page reads as Unknown. `pending` counts the lookups
    /// still queued, so the page knows to ask again.
    static func answer(_ summaries: [GameCompatSummary], pending: Int) -> Data {
        var apps: [String: Any] = [:]
        for summary in summaries where summary.state != .unknown || summary.native {
            apps[String(summary.appID)] = ["s": summary.state.rawValue, "n": summary.native]
        }
        let object: [String: Any] = ["pending": pending, "apps": apps]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
