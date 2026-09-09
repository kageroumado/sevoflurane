import Foundation

/// The built-in engine's treatment of a game's windows — the driver's
/// `ResizableWindows` option (dormison winemac.drv), which reads the first
/// character of the value, so the raw values must stay distinct in it.
///
/// The cases are an ordered scope, widest last, and the labels say which
/// games each one reaches: a collapsed picker shows only the selected label,
/// so a label that names what it does without naming what it leaves out
/// cannot be read against its neighbors.
nonisolated enum WindowTreatment: String, Codable, CaseIterable, Sendable {
    /// Windows are left as the game makes them.
    case off
    /// A window the game locks to one size becomes resizable; the picture
    /// scales to fit.
    case fixed
    /// As `fixed`, and a game covering the screen gets a resizable window of
    /// its own, still believing it fills the screen.
    case window
    /// Every titled window becomes resizable, the ones the game already lets
    /// the user resize included — which those games would otherwise redraw at
    /// the new size rather than scale.
    case all

    /// The picker's line for this rung.
    var label: String {
        switch self {
        case .off: "Never"
        case .fixed: "Games that run in a window"
        case .window: "Games that run in a window or full screen"
        case .all: "Every game window"
        }
    }

    /// What the rung covers, for a command line that has no picker to read
    /// the neighboring rungs from.
    var summary: String {
        switch self {
        case .off: "leaves every game window the size the game makes it"
        case .fixed: "makes a window the game locked to one size resizable"
        case .window: "as fixed, and a game covering the screen gets a resizable window of its own"
        case .all: "makes every titled game window resizable, the ones the game already resizes included"
        }
    }

    /// Every rung and what it covers, plus the level-clearing value the
    /// config commands accept.
    static var help: String {
        allCases.map { "\($0.rawValue) — \($0.summary)" }
            .joined(separator: "; ")
            + "; inherit — take the level above's value"
    }

    /// The rung names alone, for the places a line of help has room for the
    /// values but not for what they mean.
    static var rungs: String {
        allCases.map(\.rawValue).joined(separator: " | ") + " | inherit"
    }
}

/// The upscaler's fixed choices — the driver's `Upscaler` option
/// (dormison winemac.drv). Any other token names a shader package
/// directory (``ShaderPackages``), which carries its own title and
/// description.
nonisolated enum UpscalerChoice: String, CaseIterable, Sendable {
    /// The driver's presenter stays off and the window system scales the
    /// picture.
    case off
    /// The presenter resamples the frame at the display's full resolution
    /// with the final filter.
    case lanczos
    /// MetalFX Spatial, then the final filter.
    case metalfx

    var label: String {
        switch self {
        case .off: "Off"
        case .lanczos: "Lanczos"
        case .metalfx: "MetalFX Spatial"
        }
    }

    /// One line on what the choice is for.
    var detail: String {
        switch self {
        case .off: "The picture is scaled by the window system."
        case .lanczos: "Sharp resampling at your display's full resolution."
        case .metalfx: "For 3D games rendered below your display's resolution."
        }
    }
}

/// How the upscaler's last pass is resampled into the window — the driver's
/// `FinalFilter` option (dormison winemac.drv).
nonisolated enum FinalFilter: String, Codable, CaseIterable, Sendable {
    case nearest
    case bilinear
    case lanczos

    var label: String {
        switch self {
        case .nearest: "Nearest"
        case .bilinear: "Bilinear"
        case .lanczos: "Lanczos"
        }
    }

    /// One line on what the filter does to the picture.
    var detail: String {
        switch self {
        case .nearest: "Pixels are copied: crisp at whole-number scales, uneven at any other."
        case .bilinear: "Neighboring pixels are blended, the softest of the three."
        case .lanczos: "Sharp resampling for fractional scales."
        }
    }
}

/// What a game holding the cursor for mouse-look is given as mouse movement —
/// the driver's `LinearMouse` option (dormison winemac.drv).
nonisolated enum MouseCurve: String, Codable, CaseIterable, Sendable {
    /// The pointer moves the way it does everywhere else on the Mac, the
    /// system's acceleration curve included.
    case system
    /// The mouse's own displacement reaches the game unshaped, so the same
    /// sweep of the hand turns the camera the same distance however fast it
    /// is made.
    case linear

    var label: String {
        switch self {
        case .system: "macOS acceleration"
        case .linear: "Linear"
        }
    }
}

