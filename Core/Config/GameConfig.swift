import Foundation

/// The built-in engine's treatment of a game's windows — the driver's
/// `ResizableWindows` option (dormison winemac.drv), which reads the first
/// character of the value, so the raw values must stay distinct in it.
///
/// Each label names the windows its case reaches, because a collapsed picker
/// shows only the selected one. The raw values are stored in config files and
/// must not change; `windows=fixed` alone reads as "cannot move or resize",
/// so ``help`` spells each case out.
nonisolated enum WindowTreatment: String, Codable, CaseIterable, Sendable {
    /// Windows are left as the game makes them.
    case off
    /// A titled window the game locks to one size becomes resizable and its
    /// picture scales; a borderless full-screen window stays as it is.
    case fixed
    /// As `fixed`, and a borderless full-screen window becomes a movable,
    /// resizable titled window while the game still believes it fills the
    /// screen.
    case window
    /// Every titled window becomes resizable and scales, the ones the game
    /// resizes itself included; a borderless full-screen window stays.
    case all

    /// The picker's line for this case.
    var label: String {
        let value = switch self {
        case .off: "Never"
        case .fixed: "Fixed-size windows"
        case .window: "Fixed-size windows and full-screen games"
        case .all: "Every window with a title bar"
        }
        return InterfaceCopy.localized(value)
    }

    /// What the player gets, for a command line.
    var summary: String {
        let value = switch self {
        case .off: "every window stays as the game makes it; a full-screen game covers the screen"
        case .fixed: "a window the game locks to one size gets a resize handle and its picture scales; "
            + "a full-screen game stays full screen"
        case .window: "as fixed, and a full-screen game plays in a window you can move and resize, "
            + "still drawing as if it filled the screen"
        case .all: "every window with a title bar can be resized and its picture scales, windows the game "
            + "resizes itself included; a full-screen game stays full screen"
        }
        return InterfaceCopy.localized(value)
    }

    /// Every case and its summary, one line each, plus `inherit`.
    static var help: String {
        let width = (allCases.map(\.rawValue) + ["inherit"]).map(\.count).max() ?? 0
        let line = { (name: String, text: String) in
            "  " + name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + text
        }
        return (allCases.map { line($0.rawValue, $0.summary) } + [line("inherit", "take the level above's value")])
            .joined(separator: "\n")
    }

    /// The case names alone, for a one-line help.
    static var rungs: String {
        allCases.map(\.rawValue).joined(separator: " | ") + " | inherit"
    }
}

/// The upscaler's fixed choices — the driver's `Upscaler` option
/// (dormison winemac.drv). Any other token names a shader package
/// directory (``ShaderPackages``), which carries its own title and
/// description.
nonisolated enum UpscalerChoice: String, CaseIterable, Sendable {
    /// The window system scales the picture.
    case off
    /// The final filter alone resamples the frame to the display's resolution.
    case lanczos
    /// MetalFX Spatial, then the final filter.
    case metalfx

    var label: String {
        let value = switch self {
        case .off: "Off"
        case .lanczos: "Final filter only"
        case .metalfx: "MetalFX Spatial"
        }
        return InterfaceCopy.localized(value)
    }

    /// One line on what the choice is for.
    var detail: String {
        let value = switch self {
        case .off: "The window system scales the picture."
        case .lanczos: "No shader. The final filter does all the resizing."
        case .metalfx: "For 3D games rendered below your display's resolution."
        }
        return InterfaceCopy.localized(value)
    }
}

/// How the upscaler's last pass is resampled into the window — the driver's
/// `FinalFilter` option (dormison winemac.drv).
nonisolated enum FinalFilter: String, Codable, CaseIterable, Sendable {
    case nearest
    case bilinear
    case lanczos

    var label: String {
        let value = switch self {
        case .nearest: "Nearest"
        case .bilinear: "Bilinear"
        case .lanczos: "Lanczos"
        }
        return InterfaceCopy.localized(value)
    }

    /// One line on what the filter does to the picture.
    var detail: String {
        let value = switch self {
        case .nearest: "Copies pixels. Crisp at whole scales, uneven between."
        case .bilinear: "Blends neighboring pixels. The softest of the three."
        case .lanczos: "Sharp resampling for fractional scales."
        }
        return InterfaceCopy.localized(value)
    }
}

