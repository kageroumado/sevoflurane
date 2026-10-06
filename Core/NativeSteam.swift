import Foundation

/// Valve's own Steam for Mac and the games it has installed.
///
/// A game's macOS build runs against a running macOS Steam client: its
/// `steam_api` talks to that client, and the Windows client in the bottle
/// cannot serve it. So a game set to its Mac build is handed to Steam for Mac
/// (``MacBuildRoute``), and what that client has installed is read from its
/// own files, the same text KeyValues the bottle's client writes: the
/// libraries in `steamapps/libraryfolders.vdf`, as POSIX paths, and one
/// `appmanifest_<id>.acf` per game in each library.
nonisolated enum NativeSteam {
    /// Steam for Mac's bundle identifier, by which its app is found wherever
    /// it is installed.
    static let bundleIdentifier = "com.valvesoftware.steam"

    /// Steam for Mac's data folder, which holds its first library.
    static var root: URL {
        UserHome.url.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    /// Steam for Mac's connection log, the same format as the bottle client's
    /// (``SteamConnectionLog``).
    static var connectionLog: URL {
        root.appendingPathComponent("logs/connection_log.txt")
    }

    /// One game Steam for Mac has a manifest for.
    struct Game: Equatable, Sendable {
        let appID: Int
        let name: String
        /// Steam's `StateFlags`: bit 4 (`FullyInstalled`) is set once every
        /// file is on disk, and stays set through an update.
        let stateFlags: Int

        var isFullyInstalled: Bool { stateFlags & 4 != 0 }
    }

    /// The game a manifest describes, or `nil` for text that names no app.
    static func game(inManifest text: String) -> Game? {
        guard let appID = SharedGames.manifestValue("appid", in: text).flatMap(Int.init) else { return nil }
        return Game(
            appID: appID,
            name: SharedGames.manifestValue("name", in: text) ?? "",
            stateFlags: SharedGames.manifestValue("StateFlags", in: text).flatMap(Int.init) ?? 0,
        )
    }

    /// Every library's `steamapps` that exists on disk, the data folder's own
    /// first.
    static func steamapps(root: URL = root) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("steamapps").path) else { return [] }
        return SteamLibraries.steamapps(steamRoot: root) { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
    }

    /// Whether Steam for Mac has every file of the game on disk.
    static func isInstalled(appID: Int, root: URL = root) -> Bool {
        steamapps(root: root).contains { steamapps in
            let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return false }
            return game(inManifest: text)?.isFullyInstalled == true
        }
    }
}

/// Which build of a game Play starts: the Windows build the bottle runs, or
/// the game's own macOS build through Steam for Mac.
nonisolated enum GameBuild: String, Codable, CaseIterable, Sendable {
    case windows
    case mac

    var label: String {
        let value = switch self {
        case .windows: "Windows (Sevoflurane)"
        case .mac: "macOS (Steam for Mac)"
        }
        return InterfaceCopy.localized(value)
    }
}

/// Where one Play goes, decided from the game's build choice and what is on
/// this Mac.
nonisolated enum MacBuildRoute: Equatable, Sendable {
    /// The bottle's client starts the Windows build.
    case windows
    /// Steam for Mac starts the installed macOS build.
    case play(Int)
    /// Steam for Mac opens its install dialog for the game.
    case install(Int)
    /// The macOS build is chosen and Steam for Mac is not on this Mac.
    case steamForMacMissing(Int)

    static func decide(appID: Int, build: GameBuild?, hasSteamForMac: Bool, installedThere: Bool) -> MacBuildRoute {
        guard build == .mac else { return .windows }
        guard hasSteamForMac else { return .steamForMacMissing(appID) }
        return installedThere ? .play(appID) : .install(appID)
    }

    /// The link Steam for Mac is handed, opened by its app explicitly:
    /// Sevoflurane claims `steam://` too, and a plain open would come back
    /// here.
    var link: URL? {
        switch self {
        case let .play(id): URL(string: "steam://rungameid/\(id)")
        case let .install(id): URL(string: "steam://install/\(id)")
        case .windows, .steamForMacMissing: nil
        }
    }
}