/// One level of the settings hierarchy: the keys a game's launch reads, each
/// optional so an absent one inherits from the level above. Game files also
/// carry the executables the game is known to run under, which is what a
/// per-program value is written against.
nonisolated struct ConfigValues: Codable, Equatable, Sendable {
    var windows: WindowTreatment?
    /// What the game is given as mouse movement while it holds the cursor for
    /// mouse-look.
    var mouse: MouseCurve?
    /// The present-time upscaler: one of ``UpscalerChoice`` by raw value, or
    /// the name of a shader package. Stored as text so a file written by a
    /// later version, naming a package this one does not know, still reads;
    /// `"off"` is a value like any other and means off at this level.
    var upscaler: String?
    /// How the upscaler's last pass is resampled into the window.
    var filter: FinalFilter?
    /// Game level only: which runtime the game runs on — the bottle's engine
    /// (`wine`, the default) or macOS NW.js (`nwjs`, for the games
    /// ``NWJSGames`` detects). Stored as text so a file written by a later
    /// version, naming a runner this one does not know, still reads.
    var runner: String?
    /// Game level only: what ``NWJSGames`` found about the game's own NW.js
    /// build, recorded whether or not the native runner is switched on.
    var nwjs: NWJSInfo?
    /// Game level only: the NW.js release the native runner installed for
    /// this game, which is its own where this Mac can run that natively and a
    /// newer one where it cannot (``NWJSRuntime/release(forGameVersion:)``).
    var nwjsRuntime: String?
    /// Game level only: the exe names Steam has launched for this app, lower
    /// case, as `GameLaunchWatch` saw them own the first window.
    var exes: [String]?
    /// Game level only: the display name, for listings.
    var name: String?

    static let empty = ConfigValues()

    /// Whether any setting is set at this level (the exe list and the
    /// detection record are bookkeeping, not settings).
    var hasSettings: Bool {
        windows != nil || mouse != nil || upscaler != nil || filter != nil || runner != nil
    }

    /// Whether this game runs natively rather than through the bottle.
    var runsNatively: Bool { runner == GameRunner.nwjs }
}

/// The runtimes a game can run on. `wine` is the absence of a choice, so it
/// is never written to a file.
nonisolated enum GameRunner {
    static let wine = "wine"
    static let nwjs = "nwjs"
    static let all = [wine, nwjs]
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
/// game's own value wins, then the bottle's, then the global default.
///
/// JSON files under `~/Library/Application Support/Sevoflurane/Config/` are
/// the source of truth; the env files the engine reads at every process
/// start (`ConfigMaterializer`) are derived from them.
nonisolated enum GameConfig {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/Config")

    /// What every level inherits when nothing is set anywhere.
    static let defaults = ConfigValues(
        windows: .fixed, mouse: .system, upscaler: UpscalerChoice.off.rawValue, filter: .lanczos,
    )

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
        resolve(\.windows, bottle: bottle, game: appID)
    }

    /// The mouse curve a launch in this bottle gets: for a specific game when
    /// its id is known, otherwise the bottle's own value.
    static func mouse(bottle: String, game appID: Int? = nil) -> Resolved<MouseCurve> {
        resolve(\.mouse, bottle: bottle, game: appID)
    }

    /// The upscaler a launch in this bottle gets — an ``UpscalerChoice`` raw
    /// value or a package name: for a specific game when its id is known,
    /// otherwise the bottle's own value.
    static func upscaler(bottle: String, game appID: Int? = nil) -> Resolved<String> {
        resolve(\.upscaler, bottle: bottle, game: appID)
    }

    /// The final filter a launch in this bottle gets: for a specific game
    /// when its id is known, otherwise the bottle's own value.
    static func filter(bottle: String, game appID: Int? = nil) -> Resolved<FinalFilter> {
        resolve(\.filter, bottle: bottle, game: appID)
    }

    /// The game's own value wins, then the bottle's, then the global level's,
    /// then ``defaults``, which sets every key.
    private static func resolve<Value: Sendable>(
        _ key: KeyPath<ConfigValues, Value?>, bottle: String, game appID: Int?,
    ) -> Resolved<Value> {
        if let appID, let value = game(appID)[keyPath: key] {
            return Resolved(value: value, source: .game(appID))
        }
        if let value = Self.bottle(bottle)[keyPath: key] {
            return Resolved(value: value, source: .bottle(bottle))
        }
        return Resolved(value: global()[keyPath: key] ?? defaults[keyPath: key]!, source: .global)
    }

    // MARK: - Writing with effect

    /// Changes the bottle's own values and rewrites the engine's env files
    /// from the result — the one write path Settings › Engine and `sevo
    /// bottle config` share.
    static func update(bottle name: String, prefix: URL, _ change: (inout ConfigValues) -> Void) {
        var values = bottle(name)
        change(&values)
        setBottle(name, values)
        ConfigMaterializer.materialize(bottle: name, prefix: prefix)
    }

    /// Changes a game's own values and rewrites the engine's env files from
    /// the result — the one write path Settings › Games and `sevo app
    /// config` share.
    static func update(
        game appID: Int, bottle name: String, prefix: URL, _ change: (inout ConfigValues) -> Void,
    ) {
        var values = game(appID)
        change(&values)
        setGame(appID, values)
        ConfigMaterializer.materialize(bottle: name, prefix: prefix)
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
