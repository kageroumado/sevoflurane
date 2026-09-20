import Foundation

/// What Sevoflurane and its bottle occupy on disk, and what may be reclaimed.
///
/// Sizes come from `du`, not from a directory walk: a Steam library is
/// hundreds of thousands of files, and the C implementation is the difference
/// between a pane that fills in and one that hangs.
nonisolated enum StorageInventory {
    struct Entry: Identifiable, Sendable, Equatable {
        /// The one entry Settings' search can send someone to, and the one
        /// that opens into a list of its own.
        static let gamesID = "games"
        /// The other entry that opens into a list: the Windows programs the
        /// user added by hand.
        static let programsID = "programs"

        let id: String
        let name: String
        let detail: String
        let url: URL
        var bytes: Int64
        /// Whether removing it is this app's business. Games are Steam's, and
        /// the client reinstalls itself through Repair.
        let removal: Removal?
    }

    enum Removal: Sendable, Equatable {
        /// Comes back on its own — a cache, a rebuilt tree.
        case regenerated(String)
        /// Gone until the user installs it again.
        case permanent(String)

        var caution: String {
            switch self {
            case let .regenerated(what): what
            case let .permanent(what): what
            }
        }
    }

    /// Everything worth showing, unsized. Sizing is the slow part and is done
    /// separately so the list can be drawn immediately.
    static func entries() -> [Entry] {
        bottleEntries() + supportEntries()
    }

    /// What lives inside the bottle: Steam, its games, and the Windows drive.
    private static func bottleEntries() -> [Entry] {
        let bottle = SteamBottle.root
        let steam = SteamBottle.steamRoot
        return [
            Entry(
                id: Entry.gamesID,
                name: "Games",
                detail: "Every game Steam has installed on this Mac.",
                url: steam.appendingPathComponent("steamapps"),
                bytes: -1,
                removal: nil,
            ),
            Entry(
                id: Entry.programsID,
                name: "Added programs",
                detail: "Windows programs you added, and what their installers wrote here.",
                // The size is the sum of the directories the installers made,
                // which all sit under this drive.
                url: bottle.appendingPathComponent("drive_c"),
                bytes: -1,
                removal: nil,
            ),
            Entry(
                id: "client",
                name: "Steam client",
                detail: "The client itself, without its games.",
                url: steam,
                bytes: -1,
                removal: nil,
            ),
            Entry(
                id: "caches",
                name: "Client caches",
                detail: "Web cache, library art, and crash dumps.",
                url: steam.appendingPathComponent("appcache"),
                bytes: -1,
                removal: .regenerated("Steam rebuilds these as it runs."),
            ),
            Entry(
                id: "bottle",
                name: "Windows environment",
                detail: "The Windows drive Steam runs inside.",
                url: bottle,
                bytes: -1,
                removal: nil,
            ),
        ]
    }

    /// What Sevoflurane keeps for itself: engines, graphics layers, and logs.
    private static func supportEntries() -> [Entry] {
        let support = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Sevoflurane")
        return [
            Entry(
                id: "engines",
                name: "Dormison engines",
                detail: "Sevoflurane's own Wine engines, one folder per version.",
                url: support.appendingPathComponent("Engines"),
                bytes: -1,
                removal: .permanent("Setup downloads one again if you need it."),
            ),
            Entry(
                id: "renderers",
                name: "Renderer versions",
                detail: "DXMT and DXVK versions added beside the engine's own.",
                url: RendererVersions.root,
                bytes: -1,
                removal: .permanent("Settings › Graphics downloads or adds them again."),
            ),
            Entry(
                id: "shaders",
                name: "Shader packages",
                detail: "Upscalers downloaded for Dormison.",
                url: ShaderPackages.root,
                bytes: -1,
                removal: .permanent("Settings › Graphics downloads them again."),
            ),
            Entry(
                id: "toolkits",
                name: "Apple's Game Porting Toolkit",
                detail: "The DirectX 12 translator versions you added.",
                url: support.appendingPathComponent("D3DMetal"),
                bytes: -1,
                removal: .permanent("Download it from Apple again to get it back."),
            ),
            Entry(
                id: "shadow",
                name: "CrossOver links",
                detail: "Shortcuts that point CrossOver at the toolkit you added.",
                url: CrossOverShadow.root,
                bytes: -1,
                removal: .regenerated("Rebuilt the next time a game starts."),
            ),
            Entry(
                id: "logs",
                name: "Logs",
                detail: "The event log this app writes.",
                // Named here rather than taken from `EventLog`, which lives in
                // the app: `sevo` reports storage too, and shares this file.
                url: FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Library/Logs/Sevoflurane.log"),
                bytes: -1,
                removal: .regenerated("A new one starts on the next launch."),
            ),
        ]
    }

    /// The disk the bottle sits on: what it is called and how full it is.
    struct Volume: Sendable, Equatable {
        let name: String
        let capacity: Int64
        let available: Int64

        var used: Int64 {
            max(0, capacity - available)
        }
    }

    /// The volume that holds the Steam bottle, or the home directory's while
    /// no bottle exists. Available space is the figure Finder reports, which
    /// counts what the system would purge to make room.
    static func volume() -> Volume? {
        let manager = FileManager.default
        let root = manager.fileExists(atPath: SteamBottle.root.path)
            ? SteamBottle.root
            : manager.homeDirectoryForCurrentUser
        guard let values = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey,
        ]), let capacity = values.volumeTotalCapacity,
        let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Volume(
            name: values.volumeName ?? root.path,
            capacity: Int64(capacity),
            available: available,
        )
    }

    /// One installed game, as Steam itself accounts for it.
    struct Game: Identifiable, Sendable, Equatable {
        let id: Int
        let name: String
        let bytes: Int64
    }

    /// What is installed, largest first.
    ///
    /// Read from Steam's own `appmanifest_*.acf` files rather than measured:
    /// the client already knows every game's size on disk, and asking the
    /// filesystem the same question would walk a quarter of a million files
    /// to reach the same number.
    static func installedGames() -> [Game] {
        let steamapps = SteamBottle.steamRoot.appendingPathComponent("steamapps")
        let manifests = (try? FileManager.default.contentsOfDirectory(
            at: steamapps, includingPropertiesForKeys: nil,
        ))?.filter {
            $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf"
        } ?? []
        return manifests.compactMap(game(inManifest:)).sorted { $0.bytes > $1.bytes }
    }

    /// The three fields worth having out of an ACF: a flat `"key" "value"`
    /// format, so a full VDF parser would be ceremony.
    private static func game(inManifest url: URL) -> Game? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func value(_ key: String) -> String? {
            guard let range = text.range(of: "\"\(key)\"") else { return nil }
            let rest = text[range.upperBound...]
            guard let open = rest.firstIndex(of: "\""),
                  let close = rest[rest.index(after: open)...].firstIndex(of: "\"")
            else { return nil }
            return String(rest[rest.index(after: open) ..< close])
        }
        guard let id = value("appid").flatMap(Int.init), let name = value("name") else {
            return nil
        }
        return Game(id: id, name: name, bytes: value("SizeOnDisk").flatMap(Int64.init) ?? 0)
    }

    /// One Windows program the user added.
    struct Program: Identifiable, Sendable, Equatable {
        let id: Int
        let name: String
        /// The executable, for the row's second line.
        let path: String
        /// The directory an installer created inside the bottle, when there
        /// is one — the only part of a program this app may remove.
        let installedRoot: URL?
        var bytes: Int64

        /// Whether removing the entry also frees disk space. A program run
        /// from a folder of the user's own leaves its files behind.
        var isInsideBottle: Bool {
            installedRoot != nil
        }
    }

    /// The added programs, by name, unsized.
    static func addedPrograms() -> [Program] {
        AdoptedPrograms.all().map { entry in
            Program(
                id: entry.id,
                name: entry.name,
                path: entry.program.path,
                installedRoot: entry.program.installedRoot.map { URL(fileURLWithPath: $0) },
                bytes: -1,
            )
        }
    }

    /// What one added program occupies: the installer's directory, or nothing
    /// when the program runs from files the user keeps elsewhere.
    @concurrent
    static func size(of program: Program) async -> Int64 {
        guard let root = program.installedRoot else { return 0 }
        return await bytes(at: root)
    }

    /// Forgets a program, and moves what its installer wrote to the Trash.
    static func remove(program: Program) throws {
        if let root = program.installedRoot,
           FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.trashItem(at: root, resultingItemURL: nil)
        }
        AdoptedPrograms.remove(program.id)
    }

    /// The size of one entry, or 0 when it is not there. `steamapps` is
    /// subtracted from the client, and the client and the added programs from
    /// the bottle, so the numbers add up rather than nesting.
    @concurrent
    static func size(of entry: Entry) async -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: entry.url.path) else { return 0 }
        switch entry.id {
        case Entry.programsID:
            var total: Int64 = 0
            for program in addedPrograms() {
                total += await size(of: program)
            }
            return total
        case "client":
            return await max(0, bytes(at: entry.url) - bytes(
                at: entry.url.appendingPathComponent("steamapps"),
            ))
        case "bottle":
            let whole = await bytes(at: entry.url)
            let steam = await bytes(at: SteamBottle.steamRoot)
            var programs: Int64 = 0
            for program in addedPrograms() {
                programs += await size(of: program)
            }
            return max(0, whole - steam - programs)
        case "caches":
            var total: Int64 = 0
            for cache in cacheDirectories {
                total += await bytes(at: cache)
            }
            return total
        default:
            return await bytes(at: entry.url)
        }
    }

    /// Moves an entry to the Trash. Never an unrecoverable delete: this pane
    /// points at a games library, and a wrong click there costs a weekend of
    /// downloading.
    static func trash(_ entry: Entry) throws {
        let manager = FileManager.default
        if entry.id == "caches" {
            for cache in cacheDirectories where manager.fileExists(atPath: cache.path) {
                try? manager.trashItem(at: cache, resultingItemURL: nil)
            }
            return
        }
        guard manager.fileExists(atPath: entry.url.path) else { return }
        try manager.trashItem(at: entry.url, resultingItemURL: nil)
    }

    private static var cacheDirectories: [URL] {
        ["appcache", "depotcache", "dumps"].map(SteamBottle.steamRoot.appendingPathComponent)
            + [SteamBottle.htmlcache]
    }

    private static func bytes(at url: URL) async -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let result = await Subprocess.run(
            "/usr/bin/du", ["-sk", url.path], capture: .stdout, timeout: .seconds(240),
        )
        let kilobytes = result.output.split(separator: "\t").first.flatMap { Int64($0) } ?? 0
        return kilobytes * 1024
    }
}
