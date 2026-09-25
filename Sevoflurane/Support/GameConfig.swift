import Foundation

/// The built-in engine's treatment of a game's windows — the driver's
/// `ResizableWindows` option (dormison winemac.drv), which reads the first
/// character of the value, so the raw values must stay distinct in it.
///
/// The labels say which windows each case reaches: a collapsed picker shows
/// only the selected label, so a label that names what it does without
/// naming what it leaves out cannot be read against its neighbors. The raw
/// values are stored in every config file and stay as they are; `fixed`
/// names the windows it reaches, which a reader of `windows=fixed` alone
/// takes for "cannot move or resize", so the command-line help spells each
/// one out (``help``).
nonisolated enum WindowTreatment: String, Codable, CaseIterable, Sendable {
    /// Windows are left as the game makes them.
    case off
    /// A titled window the game locks to one size becomes resizable; the
    /// picture scales to fit. A borderless window covering the screen stays
    /// as it is.
    case fixed
    /// As `fixed`, and a borderless window covering a screen becomes an
    /// ordinary titled window the player can move and resize, while the game
    /// still believes it fills the screen.
    case window
    /// Every titled window becomes resizable, the ones the game already lets
    /// the user resize included — which those games would otherwise redraw at
    /// the new size rather than scale. A borderless window covering the
    /// screen stays as it is.
    case all

    /// The picker's line for this case.
    var label: String {
        switch self {
        case .off: "Never"
        case .fixed: "Fixed-size windows"
        case .window: "Fixed-size windows and full-screen games"
        case .all: "Every window with a title bar"
        }
    }

    /// What the player gets, for a command line that has no picker to read
    /// the neighboring cases from.
    var summary: String {
        switch self {
        case .off: "every window stays as the game makes it; a full-screen game covers the screen"
        case .fixed: "a window the game locks to one size gets a resize handle and its picture scales; "
            + "a full-screen game stays full screen"
        case .window: "as fixed, and a full-screen game plays in a window you can move and resize, "
            + "still drawing as if it filled the screen"
        case .all: "every window with a title bar can be resized and its picture scales, windows the game "
            + "resizes itself included; a full-screen game stays full screen"
        }
    }

    /// Every case and what the player gets, one line each, plus the
    /// level-clearing value the config commands accept.
    static var help: String {
        let width = (allCases.map(\.rawValue) + ["inherit"]).map(\.count).max() ?? 0
        let line = { (name: String, text: String) in
            "  " + name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + text
        }
        return (allCases.map { line($0.rawValue, $0.summary) } + [line("inherit", "take the level above's value")])
            .joined(separator: "\n")
    }

    /// The case names alone, for the places a line of help has room for the
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
        case .lanczos: "Final filter only"
        case .metalfx: "MetalFX Spatial"
        }
    }

    /// One line on what the choice is for.
    var detail: String {
        switch self {
        case .off: "The window system scales the picture."
        case .lanczos: "No shader. The final filter does all the resizing."
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

/// How the engine's threads wait for each other while a game runs — one
/// choice that stands for a set of engine switches, so the set can change
/// with the engine while a game's stored choice keeps its meaning.
nonisolated enum PerformanceTuning: String, Codable, CaseIterable, Sendable {
    /// A waiting thread goes to sleep at once, as Wine does it.
    case standard
    /// A waiting thread looks for its wake-up for two microseconds before it
    /// sleeps, and stops looking where that keeps failing. Hand-offs between
    /// threads get up to ten times quicker (`bispectral/syncprof`); a game
    /// that runs more busy threads than the Mac has cores pays for it in
    /// processor time.
    case experimental
    /// The three parameters as the level's ``TuningParameters`` set them.
    case custom

    var label: String {
        switch self {
        case .standard: "Standard"
        case .experimental: "Experimental"
        case .custom: "Custom"
        }
    }

    /// The parameters a preset stands for; `custom` stands for the ones
    /// handed in, and for the experimental ones where none are stored.
    func parameters(custom: TuningParameters?) -> TuningParameters {
        switch self {
        case .standard: .standard
        case .experimental: .experimental
        case .custom: custom ?? .experimental
        }
    }
}

/// How long a waiting thread looks for its wake-up before it sleeps — the
/// engine switches ``PerformanceTuning`` sets, open to a hand.
nonisolated struct TuningParameters: Codable, Equatable, Sendable {
    /// Iterations a thread spins on a wait before it parks (`SEVO_WAIT_SPIN`).
    /// One iteration is about 0.4 ns, so 5200 is two microseconds.
    var waitSpin: Int
    /// Whether a wait that keeps failing to catch its wake-up stops spinning
    /// (`SEVO_WAIT_SPIN_ADAPT`).
    var adaptive: Bool
    /// Iterations a thread spins on a contended object — a mutex, an event, a
    /// semaphore — before it parks (`SEVO_OBJECT_SPIN`).
    var objectSpin: Int

    static let standard = TuningParameters(waitSpin: 0, adaptive: false, objectSpin: 0)
    static let experimental = TuningParameters(waitSpin: 5200, adaptive: true, objectSpin: 5200)

    /// What the engine accepts: a spin past this is a thread that never sleeps.
    static let spinRange = 0 ... 1_000_000

    var argument: String { "\(waitSpin),\(adaptive ? 1 : 0),\(objectSpin)" }

    private static func clamped(_ spin: Int) -> Int {
        min(max(spin, spinRange.lowerBound), spinRange.upperBound)
    }

    /// Every key, always: a game's file is read over the bottle's, and an
    /// absent key would leave the bottle's value standing.
    var environment: [(key: String, value: String)] {
        [
            ("SEVO_WAIT_SPIN", "\(Self.clamped(waitSpin))"),
            ("SEVO_WAIT_SPIN_ADAPT", adaptive ? "1" : "0"),
            ("SEVO_OBJECT_SPIN", "\(Self.clamped(objectSpin))"),
        ]
    }
}

nonisolated extension TuningParameters {
    /// The command line's spelling, `<wait>,<adaptive 0|1>,<object>`.
    init?(argument: String) {
        let parts = argument.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let wait = Int(parts[0]), let object = Int(parts[2]),
              ["0", "1"].contains(parts[1]),
              Self.spinRange.contains(wait), Self.spinRange.contains(object) else { return nil }
        self.init(waitSpin: wait, adaptive: parts[1] == "1", objectSpin: object)
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
        case .linear: "Linear (no acceleration)"
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
    /// Experimental: how the engine's threads wait for each other
    /// (``PerformanceTuning``).
    var tuning: PerformanceTuning?
    /// The parameters the `custom` tuning stands for at this level.
    var tuningParameters: TuningParameters?
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
    /// Whether the engine draws its frame-rate counter at the top right of the
    /// game's window (`SEVO_FPS`): one number, from the engine's own count of
    /// presented frames, whichever renderer draws them.
    var fps: Bool?
    /// Whether the counter grows into a card with a frame-time graph of the last
    /// seconds and the 1 % low (`SEVO_FPS_GRAPH`). On, it shows the counter too.
    var fpsGraph: Bool?
    /// Whether a 32-bit game gets the whole 4 GB of address space rather than
    /// the low 2 GB.
    ///
    /// An image carrying `IMAGE_FILE_LARGE_ADDRESS_AWARE` gets it either way;
    /// `SEVO_LARGE_ADDRESS_AWARE=1` gives it to one without the flag, in
    /// dormison's `virtual_set_large_address_space` (`ntdll/unix/virtual.c`),
    /// as Proton's `PROTON_FORCE_LARGE_ADDRESS_AWARE` does.
    var largeAddressAware: Bool?
    /// Whether Rosetta tells the game the CPU has AVX and AVX2
    /// (`ROSETTA_ADVERTISE_AVX`). Rosetta translates those instructions
    /// either way; the advertisement is what a game's CPU check reads.
    var avx: Bool?
    /// Experimental: whether the game is told the Mac's memory is one pool
    /// shared by the CPU and the GPU, which it is (`SEVO_FORCE_UMA`).
    ///
    /// D3DMetal answers `ARCHITECTURE1.UMA` with 0, so every engine writes
    /// each upload into a staging buffer and then copies it into a second
    /// allocation that is the same physical memory. Skipping that copy is
    /// worth 27-107% of a bandwidth-bound frame, measured in
    /// `bispectral/gamebench --uma`; dormison's `winemac.drv` reports the
    /// unified answer when this is on. Off by default because a game that
    /// believes it takes every unified path, and the texture layouts among
    /// them are the least tested.
    var unifiedMemory: Bool?
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
            || hud != nil || fps != nil || fpsGraph != nil || largeAddressAware != nil || avx != nil || cursorConfine != nil
            || unifiedMemory != nil || tuning != nil
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

    var label: String {
        switch self {
        case .nextLaunch: "Next launch"
        case .clientRestart: "Steam restart"
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
    static let root = UserHome.url
        .appendingPathComponent("Library/Application Support/Sevoflurane/Config")

    /// What every level inherits when nothing is set anywhere.
    static let defaults = ConfigValues(
        windows: .fixed, mouse: .system, tuning: .standard,
        // Lanczos as the final filter costs 0.3 ms a frame in a window and 1.4 ms at a full 5K
        // output on an M1 Max; with the presenter off, Core Animation stretches the picture
        // bilinearly.
        upscaler: UpscalerChoice.lanczos.rawValue, filter: .lanczos,
        retina: false, emulateModeset: false,
        // AVX on: the bottle has advertised it since the translation defaults
        // were written, and a growing number of titles read the CPUID answer
        // and refuse to start without it. A game that misbehaves with the
        // advertisement turns it off for itself.
        hud: false, fps: false, fpsGraph: false, largeAddressAware: true, avx: true, unifiedMemory: false,
        cursorConfine: false,
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

    /// The performance tuning a launch in this bottle gets: for a specific
    /// game when its id is known, otherwise the bottle's own value.
    static func tuning(bottle: String, game appID: Int? = nil) -> Resolved<PerformanceTuning> {
        resolve(\.tuning, bottle: bottle, game: appID)
    }

    /// The thread-wait parameters a launch gets: the resolved preset's, and
    /// for `custom` the nearest level's own.
    static func tuningParameters(bottle: String, game appID: Int? = nil) -> TuningParameters {
        let custom = appID.flatMap { game($0).tuningParameters }
            ?? Self.bottle(bottle).tuningParameters ?? global().tuningParameters
        return tuning(bottle: bottle, game: appID).value.parameters(custom: custom)
    }

    /// The upscaler a launch in this bottle gets — an ``UpscalerChoice`` raw
    /// value or a package name: for a specific game when its id is known,
    /// otherwise the bottle's own value.
    static func upscaler(bottle: String, game appID: Int? = nil) -> Resolved<String> {
        resolve(\.upscaler, bottle: bottle, game: appID)
    }

    /// Whether a launch in this bottle is told the memory is unified: for a
    /// specific game when its id is known, otherwise the bottle's own value.
    static func unifiedMemory(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.unifiedMemory, bottle: bottle, game: appID)
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

    static func fps(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.fps, bottle: bottle, game: appID)
    }

    static func fpsGraph(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.fpsGraph, bottle: bottle, game: appID)
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
    static func resolve<Value: Sendable>(
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
    ///
    /// - Parameter inBackground: whether the env files are written on a
    ///   detached task, for a caller on the main actor. Otherwise they are on
    ///   disk when this returns.
    static func update(
        bottle name: String, prefix: URL, inBackground: Bool = false,
        _ change: (inout ConfigValues) -> Void,
    ) {
        let before = bottle(name)
        var values = before
        change(&values)
        setBottle(name, values)
        noteChanges(from: before, to: values, of: "bottle \(name)")
        rewriteFiles(bottle: name, prefix: prefix, inBackground: inBackground)
    }

    /// Changes a game's own values and rewrites the engine's env files from
    /// the result — the one write path Settings › Games and `sevo app
    /// config` share. `inBackground` is as for ``update(bottle:prefix:inBackground:_:)``.
    static func update(
        game appID: Int, bottle name: String, prefix: URL, inBackground: Bool = false,
        _ change: (inout ConfigValues) -> Void,
    ) {
        let before = game(appID)
        var values = before
        change(&values)
        setGame(appID, values)
        noteChanges(from: before, to: values, of: "game \(appID)")
        rewriteFiles(bottle: name, prefix: prefix, inBackground: inBackground)
    }

    private static func rewriteFiles(bottle name: String, prefix: URL, inBackground: Bool) {
        if inBackground {
            ConfigMaterializer.materializeInBackground(bottle: name, prefix: prefix)
        } else {
            ConfigMaterializer.materialize(bottle: name, prefix: prefix)
        }
    }

    // MARK: - The trail of changes

    /// Where a changed setting is written down. The app points this at its
    /// event log; `sevo`, which has none, appends the same line to the file.
    nonisolated(unsafe) static var logChange: @Sendable (String) -> Void = appendToLogFile

    /// One line per setting that changed: what it was, what it is, and which
    /// process wrote it and on whose behalf. A setting can be written from
    /// Settings, from `sevo`, and from a running game's View menu (which runs
    /// `sevo`), and a value nobody remembers choosing is only explained here.
    private static func noteChanges(from before: ConfigValues, to after: ConfigValues, of level: String) {
        let writer = "\(ProcessInfo.processInfo.processName), started by \(parentProcessName())"
        for change in changes(from: before, to: after) {
            logChange("settings: \(level) \(change) (\(writer))")
        }
    }

    /// Each setting that differs between two levels, as `key was → is`, with
    /// `inherit` for a level that does not set it.
    static func changes(from before: ConfigValues, to after: ConfigValues) -> [String] {
        guard before != after else { return [] }
        let old = fields(of: before), new = fields(of: after)
        return Set(old.keys).union(new.keys).sorted().compactMap { key in
            let was = old[key] ?? "inherit", now = new[key] ?? "inherit"
            return bookkeepingKeys.contains(key) || was == now ? nil : "\(key) \(was) → \(now)"
        }
    }

    /// What a level records about a game rather than sets for it.
    private static let bookkeepingKeys: Set<String> = ["exes", "name", "detected", "program"]

    private static func fields(of values: ConfigValues) -> [String: String] {
        guard let data = try? JSONEncoder().encode(values),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { value in
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "on" : "off"
            }
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            else { return "\(value)" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func parentProcessName() -> String {
        var name = [CChar](repeating: 0, count: 256)
        let length = proc_name(getppid(), &name, UInt32(name.count))
        return length > 0 ? String(cString: name) : "pid \(getppid())"
    }

    private static let changeStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func appendToLogFile(_ message: String) {
        // A test run changes settings in scratch folders by the hundred.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let url = UserHome.url.appending(path: "Library/Logs/Sevoflurane.log")
        let line = "\(changeStamp.string(from: .now)) [app] \(message)\n"
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    // MARK: - Executables

    /// Records that a launch of this app put up a window owned by `exe`; the
    /// per-program env file is written for every exe recorded here.
    static func noteExecutable(_ exe: String, forApp appID: Int, named name: String? = nil) {
        let lowered = exe.lowercased()
        guard GameExecutables.isRecordable(lowered) else { return }
        var values = game(appID)
        var exes = values.exes ?? []
        let changed = !exes.contains(lowered) || (name != nil && values.name != name)
        guard changed else { return }
        if !exes.contains(lowered) { exes.append(lowered) }
        values.exes = exes
        if let name { values.name = name }
        setGame(appID, values)
    }

    /// Whether `exe` is a program a game starts beside itself rather than the
    /// game: an embedded browser's processes, a crash reporter, a
    /// redistributable's installer. It takes the game's settings and never the
    /// game's Dock identity — Unreal's `EpicWebHelper.exe` alone is three to
    /// five processes, some of them living for under a second.
    static func isCompanionExecutable(_ exe: String) -> Bool {
        let name = exe.lowercased()
        return companionExecutables.contains(name)
            || name.hasSuffix("webhelper.exe") || name.hasSuffix("subprocess.exe")
            || name.hasPrefix("unitycrashhandler") || name.hasPrefix("vc_redist")
            || name.hasPrefix("vcredist") || name.hasPrefix("ndp4")
    }

    private static let companionExecutables: Set<String> = [
        "crashreportclient.exe", "crashpad_handler.exe", "dxsetup.exe", "dotnetfx35setup.exe",
    ]

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
