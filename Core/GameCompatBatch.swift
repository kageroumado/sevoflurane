import Foundation

/// The library's bulk compat question and the compact answer the page reads.
/// Per-game lookups (PCGamingWiki's title and page, ProtonDB when nothing
/// Mac-side decides) queue one second apart, PCGamingWiki's published rate.
nonisolated enum GameCompatBatch {
    /// One game; the wiki joins on its name.
    struct Game: Equatable, Sendable {
        let appID: Int
        let name: String
    }

    enum Lookup: Hashable, Sendable {
        /// PCGamingWiki's page title.
        case title(Int)
        case proton(Int)
        /// The macOS build's architectures, from PCGamingWiki.
        case architecture(Int)
    }

    static let maxGames = 5000
    /// App ids per community request.
    static let communityChunk = 100
    static let lookupInterval: Duration = .seconds(1)

    /// The games in a `POST /__compat/batch` body, `{"apps": [[appid, "name"], …]}`;
    /// the first of two with one id wins.
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

    /// Each game's body out of a batch answer, `{"<appid>": {…}, …}`, shaped
    /// like `GET /v1/games/<appid>`.
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

    /// Whether ProtonDB could change the verdict.
    static func needsProton(
        antiCheat: GameCompatRecord.AntiCheat?,
        wiki: GameCompatRecord.WikiTiers?,
        community: GameCompatRecord.Community?,
    ) -> Bool {
        if let community, GameCompatVerdict.rank(community.verdict) != nil { return false }
        if let wiki, GameCompatVerdict.wikiEvidence(wiki) != nil { return false }
        return GameCompatVerdict.antiCheatBlocker(antiCheat) == nil
    }

    /// `{"pending": n, "apps": {"<appid>": {"s", "t", "l", "n", "p", "m", "c"}}}`: `t` the
    /// tier, `l` ProtonDB alone, `n` a macOS build that runs on Apple silicon, `p` kept by
    /// the Apple filter (``GameCompatSummary/playsOnMac``), `m` set to its macOS build
    /// (`macBuilds`), `c` a companion's partner. A game with nothing to draw is left out.
    static func answer(_ summaries: [GameCompatSummary], pending: Int, macBuilds: Set<Int> = []) -> Data {
        var apps: [String: Any] = [:]
        for summary in summaries {
            let mac = macBuilds.contains(summary.appID)
            guard summary.state != .unknown || summary.native || summary.macRunnable || mac else { continue }
            var entry: [String: Any] = ["s": summary.state.rawValue, "n": summary.native || summary.macRunnable]
            if let tier = summary.tier { entry["t"] = tier.rawValue }
            if summary.linuxOnly { entry["l"] = true }
            if summary.playsOnMac { entry["p"] = true }
            if mac { entry["m"] = true }
            if let partner = summary.companion { entry["c"] = partner }
            apps[String(summary.appID)] = entry
        }
        let object: [String: Any] = ["pending": pending, "apps": apps]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