/// How the engine's threads wait for each other while a game runs — one
/// choice that stands for a set of engine switches, so the set can change
/// with the engine while a game's stored choice keeps its meaning.
nonisolated enum PerformanceTuning: String, Codable, CaseIterable, Sendable {
    /// A waiting thread goes to sleep at once, as Wine does it.
    case standard
    /// A waiting thread spins two microseconds before it sleeps, and stops
    /// spinning where that keeps failing. Hand-offs get up to ten times
    /// quicker; a game with more busy threads than cores pays in CPU time.
    case experimental
    /// The three parameters as the level's ``TuningParameters`` set them.
    case custom

    var label: String {
        let value = switch self {
        case .standard: "Standard"
        case .experimental: "Experimental"
        case .custom: "Custom"
        }
        return InterfaceCopy.localized(value)
    }

    /// The parameters a preset stands for; `custom` falls back to the
    /// experimental ones.
    func parameters(custom: TuningParameters?) -> TuningParameters {
        switch self {
        case .standard: .standard
        case .experimental: .experimental
        case .custom: custom ?? .experimental
        }
    }
}

/// The engine's spin-before-sleep switches that ``PerformanceTuning`` sets.
nonisolated struct TuningParameters: Codable, Equatable, Sendable {
    /// Iterations a thread spins on a wait before it parks (`SEVO_WAIT_SPIN`).
    /// One iteration is about 0.4 ns, so 5200 is two microseconds.
    var waitSpin: Int
    /// Whether a wait that keeps missing stops spinning (`SEVO_WAIT_SPIN_ADAPT`).
    var adaptive: Bool
    /// Iterations a thread spins on a contended mutex, event or semaphore
    /// before it parks (`SEVO_OBJECT_SPIN`).
    var objectSpin: Int

    static let standard = TuningParameters(waitSpin: 0, adaptive: false, objectSpin: 0)
    static let experimental = TuningParameters(waitSpin: 5200, adaptive: true, objectSpin: 5200)

    /// What the engine accepts: a spin past this is a thread that never sleeps.
    static let spinRange = 0 ... 1_000_000

    var argument: String { "\(waitSpin),\(adaptive ? 1 : 0),\(objectSpin)" }

    private static func clamped(_ spin: Int) -> Int {
        min(max(spin, spinRange.lowerBound), spinRange.upperBound)
    }

    /// Every key, always: a game's file is read over the bottle's, so an
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

/// The mouse movement a game holding the cursor for mouse-look receives —
/// the driver's `LinearMouse` option (dormison winemac.drv).
nonisolated enum MouseCurve: String, Codable, CaseIterable, Sendable {
    /// The system's acceleration curve applies.
    case system
    /// The raw displacement reaches the game, so the same sweep turns the
    /// camera the same distance at any speed.
    case linear

    var label: String {
        let value = switch self {
        case .system: "macOS acceleration"
        case .linear: "Linear (no acceleration)"
        }
        return InterfaceCopy.localized(value)
    }
}

/// A frame-rate cap (`SEVO_FPS_LIMIT`), applied on every present path, Metal
/// and OpenGL (dormison `winemac.drv` `sevo_limiter`). The rates match a
/// running game's View › Frame Rate Limit.
nonisolated enum FrameRateLimit: String, Codable, CaseIterable, Sendable {
    case off
    case fps30 = "30"
    case fps40 = "40"
    case fps45 = "45"
    case fps60 = "60"
    case fps90 = "90"
    case fps120 = "120"

    /// Frames a second, `0` for no limit.
    var framesPerSecond: Int {
        Int(rawValue) ?? 0
    }

    var label: String {
        self == .off ? InterfaceCopy.localized("Off") : "\(rawValue) fps"
    }
}

/// How much the frame rate counter shows (`SEVO_OVERLAY_LEVEL`).
nonisolated enum OverlayDetail: String, Codable, CaseIterable, Sendable {
    /// The number alone.
    case frameRate = "1"
    /// The number, the 1 % low and a five-second frame-time graph.
    case frameTime = "2"
    /// The graph card plus the game's CPU, GPU load, power draw and
    /// temperature.
    case system = "3"

    /// Whether the counter is the frame-time card, which `fps-graph` reads.
    var showsFrameGraph: Bool {
        self != .frameRate
    }

    var level: Int {
        Int(rawValue) ?? 1
    }

    var label: String {
        let value = switch self {
        case .frameRate: "Frame rate"
        case .frameTime: "Frame rate and frame time"
        case .system: "Everything (CPU, GPU, power, temperature)"
        }
        return InterfaceCopy.localized(value)
    }
}

/// Which decoders play a game's videos (`GST_PLUGIN_FEATURE_RANK`): the Mac's
/// video hardware through VideoToolbox, or GStreamer's own software decoders.
nonisolated enum VideoDecoding: String, Codable, CaseIterable, Sendable {
    /// VideoToolbox (`vtdec_hw`, `vtdec`) ranks first, as the engine ships.
    case hardware
    /// VideoToolbox is ranked out, so `avdec_h264` and its kin decode on the CPU.
    case software

    var label: String {
        let value = switch self {
        case .hardware: "Hardware (VideoToolbox)"
        case .software: "Software"
        }
        return InterfaceCopy.localized(value)
    }

    /// The other choice, offered to a game whose video decoded nothing.
    var other: VideoDecoding {
        self == .hardware ? .software : .hardware
    }
}

/// One level of the settings hierarchy: every key optional, so an absent one
/// inherits from the level above. Game files also carry the executables the
/// game runs under, which per-program values are written against.
nonisolated struct ConfigValues: Codable, Equatable, Sendable {
    var windows: WindowTreatment?
    var mouse: MouseCurve?
    /// Experimental (``PerformanceTuning``).
    var tuning: PerformanceTuning?
    /// The parameters the `custom` tuning stands for at this level.
    var tuningParameters: TuningParameters?
    /// An ``UpscalerChoice`` raw value or a shader package name, stored as
    /// text so a package a later version names still reads.
    var upscaler: String?
    var filter: FinalFilter?
    /// Game level only: the translation layer this game renders through, over
    /// the bottle's own choice. An engine that reads the env files hands it to
    /// the game at its next launch through a `WINEDLLPATH_PREPEND` directory of
    /// that renderer's payload; any other engine needs a client restart
    /// (``BottleGraphics/rendererNeedingRestart(forApp:)``).
    var renderer: Renderer?
    /// Whether the prefix draws at full resolution, doubling the screen size
    /// a game is told (`Mac Driver\RetinaMode`). Bottle-wide: `winemac.drv`
    /// reads it with no app key, so DPI and monitor sizes agree prefix-wide.
    var retina: Bool?
    /// Whether a display-mode switch is faked and the picture shown in a
    /// resizable window (win32u `X11 Driver\EmulateModeset`).
    var emulateModeset: Bool?
    /// Per DLL, the load order Wine gives it, in the registry's own spelling:
    /// `n,b`, `b,n`, `n`, `b`, or the empty string for disabled
    /// (`DllOverrides`, per program under `AppDefaults\<exe>`).
    var dllOverrides: [String: String]?
    /// Variables set by name, written after this level's rows so they win
    /// (``UserEnvironment``). An empty value removes the variable.
    var environment: [String: String]?
    /// Metal's performance HUD (`MTL_HUD_ENABLED`).
    var hud: Bool?
    /// The engine's frame-rate counter at the window's top right (`SEVO_FPS`),
    /// counted from presented frames under any renderer.
    var fps: Bool?
    var overlayDetail: OverlayDetail?
    var frameRateLimit: FrameRateLimit?
    /// Whether a program's own Win32 menus show in the macOS menu bar, with
    /// the strip in its window cropped away (`SEVO_MENU_BAR`).
    var nativeMenuBar: Bool?
    /// Whether a 32-bit game without `IMAGE_FILE_LARGE_ADDRESS_AWARE` gets the
    /// whole 4 GB of address space (`SEVO_LARGE_ADDRESS_AWARE`, dormison's
    /// `virtual_set_large_address_space`, like Proton's
    /// `PROTON_FORCE_LARGE_ADDRESS_AWARE`).
    var largeAddressAware: Bool?
    /// Whether Rosetta advertises AVX and AVX2 to a game's CPU check
    /// (`ROSETTA_ADVERTISE_AVX`); it translates them either way.
    var avx: Bool?
    /// Experimental: whether the game is told the Mac's memory is one pool
    /// shared by the CPU and the GPU, which it is (`SEVO_FORCE_UMA`).
    ///
    /// D3DMetal answers `ARCHITECTURE1.UMA` with 0, so every engine writes
    /// each upload into a staging buffer and then copies it into a second
    /// allocation that is the same physical memory. Skipping that copy is
    /// worth 27-107% of a bandwidth-bound frame; dormison's `winemac.drv`
    /// reports the unified answer when this is on. Off by default: a game that
    /// believes it takes every unified path, and the texture layouts among
    /// them are the least tested.
    var unifiedMemory: Bool?
    /// Whether the pointer stays inside the window while the game clips the
    /// cursor (`SEVO_CURSOR_CONFINE`), so mouse-look cannot reach a second
    /// display.
    var cursorConfine: Bool?
    /// The processor count a game is told (`SEVO_CPU_COUNT`), capping
    /// `GetSystemInfo`, the affinity mask and
    /// `GetLogicalProcessorInformation`; `0` is every processor. Unity 5's
    /// JobQueue spins one worker per processor under Rosetta, so fewer
    /// processors means fewer spinning workers.
    var processors: Int?
    var videoDecoding: VideoDecoding?
    /// Game level only: ``GameRunner`` `wine` (the default) or `nwjs`, stored
    /// as text so a runner a later version names still reads.
    var runner: String?
    /// Game level only: whether Play uses Sevoflurane's Steam or hands the
    /// macOS version to Steam for Mac (``MacBuildRoute``), honored while
    /// ``NativeSteam/isOffered``.
    var build: GameBuild?
    /// Game level only: what ``NWJSGames`` found, recorded whether or not the
    /// native runner is on.
    var nwjs: NWJSInfo?
    /// Game level only: the NW.js release the native runner installed
    /// (``NWJSRuntime/release(forGameVersion:)``).
    var nwjsRuntime: String?
    /// Game level only: lowercased exe names `GameLaunchWatch` saw own the
    /// first window.
    var exes: [String]?
    /// Game level only: the display name.
    var name: String?
    /// Game level only: set for an adopted program (``AdoptedPrograms``).
    var program: AdoptedProgram?

    static let empty = ConfigValues()

    /// Whether any setting is set at this level; the exe list and the
    /// detection record are bookkeeping.
    var hasSettings: Bool {
        windows != nil || mouse != nil || upscaler != nil || filter != nil || runner != nil
            || renderer != nil || retina != nil || emulateModeset != nil
            || dllOverrides?.isEmpty == false || environment?.isEmpty == false
            || hud != nil || fps != nil || overlayDetail != nil || frameRateLimit != nil || nativeMenuBar != nil
            || largeAddressAware != nil || avx != nil || cursorConfine != nil
            || unifiedMemory != nil || tuning != nil || processors != nil || videoDecoding != nil || build != nil
    }

    /// Whether this game runs natively rather than through the bottle.
    var runsNatively: Bool { runner == GameRunner.nwjs }
}

nonisolated extension ConfigValues {
    /// `fps-graph` at this level: on is the frame-time card with the counter
    /// shown, off the number alone, `nil` inherits.
    mutating func setFrameGraph(_ on: Bool?, counterShown: Bool) {
        switch on {
        case nil: overlayDetail = nil
        case false?: overlayDetail = .frameRate
        case true?:
            overlayDetail = .frameTime
            if !counterShown { fps = true }
        }
    }
}

/// The runtimes a game can run on. `wine` is the default and never written.
nonisolated enum GameRunner {
    static let wine = "wine"
    static let nwjs = "nwjs"
    static let all = [wine, nwjs]
    /// A game's own macOS build, set by Steam's mapping (``SteamPlayMacOS``),
    /// so it is outside ``all``; run records name it as runner and renderer.
    static let macos = "macos"
}

/// What a changed setting costs to reach the game, as Settings and `sevo`
/// say it.
nonisolated enum SettingReach: Equatable, Sendable {
    case nextLaunch
    /// The client carries the value, so it restarts around the next launch.
    case clientRestart

    var label: String {
        let value = switch self {
        case .nextLaunch: "Next launch"
        case .clientRestart: "Steam restart"
        }
        return InterfaceCopy.localized(value)
    }

    var detail: String {
        let value = switch self {
        case .nextLaunch:
            "reaches the game the next time it starts; Steam keeps running"
        case .clientRestart:
            "the Steam client carries this value, so it restarts (about 30 s) "
                + "around the next launch"
        }
        return InterfaceCopy.localized(value)
    }

    /// An env-file setting: next launch where the engine reads the files.
    static var env: SettingReach {
        Engine.active.supportsEnvFiles ? .nextLaunch : .clientRestart
    }

    /// The registry is live in wineserver and read at every process start.
    static let registry = SettingReach.nextLaunch

    /// A renderer a `WINEDLLPATH_PREPEND` directory can carry rides in the
    /// game's env file; any other is the client's to hand down.
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

/// The settings hierarchy — global, bottle, game — and its resolver. JSON
/// files under `~/Library/Application Support/Sevoflurane/Config/` are the
/// source of truth; `ConfigMaterializer` derives the engine's env files.
nonisolated enum GameConfig {
    static let root = AppIdentity.supportFolder
        .appendingPathComponent("Config")

    /// What every level inherits when nothing is set anywhere.
    static let defaults = ConfigValues(
        windows: .fixed, mouse: .system, tuning: .standard,
        // Lanczos as the final filter costs 0.3 ms a frame in a window and 1.4 ms at a full 5K
        // output on an M1 Max; with the presenter off, Core Animation stretches the picture
        // bilinearly.
        upscaler: UpscalerChoice.lanczos.rawValue, filter: .lanczos,
        retina: false, emulateModeset: false,
        // AVX on: a growing number of titles read the CPUID answer and refuse
        // to start without it. A game that misbehaves with it turns it off for
        // itself.
        hud: false, fps: false, overlayDetail: .frameRate, frameRateLimit: .off, nativeMenuBar: false, largeAddressAware: true, avx: true, unifiedMemory: false,
        cursorConfine: false, processors: 0, videoDecoding: .hardware,
    )

    // MARK: - Levels

    static func global() -> ConfigValues {
        migrateIfNeeded()
        return read(globalURL)
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

    // Each resolver answers for a specific game when its id is known,
    // otherwise for the bottle (``resolve(_:bottle:game:)``).

    static func windows(bottle: String, game appID: Int? = nil) -> Resolved<WindowTreatment> {
        resolve(\.windows, bottle: bottle, game: appID)
    }

    static func mouse(bottle: String, game appID: Int? = nil) -> Resolved<MouseCurve> {
        resolve(\.mouse, bottle: bottle, game: appID)
    }

    static func tuning(bottle: String, game appID: Int? = nil) -> Resolved<PerformanceTuning> {
        resolve(\.tuning, bottle: bottle, game: appID)
    }

    /// The resolved preset's parameters; for `custom`, the nearest level's.
    static func tuningParameters(bottle: String, game appID: Int? = nil) -> TuningParameters {
        let custom = appID.flatMap { game($0).tuningParameters }
            ?? Self.bottle(bottle).tuningParameters ?? global().tuningParameters
        return tuning(bottle: bottle, game: appID).value.parameters(custom: custom)
    }

    static func upscaler(bottle: String, game appID: Int? = nil) -> Resolved<String> {
        resolve(\.upscaler, bottle: bottle, game: appID)
    }

    static func unifiedMemory(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.unifiedMemory, bottle: bottle, game: appID)
    }

    static func filter(bottle: String, game appID: Int? = nil) -> Resolved<FinalFilter> {
        resolve(\.filter, bottle: bottle, game: appID)
    }

    /// Prefix-wide, so there is no game to ask for.
    static func retina(bottle: String) -> Resolved<Bool> {
        resolve(\.retina, bottle: bottle, game: nil)
    }

    static func emulateModeset(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.emulateModeset, bottle: bottle, game: appID)
    }

    static func hud(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.hud, bottle: bottle, game: appID)
    }

    static func fps(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.fps, bottle: bottle, game: appID)
    }

    static func overlayDetail(bottle: String, game appID: Int? = nil) -> Resolved<OverlayDetail> {
        resolve(\.overlayDetail, bottle: bottle, game: appID)
    }

    static func frameRateLimit(bottle: String, game appID: Int? = nil) -> Resolved<FrameRateLimit> {
        resolve(\.frameRateLimit, bottle: bottle, game: appID)
    }

    static func nativeMenuBar(bottle: String, game appID: Int? = nil) -> Resolved<Bool> {
        resolve(\.nativeMenuBar, bottle: bottle, game: appID)
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

    static func processors(bottle: String, game appID: Int? = nil) -> Resolved<Int> {
        resolve(\.processors, bottle: bottle, game: appID)
    }

    static func videoDecoding(bottle: String, game appID: Int? = nil) -> Resolved<VideoDecoding> {
        resolve(\.videoDecoding, bottle: bottle, game: appID)
    }

    /// The game's own renderer, otherwise the bottle's. The bottle's lives in
    /// the graphics store, where it is
    /// negotiated with the staged Wine tree and with msync, so this resolver
    /// reaches across to it instead of falling through to ``defaults``.
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

    /// Changes the bottle's own values and rewrites the env files — the one
    /// write path Settings › Engine and `sevo bottle config` share.
    ///
    /// - Parameter inBackground: write the env files on a detached task, for
    ///   a main-actor caller; otherwise they are on disk on return.
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

    /// The game-level counterpart of ``update(bottle:prefix:inBackground:_:)``,
    /// shared by Settings › Games and `sevo app config`.
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

    /// Where a changed setting is logged: the app's event log, or for `sevo`
    /// the log file.
    nonisolated(unsafe) static var logChange: @Sendable (String) -> Void = appendToLogFile

    /// One line per changed setting, with the writing process and its parent:
    /// Settings, `sevo` and a running game's View menu all write settings.
    private static func noteChanges(from before: ConfigValues, to after: ConfigValues, of level: String) {
        let writer = "\(ProcessInfo.processInfo.processName), started by \(parentProcessName())"
        for change in changes(from: before, to: after) {
            logChange("settings: \(level) \(change) (\(writer))")
        }
    }

    /// Each differing setting as `key was → is`; `inherit` for an unset one.
    static func changes(from before: ConfigValues, to after: ConfigValues) -> [String] {
        guard before != after else { return [] }
        let old = fields(of: before), new = fields(of: after)
        return Set(old.keys).union(new.keys).sorted().compactMap { key in
            let was = old[key] ?? "inherit", now = new[key] ?? "inherit"
            return bookkeepingKeys.contains(key) || was == now ? nil : "\(key) \(was) → \(now)"
        }
    }

    /// What a level records about a game rather than sets for it.
    private static let bookkeepingKeys: Set<String> = ["exes", "name", "program", "nwjs", "nwjsRuntime"]

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
        guard length > 0 else { return "pid \(getppid())" }
        return String(decoding: name.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
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
        let url = AppIdentity.logFile()
        let line = "\(changeStamp.string(from: .now)) [app] \(message)\n"
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    // MARK: - Executables

    /// Records that a launch of this app put up a window owned by `exe`.
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

    /// Whether `exe` is a helper a game starts beside itself (an embedded
    /// browser, a crash reporter, a redistributable's installer). It takes the
    /// game's settings but never its Dock identity: Unreal's
    /// `EpicWebHelper.exe` alone is three to five short-lived processes.
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

    /// An empty level has no file.
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

    /// Moves settings keys found in the shared defaults into the hierarchy.
    /// Each pass clears the keys it read, so none runs twice.
    private static func migrateIfNeeded() {
        migrateWindowSwitches()
        migrateRendererPins()
        _ = frameGraphMigration
    }

    /// Rewrites each level's `fpsGraph` key as an overlay detail, once per
    /// process.
    private static let frameGraphMigration: Void = {
        let manager = FileManager.default
        var urls = [globalURL]
        for directory in [bottlesRoot, gamesRoot] {
            let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            urls += entries.filter { $0.pathExtension == "json" }
        }
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let values = migratedFrameGraph(data) else { continue }
            write(values, to: url)
        }
    }()

    /// A level stored with `fpsGraph`, with an on switch as the frame-time
    /// card and the counter shown; `nil` for a file without the key.
    static func migratedFrameGraph(_ data: Data) -> ConfigValues? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let graph = object["fpsGraph"] as? Bool,
              var values = try? JSONDecoder().decode(ConfigValues.self, from: data) else { return nil }
        if graph, values.overlayDetail == nil {
            values.overlayDetail = .frameTime
            values.fps = true
        }
        return values
    }

    /// Moves the two window switches in the shared defaults into the global
    /// `windows`, then removes the keys.
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

    /// Moves the per-app renderer pins in the shared defaults into each game's
    /// `renderer`. The key goes first, so an undecodable map is not retried on
    /// every read.
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

    /// One entry of the shared defaults' per-app renderer map.
    private struct RendererPin: Decodable {
        let renderer: Renderer
        let name: String
    }
}
