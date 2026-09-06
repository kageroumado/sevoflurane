import Foundation

/// The built-in engine's treatment of a game's windows — the driver's
/// `ResizableWindows` option (methylpentynol winemac.drv).
nonisolated enum WindowTreatment: String, Codable, CaseIterable, Sendable {
    /// Windows are left as the game makes them.
    case off
    /// A window the game locks to one size becomes resizable; the picture
    /// scales to fit.
    case fixed
    /// As `fixed`, and a game filling the screen gets a resizable window of
    /// its own, still believing it fills the screen.
    case window

    var label: String {
        switch self {
        case .off: "As the game makes them"
        case .fixed: "Resizable"
        case .window: "Fullscreen games in a window"
        }
    }
}

/// One level of the settings hierarchy: the keys a game's launch reads, each
/// optional so an absent one inherits from the level above. Game files also
/// carry the executables the game is known to run under, which is what a
/// per-program value is written against.
nonisolated struct ConfigValues: Codable, Equatable, Sendable {
    var windows: WindowTreatment?
    /// Game level only: the exe names Steam has launched for this app, lower
    /// case, as `GameLaunchWatch` saw them own the first window.
    var exes: [String]?
    /// Game level only: the display name, for listings.
    var name: String?

    static let empty = ConfigValues()

    /// Whether any setting is set at this level (the exe list alone is
    /// bookkeeping, not a setting).
    var hasSettings: Bool { windows != nil }
}

/// Where a resolved value came from.
nonisolated enum ConfigLevel: Equatable, Sendable, CustomStringConvertible {
    case global
    case bottle(String)
    case game(Int)

    var description: String {
        switch self {
        case .global: "global"
        case let .bottle(name): "bottle \(name)"
        case let .game(id): "game \(id)"
        }
    }
}

/// A setting's value together with the level that supplied it.
nonisolated struct Resolved<Value: Sendable>: Sendable {
    let value: Value
    let source: ConfigLevel
}

/// The settings hierarchy — global, bottle, game — and its resolver: the
/// game's own value wins, then the bottle's, then the global default
/// (`Docs/config-hierarchy-plan.md`).
///
/// JSON files under `~/Library/Application Support/Sevoflurane/Config/` are
/// the source of truth; the env files the engine reads at every process
/// start (`ConfigMaterializer`) are derived from them.
nonisolated enum GameConfig {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/Config")

    /// What every level inherits when nothing is set anywhere.
    static let defaults = ConfigValues(windows: .fixed)

    // MARK: - Levels

    static func global() -> ConfigValues {
        migrateIfNeeded()
        return read(globalURL)
    }

    static func setGlobal(_ values: ConfigValues) {
        write(values, to: globalURL)
    }

    static func bottle(_ name: String) -> ConfigValues {
        migrateIfNeeded()
        return read(bottleURL(name))
    }

    static func setBottle(_ name: String, _ values: ConfigValues) {
        write(values, to: bottleURL(name))
    }

    static func game(_ appID: Int) -> ConfigValues {
        read(gameURL(appID))
    }

    static func setGame(_ appID: Int, _ values: ConfigValues) {
        write(values, to: gameURL(appID))
    }

    /// Every game with a file, by app id.
    static func games() -> [Int: ConfigValues] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: gamesRoot, includingPropertiesForKeys: nil,
        ) else { return [:] }
        var result: [Int: ConfigValues] = [:]
        for url in entries where url.pathExtension == "json" {
            guard let id = Int(url.deletingPathExtension().lastPathComponent) else { continue }
            result[id] = read(url)
        }
        return result
    }

    // MARK: - Resolver

    /// The window treatment a launch in this bottle gets: for a specific game
    /// when its id is known, otherwise the bottle's own value.
    static func windows(bottle: String, game appID: Int? = nil) -> Resolved<WindowTreatment> {
        if let appID, let value = game(appID).windows {
            return Resolved(value: value, source: .game(appID))
        }
        if let value = Self.bottle(bottle).windows {
            return Resolved(value: value, source: .bottle(bottle))
        }
        return Resolved(value: global().windows ?? defaults.windows!, source: .global)
    }

    // MARK: - Executables

    /// Records that a launch of this app put up a window owned by `exe`; the
    /// per-program env file is written for every exe recorded here.
    static func noteExecutable(_ exe: String, forApp appID: Int, named name: String? = nil) {
        let lowered = exe.lowercased()
        var values = game(appID)
        var exes = values.exes ?? []
        let changed = !exes.contains(lowered) || (name != nil && values.name != name)
        guard changed else { return }
        if !exes.contains(lowered) { exes.append(lowered) }
        values.exes = exes
        if let name { values.name = name }
        setGame(appID, values)
    }

    // MARK: - Files

    private static var globalURL: URL { root.appendingPathComponent("global.json") }
    private static var bottlesRoot: URL { root.appendingPathComponent("bottles") }
    private static var gamesRoot: URL { root.appendingPathComponent("games") }

    private static func bottleURL(_ name: String) -> URL {
        bottlesRoot.appendingPathComponent("\(name).json")
    }

    private static func gameURL(_ appID: Int) -> URL {
        gamesRoot.appendingPathComponent("\(appID).json")
    }

    private static func read(_ url: URL) -> ConfigValues {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode(ConfigValues.self, from: data)
        else { return .empty }
        return values
    }

    /// A level with nothing in it has no file, so the directory listing is
    /// the list of levels that say something.
    private static func write(_ values: ConfigValues, to url: URL) {
        let manager = FileManager.default
        if values == .empty {
            try? manager.removeItem(at: url)
            return
        }
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(values) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Migration

    /// The two window switches that lived in the shared defaults become the
    /// global level's `windows`, once; the keys are then removed so this
    /// cannot run twice.
    private static func migrateIfNeeded() {
        let defaults = Preferences.shared
        let resizableKey = "resizableGameWindows"
        let fullscreenKey = "fullscreenGamesInWindows"
        let resizable = defaults.object(forKey: resizableKey) as? Bool
        let fullscreen = defaults.object(forKey: fullscreenKey) as? Bool
        guard resizable != nil || fullscreen != nil else { return }
        var values = read(globalURL)
        if values.windows == nil {
            values.windows = fullscreen == true ? .window : (resizable == false ? .off : .fixed)
            write(values, to: globalURL)
        }
        defaults.removeObject(forKey: resizableKey)
        defaults.removeObject(forKey: fullscreenKey)
    }
}
