import Foundation

/// What Sevoflurane and its bottle occupy on disk, and what may be reclaimed.
///
/// Sizes come from `du`, not from a directory walk: a Steam library is
/// hundreds of thousands of files, and the C implementation is the difference
/// between a pane that fills in and one that hangs.
nonisolated enum StorageInventory {
    struct Entry: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let detail: String
        let icon: String
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
        let support = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Sevoflurane")
        let bottle = SteamBottle.root
        let steam = SteamBottle.steamRoot
        return [
            Entry(
                id: "games",
                name: "Games",
                detail: "Every game Steam has installed on this Mac.",
                icon: "gamecontroller",
                url: steam.appendingPathComponent("steamapps"),
                bytes: -1,
                removal: nil,
            ),
            Entry(
                id: "client",
                name: "Steam client",
                detail: "The client itself, without its games.",
                icon: "shippingbox",
                url: steam,
                bytes: -1,
                removal: nil,
            ),
            Entry(
                id: "caches",
                name: "Client caches",
                detail: "Web cache, library art, and crash dumps.",
                icon: "trash.slash",
                url: steam.appendingPathComponent("appcache"),
                bytes: -1,
                removal: .regenerated("Steam rebuilds these as it runs."),
            ),
            Entry(
                id: "bottle",
                name: "Windows environment",
                detail: "The pretend Windows drive Steam runs inside.",
                icon: "externaldrive",
                url: bottle,
                bytes: -1,
                removal: nil,
            ),
            Entry(
                id: "engines",
                name: "Built-in engines",
                detail: "The Windows translator Sevoflurane downloaded.",
                icon: "gearshape.2",
                url: support.appendingPathComponent("Engines"),
                bytes: -1,
                removal: .permanent("Setup downloads one again if you need it."),
            ),
            Entry(
                id: "toolkits",
                name: "Apple's Game Porting Toolkit",
                detail: "The DirectX 12 translator versions you added.",
                icon: "cpu",
                url: support.appendingPathComponent("D3DMetal"),
                bytes: -1,
                removal: .permanent("You would download the toolkit again from Apple."),
            ),
            Entry(
                id: "shadow",
                name: "CrossOver links",
                detail: "Shortcuts that point CrossOver at the toolkit you added.",
                icon: "link",
                url: CrossOverShadow.root,
                bytes: -1,
                removal: .regenerated("Rebuilt the next time a game starts."),
            ),
            Entry(
                id: "logs",
                name: "Logs",
                detail: "The event log this app writes.",
                icon: "doc.text",
                // Named here rather than taken from `EventLog`, which lives in
                // the app: `sevo` reports storage too, and shares this file.
                url: FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Library/Logs/Sevoflurane.log"),
                bytes: -1,
                removal: .regenerated("A new one starts on the next launch."),
            ),
        ]
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

    /// The size of one entry, or 0 when it is not there. `steamapps` is
    /// subtracted from the client and the client from the bottle, so the
    /// numbers add up rather than nesting.
    @concurrent
    static func size(of entry: Entry) async -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: entry.url.path) else { return 0 }
        switch entry.id {
        case "client":
            return await max(0, bytes(at: entry.url) - bytes(
                at: entry.url.appendingPathComponent("steamapps"),
            ))
        case "bottle":
            return await max(0, bytes(at: entry.url) - bytes(at: SteamBottle.steamRoot))
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
