import Foundation

/// Valve's own Steam for Mac and the games it has installed.
///
/// A game's macOS build talks to a running macOS Steam client through its
/// `steam_api`, which the bottle's Windows client cannot serve, so a game set
/// to its Mac build is handed to Steam for Mac (``MacBuildRoute``). Its
/// installs are read from the same text KeyValues files the bottle's client
/// writes, with POSIX library paths.
nonisolated enum NativeSteam {
    static let bundleIdentifier = "com.valvesoftware.steam"

    /// Steam for Mac's data folder, which holds its first library.
    static var root: URL {
        UserHome.url.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    /// Same format as the bottle client's (``SteamConnectionLog``).
    static var connectionLog: URL {
        root.appendingPathComponent("logs/connection_log.txt")
    }

    struct Game: Equatable, Sendable {
        let appID: Int
        let name: String
        /// Bit 4 (`FullyInstalled`) is set once every file is on disk, and
        /// stays set through an update.
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

    /// Every existing library's `steamapps`, the data folder's own first.
    static func steamapps(root: URL = root) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("steamapps").path) else { return [] }
        return SteamLibraries.steamapps(steamRoot: root) { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
    }

    /// Whether Play can hand games to Steam for Mac: opt-in on an engine that
    /// plays macOS versions itself, always on any other engine.
    static var isOffered: Bool {
        isOffered(enginePlaysMacOS: Engine.running.supportsSteamPlayMacOS, optedIn: Preferences.offersSteamForMac)
    }

    static func isOffered(enginePlaysMacOS: Bool, optedIn: Bool) -> Bool {
        !enginePlaysMacOS || optedIn
    }

    /// Turns the option on for anyone already sending a game to Steam for Mac,
    /// so a later engine that plays macOS versions changes nothing for them.
    /// Runs at every launch.
    static func adoptEarlierChoices(games: [ConfigValues]) {
        guard !Engine.running.supportsSteamPlayMacOS else { return }
        if games.contains(where: { $0.build == .mac }) { Preferences.offersSteamForMac = true }
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

/// Where Play runs a game: Sevoflurane's own Steam, or Valve's Steam for Mac.
/// Which version Sevoflurane's Steam installs is Steam's per-game choice
/// (``SteamPlayMacOS``) where the engine plays macOS versions, else Windows.
nonisolated enum GameBuild: String, Codable, CaseIterable, Sendable {
    case windows
    case mac

    var label: String {
        let value = switch self {
        case .windows: "Sevoflurane"
        case .mac: "Steam for Mac"
        }
        return InterfaceCopy.localized(value)
    }
}

/// Where one Play goes, decided from the game's build choice and what is on
/// this Mac.
nonisolated enum MacBuildRoute: Equatable, Sendable {
    case windows
    /// Steam for Mac starts the installed macOS build.
    case play(Int)
    /// Steam for Mac opens its install dialog for the game.
    case install(Int)
    /// The macOS build is chosen and Steam for Mac is not installed.
    case steamForMacMissing(Int)

    static func decide(appID: Int, build: GameBuild?, hasSteamForMac: Bool, installedThere: Bool) -> MacBuildRoute {
        guard build == .mac else { return .windows }
        guard hasSteamForMac else { return .steamForMacMissing(appID) }
        return installedThere ? .play(appID) : .install(appID)
    }

    /// The link to open in Steam for Mac's app explicitly: Sevoflurane claims
    /// `steam://` too, so a plain open would come back here.
    var link: URL? {
        switch self {
        case let .play(id): URL(string: "steam://rungameid/\(id)")
        case let .install(id): URL(string: "steam://install/\(id)")
        case .windows, .steamForMacMissing: nil
        }
    }
}
