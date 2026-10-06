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
                detail: "The games in Steam\u{2019}s library inside the bottle.",
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
            Entry(
                id: "companions",
                name: "Companion Windows",
                detail: "A second Windows drive beside the bottle, without Steam, for HoYoverse\u{2019}s games.",
                // `SteamParent.root`, which the CLI does not compile.
                url: AppIdentity.supportFolder
                    .appendingPathComponent("Companions"),
                bytes: -1,
                removal: .regenerated("Made again the next time one of those games starts; it asks you to sign in again."),
            ),
        ]
    }

    /// What Sevoflurane keeps for itself: engines, graphics layers, and logs.
    private static func supportEntries() -> [Entry] {
        let support = AppIdentity.supportFolder
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
                name: "Upscalers",
                detail: "Extra upscalers downloaded for Dormison.",
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
                url: AppIdentity.logFile(),
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
            : UserHome.url
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

    /// What is installed in the library inside the bottle, largest first —
    /// the games the Games row measures. Libraries elsewhere are listed on
    /// their own (``libraries()``).
    ///
    /// Read from Steam's own `appmanifest_*.acf` files rather than measured:
    /// the client already knows every game's size on disk, and asking the
    /// filesystem the same question would walk a quarter of a million files
    /// to reach the same number.
    static func installedGames() -> [Game] {
        SharedGames.installedGames(in: SharedGames.activeSteamapps)
            .map { Game(id: $0.appID, name: $0.name, bytes: $0.bytes) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// One of Steam's game libraries, and the drive it is on.
    struct Library: Identifiable, Sendable, Equatable {
        /// The library's folder, which is its identity.
        let id: URL
        /// The inside-the-bottle library Steam installs into by default.
        let isInsideBottle: Bool
        let fileSystem: SteamLibraries.FileSystem
        /// Free space on the library's drive, when the drive says.
        let available: Int64?
        let games: Int
        /// Steam's own count of the games' size.
        let bytes: Int64

        /// The folder as a person writes it: `~/…` or `/Volumes/…`.
        var location: String {
            (id.path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// Every library Steam knows in the active bottle whose drive is here,
    /// the one inside the bottle first.
    static func libraries() -> [Library] {
        let games = SharedGames.installedGames()
        // By path: a URL made for a folder that exists carries a trailing
        // slash, and one made for the same folder by name does not.
        let inBottle = SharedGames.activeSteamapps.standardizedFileURL.path
        return SteamLibraries.steamapps().map { steamapps in
            let path = steamapps.standardizedFileURL.path
            let inLibrary = games.filter { $0.steamapps.standardizedFileURL.path == path }
            let available = (try? steamapps.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey],
            ))?.volumeAvailableCapacityForImportantUsage
            return Library(
                id: steamapps.deletingLastPathComponent(),
                isInsideBottle: path == inBottle,
                fileSystem: SteamLibraries.fileSystem(at: steamapps),
                available: available,
                games: inLibrary.count,
                bytes: inLibrary.map(\.bytes).reduce(0, +),
            )
        }
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
            // `du` skips the games itself rather than walking them twice,
            // once in the client and once to subtract them.
            return await bytes(at: entry.url, skipping: "steamapps")
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

    /// Entries a running bottle has open.
    static let usedWhileRunning: Set<String> = [
        Entry.gamesID, Entry.programsID, "client", "caches", "bottle", "engines", "renderers", "toolkits",
    ]

    /// Whether reclaiming `entry` is refused: an entry the running bottle
    /// reads from waits until the bottle stops, since the client writes its
    /// caches as it runs and a running game has its engine, renderer and
    /// toolkit files mapped. `bottleRunning` is ``isBottleRunning``.
    static func isRefused(_ entry: Entry, bottleRunning: Bool) -> Bool {
        bottleRunning && usedWhileRunning.contains(entry.id)
    }

    /// Whether the bottle's wineserver holds its lock, which is true from the
    /// first Wine process to the last.
    static var isBottleRunning: Bool {
        WineOrphans.isServerAlive(forPrefix: SteamBottle.root.path)
    }

    /// A reclaim refused because the bottle is using what it would remove.
    struct InUse: Error, CustomStringConvertible {
        let entry: String
        var description: String {
            "\(entry) is in use while Steam or a game runs; stop the client first"
        }
    }

    private static var cacheDirectories: [URL] {
        ["appcache", "depotcache", "dumps"].map(SteamBottle.steamRoot.appendingPathComponent)
            + [SteamBottle.htmlcache]
    }

    /// What `url` occupies, leaving out every directory or file named
    /// `skipping` inside it.
    private static func bytes(at url: URL, skipping name: String? = nil) async -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let result = await Subprocess.run(
            "/usr/bin/du", ["-sk"] + (name.map { ["-I", $0] } ?? []) + [url.path],
            capture: .stdout, timeout: .seconds(240),
        )
        let kilobytes = result.output.split(separator: "\t").first.flatMap { Int64($0) } ?? 0
        return kilobytes * 1024
    }
}
