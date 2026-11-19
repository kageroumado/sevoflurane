import Foundation

/// Discord's detectable-games list (``databaseURL``, no authentication),
/// indexed by Steam app id, executable and name to the Discord application
/// a game is published under. The download is about 12 MB, almost all artwork
/// hashes and overlay flags, so only the index is kept on disk. It is refreshed
/// in the background once a week and a lookup answers from the index already
/// there; only the first lookup on a Mac with no index waits for the download.
///
/// A failed refresh leaves the stale index in place.
actor DiscordApplications {
    /// The index the app publishes through.
    static let shared = DiscordApplications()

    /// How long an index stands before it is downloaded again.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    static let databaseURL = URL(string: "https://discord.com/api/v9/applications/detectable")!

    static let indexFile = AppIdentity.supportFolder
        .appendingPathComponent("Discord/applications.json")

    /// The database as the app keeps it on disk: four tables and a format.
    struct Index: Codable, Sendable, Equatable {
        /// An index in any other format is read as absent and rebuilt.
        static let currentFormat = 2

        var format = Index.currentFormat
        /// Steam app id → Discord application id.
        var steam: [String: String] = [:]
        /// A normalized name or alias → Discord application id.
        var names: [String: String] = [:]
        /// A Windows executable as Discord's scanner names it, lowercased with
        /// as much of its path as Discord gives → Discord application id.
        var executables: [String: String] = [:]
        /// Discord application id → the name Discord shows for it.
        var titles: [String: String] = [:]

        func application(steamAppID: Int) -> (id: String, name: String)? {
            application(steam[String(steamAppID)])
        }

        /// Matches Discord's name or any alias.
        func application(named name: String) -> (id: String, name: String)? {
            application(names[DiscordApplications.normalized(name)])
        }

        /// The longest listed tail of `path` wins, as in Discord's scanner:
        /// `_retail_/wow.exe` over `wow.exe`.
        func application(executable path: String) -> (id: String, name: String)? {
            for tail in DiscordApplications.pathTails(path) {
                if let id = executables[tail] { return application(id) }
            }
            return nil
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

    func applicationID(steamAppID: Int) async -> (id: String, name: String)? {
        await current()?.application(steamAppID: steamAppID)
    }

    /// For a program with no Steam app id.
    func applicationID(named name: String) async -> (id: String, name: String)? {
        await current()?.application(named: name)
    }

    /// For a program with no Steam app id.
    func applicationID(executable path: String) async -> (id: String, name: String)? {
        await current()?.application(executable: path)
    }

    /// Memory, else disk, else a first download; a copy older than ``maxAge``
    /// still answers while a background refresh runs.
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

    /// Downloads and writes the index, one download at a time.
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

    /// One game in Discord's database, the fields the index uses.
    private struct Entry: Decodable {
        /// Optional fields: Discord carries skus with a null id (Battle.net,
        /// Uplay), and one must not lose the whole index.
        struct SKU: Decodable {
            let distributor: String?
            let id: String?
        }

        struct Executable: Decodable {
            /// Lowercased, with as many folders as Discord needs:
            /// `yandere school/yandereschool.exe`.
            let name: String?
            /// `win32`, `darwin` or `linux`.
            let os: String?
            let isLauncher: Bool?
            /// Arguments the process must carry too, for a shared exe such
            /// as Source's `hl2.exe`.
            let arguments: String?
        }

        let id: String
        let name: String
        let aliases: [String]?
        let thirdPartySkus: [SKU]?
        let executables: [Executable]?
    }

    /// The index built from the database's JSON; the first entry to claim a
    /// key keeps it. Only Windows executables are kept, minus launchers,
    /// argument matches and `>` whole-path names, which a path-only match
    /// would misattribute.
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
            for executable in entry.executables ?? [] where executable.os == "win32" {
                guard executable.isLauncher != true, executable.arguments == nil,
                      let name = executable.name, !name.hasPrefix(">") else { continue }
                let key = pathTails(name).first ?? ""
                guard !key.isEmpty, index.executables[key] == nil else { continue }
                index.executables[key] = entry.id
                claimed = true
            }
            if claimed { index.titles[entry.id] = entry.name }
        }
        return index
    }

    /// Lowercase alphanumerics only, applied to both sides of an exact match.
    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// Every tail of a path, longest first, lowercased with forward slashes
    /// and no drive letter: `C:\Games\A\B.exe` gives `games/a/b.exe`,
    /// `a/b.exe` and `b.exe`.
    static func pathTails(_ path: String) -> [String] {
        var components = path.lowercased()
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
        if let first = components.first, first.count == 2, first.hasSuffix(":") {
            components.removeFirst()
        }
        return components.indices.map { components[$0...].joined(separator: "/") }
    }

    // MARK: - Disk

    static func read(at path: URL) -> Index? {
        guard let data = try? Data(contentsOf: path),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              index.format == Index.currentFormat else { return nil }
        return index
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
