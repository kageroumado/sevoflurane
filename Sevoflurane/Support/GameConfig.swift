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
        case .off: "The window system scales the picture."
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
        case .nearest: "Copies pixels. Crisp at whole-number scales, uneven at the rest."
        case .bilinear: "Blends neighboring pixels. The softest of the three."
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
    /// Game level only: the translation layer this game renders through, over
    /// the bottle's own choice. An engine that reads the env files hands it to
    /// the game at its next launch, through a `WINEDLLPATH_PREPEND` directory
    /// of that renderer's payload; an engine without them takes a client
    /// restart, which is what ``BottleGraphics/rendererNeedingRestart(forApp:)``
    /// answers.
    var renderer: Renderer?
    /// Whether the prefix draws at the display's full resolution, which
    /// doubles what a game is told the screen measures
    /// (`Mac Driver\RetinaMode`).
    ///
    /// Bottle-wide: `winemac.drv` reads it with no app key so that the DPI and
    /// the monitor sizes are one answer for every process in the prefix.
    var retina: Bool?
    /// Whether a game that switches the display mode gets the switch faked and
    /// its picture in a window the user can resize
    /// (win32u `X11 Driver\EmulateModeset`).
    var emulateModeset: Bool?
    /// Per DLL, the load order Wine gives it, in the registry's own spelling:
    /// `n,b`, `b,n`, `n`, `b`, or the empty string for disabled
    /// (`DllOverrides`, per program under `AppDefaults\<exe>`).
    var dllOverrides: [String: String]?
    /// Whether Metal draws its performance HUD over the game
    /// (`MTL_HUD_ENABLED`) — frame time, GPU time and memory, from the driver
    /// itself rather than from anything the game exposes.
    var hud: Bool?
    /// Whether a 32-bit game gets the whole 4 GB of address space rather than
    /// the low 2 GB.
    ///
    /// The engine reads the image's own `IMAGE_FILE_LARGE_ADDRESS_AWARE` bit
    /// and nothing else: in dormison's `virtual_set_large_address_space`
    /// (`ntdll/unix/virtual.c`) an image without the bit keeps
    /// `user_space_wow_limit = limit_2g - 1`. Honoring this key is a `getenv`
    /// there that takes `SEVO_LARGE_ADDRESS_AWARE` as the bit — Proton's
    /// `PROTON_FORCE_LARGE_ADDRESS_AWARE`. Until that patch lands the
    /// variable is written and read by nobody, and Settings says so.
    var largeAddressAware: Bool?
    /// Whether Rosetta tells the game the CPU has AVX and AVX2
    /// (`ROSETTA_ADVERTISE_AVX`). Rosetta translates those instructions
    /// either way; the advertisement is what a game's CPU check reads.
    var avx: Bool?
    /// Whether the window server holds the pointer inside the game's window
    /// while the game has the cursor clipped (`SEVO_CURSOR_CONFINE`), which is
    /// what keeps mouse-look from walking onto a second display.
    var cursorConfine: Bool?
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
    /// Game level only: the Windows program the user handed to Sevoflurane,
    /// which is what makes this entry an adopted program rather than a Steam
    /// app (``AdoptedPrograms``).
    var program: AdoptedProgram?

    static let empty = ConfigValues()

    /// Whether any setting is set at this level (the exe list and the
    /// detection record are bookkeeping, not settings).
    var hasSettings: Bool {
        windows != nil || mouse != nil || upscaler != nil || filter != nil || runner != nil
            || renderer != nil || retina != nil || emulateModeset != nil
            || dllOverrides?.isEmpty == false
            || hud != nil || largeAddressAware != nil || avx != nil || cursorConfine != nil
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

/// What a changed setting costs to reach the game — the badge Settings shows
/// beside every control, and the sentence `sevo` prints after a write.
nonisolated enum SettingReach: Equatable, Sendable {
    /// The game reads it when it next starts; Steam keeps running.
    case nextLaunch
    /// The client itself carries the value, so it restarts around the next
    /// launch.
    case clientRestart
    /// Written down and waiting on an engine that reads it.
    case recorded

    var label: String {
        switch self {
        case .nextLaunch: "Next launch"
        case .clientRestart: "Steam restart"
        case .recorded: "Recorded"
        }
    }

    /// The sentence behind the badge, and what a command line prints.
    var detail: String {
        switch self {
        case .nextLaunch:
            "reaches the game the next time it starts; Steam keeps running"
        case .clientRestart:
            "the Steam client carries this value, so it restarts (about 30 s) "
                + "around the next launch"
        case .recorded:
            "stored for this game; the built-in engine does not read it yet"
        }
    }

    /// What a setting carried by a game's env file costs: the next launch on an
    /// engine that reads those files, a client restart on one that does not.
    static var env: SettingReach {
        Engine.active.supportsEnvFiles ? .nextLaunch : .clientRestart
    }

    /// The registry is live in wineserver and read at every process start, so
    /// a value written now is what the next game process sees.
    static let registry = SettingReach.nextLaunch

    /// What a renderer costs this game: a layer a `WINEDLLPATH_PREPEND`
    /// directory can carry rides in the game's own env file; every other one
    /// is the client's to hand down.
    static func renderer(_ own: Renderer?) -> SettingReach {
        guard let own else { return env }
        return Engine.active.supportsEnvFiles && EngineRenderers.supportsPerGame(own)
            ? .nextLaunch : .clientRestart
    }
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
        retina: false, emulateModeset: false,
        // AVX on: the bottle has advertised it since the translation defaults
        // were written, and a growing number of titles read the CPUID answer
        // and refuse to start without it. A game that misbehaves with the
        // advertisement turns it off for itself.
        hud: false, largeAddressAware: true, avx: true, cursorConfine: false,
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
        migrateIfNeeded()
        return read(gameURL(appID))
    }

    static func setGame(_ appID: Int, _ values: ConfigValues) {
        write(values, to: gameURL(appID))
    }

    /// Every game with a file, by app id.
    static func games() -> [Int: ConfigValues] {
        migrateIfNeeded()
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

    /// Whether the prefix draws at the display's full resolution. One answer
    /// for the whole prefix, so there is no game to ask for.
    static func retina(bottle: String) -> Resolved<Bool> {
        resolve(\.retina, bottle: bottle, game: nil)
    }

    /// Whether a game that switches the display mode gets the switch faked:
    /// for a specific game when its id is known, otherwise the bottle's own
    /// value.
    static func emulateModeset(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.emulateModeset, bottle: bottle, game: appID)
    }

    /// The env-carried switches, each resolved for a specific game when its id
    /// is known and for the bottle otherwise.
    static func hud(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.hud, bottle: bottle, game: appID)
    }

    static func largeAddressAware(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.largeAddressAware, bottle: bottle, game: appID)
    }

    static func avx(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.avx, bottle: bottle, game: appID)
    }

    static func cursorConfine(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.cursorConfine, bottle: bottle, game: appID)
    }

    /// The renderer a launch gets: the game's own choice when it has one,
    /// otherwise the bottle's.
    ///
    /// The bottle's renderer lives in the graphics store rather than in this
    /// hierarchy — it is negotiated with the staged Wine tree and with msync,
    /// which have not moved here yet — so this resolver reaches across to it
    /// instead of falling through to ``defaults``.
    static func renderer(game appID: Int? = nil) -> Resolved<Renderer> {
        if let appID, let pinned = game(appID).renderer {
            return Resolved(value: pinned, source: .game(appID))
        }
        return Resolved(
            value: BottleGraphics.currentSelection().renderer,
            source: .bottle(SteamBottle.name),
        )
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

    /// Every settings key that used to live in the shared defaults, moved into
    /// the hierarchy. Each pass clears the keys it read, so none runs twice.
    private static func migrateIfNeeded() {
        migrateWindowSwitches()
        migrateRendererPins()
    }

    /// The two window switches that lived in the shared defaults become the
    /// global level's `windows`, once; the keys are then removed so this
    /// cannot run twice.
    private static func migrateWindowSwitches() {
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

    /// The per-app renderer pins that lived in the shared defaults become each
    /// game's own `renderer`, once. The key goes first: a pin nobody can
    /// decode is still a pin this hierarchy now owns, and leaving the key
    /// would make every read of every game file try it again.
    private static func migrateRendererPins() {
        let defaults = Preferences.shared
        let pinsKey = "rendererOverrides"
        guard let data = defaults.data(forKey: pinsKey) else { return }
        defaults.removeObject(forKey: pinsKey)
        guard let pins = try? JSONDecoder().decode([String: RendererPin].self, from: data)
        else { return }
        for (key, pin) in pins {
            guard let appID = Int(key) else { continue }
            var values = read(gameURL(appID))
            guard values.renderer == nil else { continue }
            values.renderer = pin.renderer
            if values.name == nil { values.name = pin.name }
            write(values, to: gameURL(appID))
        }
    }

    /// One entry of the shared defaults' old per-app renderer map.
    private struct RendererPin: Decodable {
        let renderer: Renderer
        let name: String
    }
}
