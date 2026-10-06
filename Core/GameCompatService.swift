import Foundation

/// Assembles one ``GameCompatRecord`` per app from the community databases,
/// with every source cached on disk so a game page answers offline after its
/// first look and no source is asked twice in a week.
///
/// Two of the sources are whole tables fetched once (AreWeAntiCheatYet's
/// `games.json`, AppleGamingWiki's compatibility table); three are per-app
/// lookups (ProtonDB's summary, PCGamingWiki's app-id-to-title bridge,
/// Sevoflurane's own community summary, which also answers in batches for the
/// library). The client's app cache adds whether a macOS build exists. A
/// source that cannot be reached reads as absent, never as an error: the
/// badge for a game nobody has data on is "Unknown", and the page must never
/// show a spinner that waits on a wiki.
actor GameCompatService {
    static let shared = GameCompatService()

    /// How long a cached answer stands before it is asked for again. The
    /// tables change a few times a month; ProtonDB's summaries drift slowly.
    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let communityMaxAge: TimeInterval = 24 * 3600

    static let cacheRoot = AppIdentity.supportFolder
        .appendingPathComponent("Compat")

    private let session: URLSession
    /// Where this service keeps its answers: ``cacheRoot``, or a folder of a
    /// test's own.
    private let cache: URL
    /// The client's app cache, which says whether a macOS build exists.
    private let appInfo: URL
    private var antiCheatIndex: GameCompatSources.AntiCheatIndex?
    private var wikiIndex: GameCompatSources.WikiIndex?
    private var antiCheatLoad: Task<GameCompatSources.AntiCheatIndex?, Never>?
    private var wikiLoad: Task<GameCompatSources.WikiIndex?, Never>?

    init(session: URLSession? = nil, cache: URL = cacheRoot, appInfo: URL = SteamAppInfo.fileURL) {
        self.cache = cache
        self.appInfo = appInfo
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            // The wikis ask for a contactable agent string and cache-friendly
            // clients; both are cheap to give.
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            configuration.httpAdditionalHeaders = [
                "User-Agent": "Sevoflurane/\(version) (https://kagerou.glass; mail@kagerou.glass)",
                "Accept": "application/json",
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    /// The record for one app, as JSON for the page and the CLI.
    func recordJSON(appID: Int, name: String, deckCategory: Int?, ignoringCache: Bool = false) async -> Data {
        let record = await self.record(
            appID: appID, name: name, deckCategory: deckCategory, ignoringCache: ignoringCache,
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(record)) ?? Data("{}".utf8)
    }

    func record(appID: Int, name: String, deckCategory: Int?, ignoringCache: Bool = false) async -> GameCompatRecord {
        if ignoringCache {
            antiCheatIndex = nil
            wikiIndex = nil
            try? FileManager.default.removeItem(at: cache.appendingPathComponent("proton/\(appID).json"))
            try? FileManager.default.removeItem(at: cache.appendingPathComponent("pcgw/\(appID).json"))
            try? FileManager.default.removeItem(at: cache.appendingPathComponent("community/\(appID).json"))
            try? FileManager.default.removeItem(at: cache.appendingPathComponent("pcgw-mac/\(appID).json"))
            try? FileManager.default.removeItem(at: cache.appendingPathComponent("awacy.json"))
            try? FileManager.default.removeItem(at: cache.appendingPathComponent("applegamingwiki.json"))
        }
        async let antiCheatTable = loadAntiCheatIndex()
        async let wikiTable = loadWikiIndex()
        async let proton = loadProton(appID: appID)
        async let community = loadCommunity(appID: appID)
        let antiCheat = await antiCheatTable?.lookup(appID: appID, name: name)
        var wiki = await wikiTable?.lookup(title: name)
        if wiki == nil, let table = await wikiTable, let title = await loadPCGamingWikiTitle(appID: appID) {
            wiki = table.lookup(title: title)
        }
        let protonSummary = await proton
        let communitySummary = await community
        let hasMacBuild = SteamAppInfo.platforms(appID: appID, in: appInfo).contains("macos")
        // The architecture only changes the macOS cell, so it is asked for
        // only when that cell would show without it.
        let architectures = GameCompatVerdict.native(wiki: wiki, hasMacBuild: hasMacBuild) == nil
            ? nil : await loadMacArchitectures(appID: appID)
        return GameCompatRecord(
            appID: appID,
            name: name,
            antiCheat: antiCheat,
            wiki: wiki,
            proton: protonSummary,
            community: communitySummary,
            hasMacBuild: hasMacBuild,
            macArchitectures: architectures,
            deckCategory: deckCategory,
            mac: GameCompatVerdict.mac(
                antiCheat: antiCheat, wiki: wiki, proton: protonSummary, community: communitySummary,
            ),
            nativeBadge: GameCompatVerdict.native(
                wiki: wiki, hasMacBuild: hasMacBuild, architectures: architectures,
            ),
            antiCheatBadge: GameCompatVerdict.antiCheat(antiCheat),
            fetchedAt: .now,
        )
    }

    // MARK: - The library

    /// The library's verdicts for many games at once, from what costs no
    /// per-game request: the two whole tables, the community database's
    /// batches, the client's app cache, and whatever per-app answers the disk
    /// already holds. A per-app lookup the answer lacks joins the queue
    /// (``GameCompatBatch``), and the page asks again while ``pending`` says
    /// some remain. A macOS build that would count as playing waits on its
    /// architectures there too, as the game's page does: a 32-bit-only build
    /// plays nowhere on Apple silicon.
    func summaries(for games: [GameCompatBatch.Game]) async -> (summaries: [GameCompatSummary], pending: Int) {
        async let antiCheatTable = loadAntiCheatIndex()
        async let wikiTable = loadWikiIndex()
        async let communities = loadCommunities(appIDs: games.map(\.appID))
        let platforms = SteamAppInfo.platforms(appIDs: Set(games.map(\.appID)), in: appInfo)
        let antiCheatIndex = await antiCheatTable
        let wikiIndex = await wikiTable
        let community = await communities
        var lookups: [GameCompatBatch.Lookup] = []
        let summaries = games.map { game in
            let id = game.appID
            let antiCheat = antiCheatIndex?.lookup(appID: id, name: game.name)
            var wiki = wikiIndex?.lookup(title: game.name)
            var titlePending = false
            if wiki == nil, let wikiIndex {
                let (data, fresh) = cachedAnyAge(file: "pcgw/\(id).json")
                if let data, let title = GameCompatSources.pcGamingWikiTitle(data: data) {
                    wiki = wikiIndex.lookup(title: title)
                }
                if !fresh {
                    lookups.append(.title(id))
                    titlePending = data == nil
                }
            }
            var proton: GameCompatRecord.ProtonSummary?
            if !titlePending, GameCompatBatch.needsProton(antiCheat: antiCheat, wiki: wiki, community: community[id]) {
                let (data, fresh) = cachedAnyAge(file: "proton/\(id).json")
                proton = data.flatMap { GameCompatSources.protonSummary(appID: id, data: $0) }
                if !fresh { lookups.append(.proton(id)) }
            }
            let hasMacBuild = platforms[id]?.contains("macos") == true
            var architectures: GameCompatRecord.MacArchitectures?
            if GameCompatVerdict.native(wiki: wiki, hasMacBuild: hasMacBuild) != nil {
                let (data, fresh) = cachedAnyAge(file: "pcgw-mac/\(id).json")
                architectures = data.flatMap {
                    try? JSONDecoder().decode(GameCompatRecord.MacArchitectures?.self, from: $0)
                }
                if !fresh { lookups.append(.architecture(id)) }
            }
            return GameCompatVerdict.summary(
                appID: id, antiCheat: antiCheat, wiki: wiki, proton: proton, community: community[id],
                hasMacBuild: hasMacBuild, architectures: architectures,
            )
        }
        enqueue(lookups)
        return (summaries, queuedLookups.count)
    }

    /// Lookups waiting for their turn or in flight, in order and as a set.
    private var lookupQueue: [GameCompatBatch.Lookup] = []
    private var queuedLookups: Set<GameCompatBatch.Lookup> = []
    private var lookupDrain: Task<Void, Never>?

    private func enqueue(_ lookups: [GameCompatBatch.Lookup]) {
        for lookup in lookups where queuedLookups.insert(lookup).inserted {
            lookupQueue.append(lookup)
        }
        guard lookupDrain == nil, !lookupQueue.isEmpty else { return }
        lookupDrain = Task(name: "Compat lookups") { await self.drainLookups() }
    }

    /// Runs the queue one lookup at a time, ``GameCompatBatch/lookupInterval``
    /// apart; each answer lands in the disk cache the next ask reads.
    private func drainLookups() async {
        while !lookupQueue.isEmpty {
            let lookup = lookupQueue.removeFirst()
            switch lookup {
            case let .title(id): _ = await loadPCGamingWikiTitle(appID: id)
            case let .proton(id): _ = await loadProton(appID: id)
            case let .architecture(id):
                // The page text is asked for by title, which is a request
                // of its own when the disk lacks it, and takes its own turn.
                if Self.cached(at: cache.appendingPathComponent("pcgw/\(id).json"), maxAge: Self.maxAge) == nil {
                    _ = await loadPCGamingWikiTitle(appID: id)
                    try? await Task.sleep(for: GameCompatBatch.lookupInterval)
                }
                _ = await loadMacArchitectures(appID: id)
            }
            queuedLookups.remove(lookup)
            try? await Task.sleep(for: GameCompatBatch.lookupInterval)
        }
        lookupDrain = nil
    }

    /// Sevoflurane's own summaries for many games: a day-fresh cached answer
    /// where there is one, the batch endpoint for the rest, each answer
    /// cached per game as ``loadCommunity(appID:)`` caches it. A batch that
    /// fails leaves its games on whatever stale answer the disk holds.
    private func loadCommunities(appIDs: [Int]) async -> [Int: GameCompatRecord.Community] {
        var summaries: [Int: GameCompatRecord.Community] = [:]
        var missing: [Int] = []
        for id in appIDs {
            let path = cache.appendingPathComponent("community/\(id).json")
            if let data = Self.cached(at: path, maxAge: Self.communityMaxAge) {
                summaries[id] = GameCompatSources.community(data: data)
            } else {
                missing.append(id)
            }
        }
        for request in GameCompatBatch.communityRequests(base: StatsUploader.baseURL, appIDs: missing) {
            var bodies: [Int: Data]?
            if let (data, response) = try? await session.data(from: request.url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                bodies = GameCompatBatch.communityBodies(data)
            }
            for id in request.appIDs {
                let path = cache.appendingPathComponent("community/\(id).json")
                if let bodies {
                    let body = bodies[id] ?? Data("{}".utf8)
                    Self.store(body, at: path)
                    summaries[id] = GameCompatSources.community(data: body)
                } else if let stale = Self.cached(at: path, maxAge: nil) {
                    summaries[id] = GameCompatSources.community(data: stale)
                }
            }
        }
        return summaries
    }

    /// A cached answer whatever its age, and whether it is still fresh.
    private func cachedAnyAge(file: String) -> (data: Data?, fresh: Bool) {
        let path = cache.appendingPathComponent(file)
        if let data = Self.cached(at: path, maxAge: Self.maxAge) { return (data, true) }
        return (Self.cached(at: path, maxAge: nil), false)
    }

    // MARK: - Whole tables

    private func loadAntiCheatIndex() async -> GameCompatSources.AntiCheatIndex? {
        if let antiCheatIndex { return antiCheatIndex }
        if let antiCheatLoad { return await antiCheatLoad.value }
        let task = Task<GameCompatSources.AntiCheatIndex?, Never> {
            guard let data = await self.cachedOrFetched(
                file: "awacy.json", from: GameCompatSources.antiCheatDataURL,
            ) else { return nil }
            return try? GameCompatSources.AntiCheatIndex(data: data)
        }
        antiCheatLoad = task
        let index = await task.value
        antiCheatIndex = index
        antiCheatLoad = nil
        return index
    }

    private func loadWikiIndex() async -> GameCompatSources.WikiIndex? {
        if let wikiIndex { return wikiIndex }
        if let wikiLoad { return await wikiLoad.value }
        let task = Task<GameCompatSources.WikiIndex?, Never> {
            guard let data = await self.cachedOrFetched(
                file: "applegamingwiki.json", from: GameCompatSources.wikiExportURL,
            ) else { return nil }
            return try? GameCompatSources.WikiIndex(data: data)
        }
        wikiLoad = task
        let index = await task.value
        wikiIndex = index
        wikiLoad = nil
        return index
    }

    // MARK: - Per-app lookups

    private func loadProton(appID: Int) async -> GameCompatRecord.ProtonSummary? {
        guard let data = await cachedOrFetched(
            file: "proton/\(appID).json", from: GameCompatSources.protonSummaryURL(appID: appID),
            // A missing app is a 404 with an HTML page; caching the miss
            // keeps the next look at the same game off the network too.
            acceptingMissesAs: Data("{}".utf8),
        ) else { return nil }
        return GameCompatSources.protonSummary(appID: appID, data: data)
    }

    /// Sevoflurane's own summary for the app. Runs arrive daily, so this
    /// answer is kept a day where the community tables are kept a week.
    private func loadCommunity(appID: Int) async -> GameCompatRecord.Community? {
        guard let data = await cachedOrFetched(
            file: "community/\(appID).json",
            from: StatsUploader.baseURL.appendingPathComponent("games/\(appID)"),
            maxAge: Self.communityMaxAge,
            acceptingMissesAs: Data("{}".utf8),
        ) else { return nil }
        return GameCompatSources.community(data: data)
    }

    /// The macOS build's architectures from the game's PCGamingWiki page.
    /// Only the three fields are kept on disk; a page is tens of kilobytes.
    private func loadMacArchitectures(appID: Int) async -> GameCompatRecord.MacArchitectures? {
        let path = cache.appendingPathComponent("pcgw-mac/\(appID).json")
        if let data = Self.cached(at: path, maxAge: Self.maxAge) {
            return try? JSONDecoder().decode(GameCompatRecord.MacArchitectures?.self, from: data)
        }
        guard let title = await loadPCGamingWikiTitle(appID: appID) else {
            // PCGamingWiki answered and has no page for the app: kept as an
            // answer, so the library's queue asks again only once it is stale.
            if Self.cached(at: cache.appendingPathComponent("pcgw/\(appID).json"), maxAge: Self.maxAge) != nil {
                Self.store(Data("null".utf8), at: path)
            }
            return nil
        }
        guard let url = GameCompatSources.pcGamingWikiTextURL(title: title),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = GameCompatSources.pcGamingWikiText(data: data)
        else { return nil }
        var architectures = GameCompatSources.macArchitectures(wikitext: text)
        architectures?.pageURL = GameCompatSources.pcGamingWikiPageURL(title: title)
        if let encoded = try? JSONEncoder().encode(architectures) { Self.store(encoded, at: path) }
        return architectures
    }

    private func loadPCGamingWikiTitle(appID: Int) async -> String? {
        guard let data = await cachedOrFetched(
            file: "pcgw/\(appID).json", from: GameCompatSources.pcGamingWikiLookupURL(appID: appID),
        ) else { return nil }
        return GameCompatSources.pcGamingWikiTitle(data: data)
    }

    // MARK: - Disk cache

    /// The cached body when it is younger than ``maxAge``; otherwise a fresh
    /// fetch, written back on success. A stale file stands in when the
    /// network fails, so an offline machine keeps its last answers.
    private func cachedOrFetched(
        file: String, from url: URL, maxAge: TimeInterval = GameCompatService.maxAge, acceptingMissesAs miss: Data? = nil,
    ) async -> Data? {
        let path = cache.appendingPathComponent(file)
        if let data = Self.cached(at: path, maxAge: maxAge) { return data }
        do {
            let (data, response) = try await session.data(from: url)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 404, let miss {
                Self.store(miss, at: path)
                return miss
            }
            guard (200 ..< 300).contains(status) else {
                throw GameCompatError("\(url.host ?? "source") answered \(status)")
            }
            Self.store(data, at: path)
            return data
        } catch {
            return Self.cached(at: path, maxAge: nil)
        }
    }

    private static func cached(at path: URL, maxAge: TimeInterval?) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if let maxAge, Date.now.timeIntervalSince(modified) > maxAge { return nil }
        return try? Data(contentsOf: path)
    }

    private static func store(_ data: Data, at path: URL) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: path, options: .atomic)
    }
}
