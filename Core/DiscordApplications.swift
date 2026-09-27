import Foundation

/// Discord's list of the games it detects, reduced to the lookups the app
/// makes of it: a Steam app id or a program's name in, the Discord application
/// that game is published under out.
///
/// Discord serves the list at ``databaseURL`` with no authentication: every
/// game it knows, each with the application id it shows the game under, the
/// names it goes by, and the store ids it ships under. The download is about
/// 12 MB and almost all of it is artwork hashes and overlay flags, so only the
/// index is kept on disk. It is refreshed in the background once a week; a
/// lookup answers from whatever index is already there, so publishing a game's
/// activity never waits on the network. The first lookup on a Mac that has no
/// index yet is the one exception: it waits for the download, so the very
/// first game a player launches still shows up.
///
/// A source that cannot be reached reads as absent: a failed refresh leaves
/// the stale index in place, and a game the index does not name publishes
/// nothing.
actor DiscordApplications {
    /// The index the app publishes through.
    static let shared = DiscordApplications()

    /// How long an index stands before it is downloaded again. Games join the
    /// list continuously, and one already in it keeps its application id.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    static let databaseURL = URL(string: "https://discord.com/api/v9/applications/detectable")!

    static let indexFile = UserHome.url
        .appendingPathComponent("Library/Application Support/Sevoflurane/Discord/applications.json")

    /// The database as the app reads it: the two ways in, and the names to
    /// publish under them.
    ///
    /// Discord's own entries carry another two dozen fields — icon hashes,
    /// executables, overlay flags, content ratings — and the app wants none of
    /// them, so the file on disk is these three tables and nothing else.
    struct Index: Codable, Sendable, Equatable {
        /// Steam app id → Discord application id.
        var steam: [String: String] = [:]
        /// A normalized name or alias → Discord application id.
        var names: [String: String] = [:]
        /// Discord application id → the name Discord shows for it.
        var titles: [String: String] = [:]

        /// The application a Steam game is published under.
        func application(steamAppID: Int) -> (id: String, name: String)? {
            application(steam[String(steamAppID)])
        }

        /// The application a program's name resolves to, matching Discord's
        /// own name or any of its aliases.
        func application(named name: String) -> (id: String, name: String)? {
            application(names[DiscordApplications.normalized(name)])
        }

        private func application(_ id: String?) -> (id: String, name: String)? {
            guard let id, let name = titles[id] else { return nil }
            return (id, name)
        }
    }

    private let session: URLSession
    private let databaseURL: URL
    private let indexFile: URL
    private var index: Index?
    private var load: Task<Index?, Never>?

    /// - Parameters:
    ///   - session: the session the database is fetched over.
    ///   - databaseURL: where the database is served.
    ///   - indexFile: where the built index is kept between launches.
    init(
        session: URLSession? = nil,
        databaseURL: URL = DiscordApplications.databaseURL,
        indexFile: URL = DiscordApplications.indexFile,
    ) {
        self.databaseURL = databaseURL
        self.indexFile = indexFile
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 120
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            configuration.httpAdditionalHeaders = [
                "User-Agent": "Sevoflurane/\(version) (https://kagerou.glass; mail@kagerou.glass)",
                "Accept": "application/json",
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Lookups

    /// The Discord application a Steam game is published under.
    func applicationID(steamAppID: Int) async -> (id: String, name: String)? {
        await current()?.application(steamAppID: steamAppID)
    }

    /// The Discord application a program's name is published under, for a
    /// program that has no Steam app id.
    func applicationID(named name: String) async -> (id: String, name: String)? {
        await current()?.application(named: name)
    }

    /// The index to answer from: the one in memory, else the one on disk,
    /// else a first download. A copy older than ``maxAge`` still answers and
    /// is sent for a refresh the caller does not wait on.
    private func current() async -> Index? {
        let stale = Self.age(of: indexFile).map { $0 > Self.maxAge } ?? true
        if let index {
            if stale { refreshInBackground() }
            return index
        }
        if let onDisk = Self.read(at: indexFile) {
            index = onDisk
            if stale { refreshInBackground() }
            return onDisk
        }
        return await rebuild()
    }

    private func refreshInBackground() {
        guard load == nil else { return }
        Task(name: "Refresh the Discord application index") { _ = await self.rebuild() }
    }

    /// Downloads the database, builds the index and writes it, with one
    /// download in flight at a time.
    private func rebuild() async -> Index? {
        if let load { return await load.value }
        let task = Task<Index?, Never> { [session, databaseURL, indexFile] in
            do {
                let (data, response) = try await session.data(from: databaseURL)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200 ..< 300).contains(status), let built = Self.index(from: data) else {
                    return nil
                }
                Self.write(built, to: indexFile)
                return built
            } catch {
                return nil
            }
        }
        load = task
        let built = await task.value
        load = nil
        if let built { index = built }
        return built
    }

    // MARK: - Building the index

    /// One game as Discord's database describes it, in the four fields the
    /// index is built from.
    private struct Entry: Decodable {
        /// One store's id for the game. Discord carries a sku with a null id
        /// for a store that gave it none — Battle.net and Uplay both have
        /// them — and a whole index must not be lost to one of those, so
        /// every field a sku is read for is optional.
        struct SKU: Decodable {
            let distributor: String?
            let id: String?
        }

        let id: String
        let name: String
        let aliases: [String]?
        let thirdPartySkus: [SKU]?
    }

    /// The index built from the database's JSON.
    ///
    /// The first entry to claim a Steam id or a name keeps it, so a game that
    /// shares a name with a later one stays where the database put it.
    static func index(from data: Data) -> Index? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let entries = try? decoder.decode([Entry].self, from: data) else { return nil }
        var index = Index()
        for entry in entries where !entry.id.isEmpty {
            var claimed = false
            for sku in entry.thirdPartySkus ?? [] where sku.distributor == "steam" {
                guard let skuID = sku.id, let appID = Int(skuID) else { continue }
                let key = String(appID)
                guard index.steam[key] == nil else { continue }
                index.steam[key] = entry.id
                claimed = true
            }
            for name in [entry.name] + (entry.aliases ?? []) {
                let key = normalized(name)
                guard !key.isEmpty, index.names[key] == nil else { continue }
                index.names[key] = entry.id
                claimed = true
            }
            if claimed { index.titles[entry.id] = entry.name }
        }
        return index
    }

    /// A name reduced to what every spelling of it shares: lowercase, with
    /// spacing and punctuation removed.
    ///
    /// Both sides of a lookup pass through this, and the match is exact:
    /// "Hollow Knight: Silksong" and "hollowknightsilksong" are the same game,
    /// while a near miss is a different one.
    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    // MARK: - Disk

    static func read(at path: URL) -> Index? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Index.self, from: data)
    }

    private static func write(_ index: Index, to path: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(index) else { return }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: path, options: .atomic)
    }

    private static func age(of path: URL) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Date.now.timeIntervalSince(modified)
    }
}
