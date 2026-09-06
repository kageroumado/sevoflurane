import Foundation

/// Assembles one ``GameCompatRecord`` per app from the community databases,
/// with every source cached on disk so a game page answers offline after its
/// first look and no source is asked twice in a week.
///
/// Two of the sources are whole tables fetched once (AreWeAntiCheatYet's
/// `games.json`, AppleGamingWiki's compatibility table); two are per-app
/// lookups (ProtonDB's summary, PCGamingWiki's app-id-to-title bridge). A
/// source that cannot be reached reads as absent, never as an error: the
/// badge for a game nobody has data on is "Unknown", and the page must never
/// show a spinner that waits on a wiki.
actor GameCompatService {
    static let shared = GameCompatService()

    /// How long a cached answer stands before it is asked for again. The
    /// tables change a few times a month; ProtonDB's summaries drift slowly.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    static let cacheRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/Compat")

    private let session: URLSession
    private var antiCheatIndex: GameCompatSources.AntiCheatIndex?
    private var wikiIndex: GameCompatSources.WikiIndex?
    private var antiCheatLoad: Task<GameCompatSources.AntiCheatIndex?, Never>?
    private var wikiLoad: Task<GameCompatSources.WikiIndex?, Never>?

    init(session: URLSession? = nil) {
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
            try? FileManager.default.removeItem(at: Self.cacheRoot.appendingPathComponent("proton/\(appID).json"))
            try? FileManager.default.removeItem(at: Self.cacheRoot.appendingPathComponent("pcgw/\(appID).json"))
            try? FileManager.default.removeItem(at: Self.cacheRoot.appendingPathComponent("awacy.json"))
            try? FileManager.default.removeItem(at: Self.cacheRoot.appendingPathComponent("applegamingwiki.json"))
        }
        async let antiCheatTable = loadAntiCheatIndex()
        async let wikiTable = loadWikiIndex()
        async let proton = loadProton(appID: appID)
        let antiCheat = await antiCheatTable?.lookup(appID: appID, name: name)
        var wiki = await wikiTable?.lookup(title: name)
        if wiki == nil, let table = await wikiTable, let title = await loadPCGamingWikiTitle(appID: appID) {
            wiki = table.lookup(title: title)
        }
        let protonSummary = await proton
        return GameCompatRecord(
            appID: appID,
            name: name,
            antiCheat: antiCheat,
            wiki: wiki,
            proton: protonSummary,
            deckCategory: deckCategory,
            mac: GameCompatVerdict.mac(antiCheat: antiCheat, wiki: wiki, proton: protonSummary),
            antiCheatBadge: GameCompatVerdict.antiCheat(antiCheat),
            fetchedAt: .now,
        )
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
        file: String, from url: URL, acceptingMissesAs miss: Data? = nil,
    ) async -> Data? {
        let path = Self.cacheRoot.appendingPathComponent(file)
        if let data = Self.cached(at: path, maxAge: Self.maxAge) { return data }
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
