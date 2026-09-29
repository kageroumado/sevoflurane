import ArgumentParser
import Foundation

/// The switches that are one env key each, by the name the command line
/// calls them. One table, so the two config commands, their help and their
/// JSON cannot name different sets.
enum ConfigSwitches {
    struct Entry: Sendable {
        let key: String
        let path: WritableKeyPath<ConfigValues, Bool?> & Sendable
    }

    static let all: [Entry] = [
        Entry(key: "hud", path: \.hud),
        Entry(key: "fps", path: \.fps),
        Entry(key: "fps-graph", path: \.fpsGraph),
        Entry(key: "cursor-confine", path: \.cursorConfine),
        Entry(key: "avx", path: \.avx),
        Entry(key: "large-address-aware", path: \.largeAddressAware),
    ]

    static var names: String {
        all.map(\.key).joined(separator: " | ")
    }

    static func path(for key: String) -> (WritableKeyPath<ConfigValues, Bool?> & Sendable)? {
        all.first { $0.key == key }?.path
    }

    /// The resolved value and the level it came from, for a game when its id
    /// is known and for the bottle otherwise.
    static func resolved(_ key: String, bottle: String, game appID: Int?) -> Resolved<Bool>? {
        switch key {
        case "hud": GameConfig.hud(bottle: bottle, game: appID)
        case "fps": GameConfig.fps(bottle: bottle, game: appID)
        case "fps-graph": GameConfig.fpsGraph(bottle: bottle, game: appID)
        case "cursor-confine": GameConfig.cursorConfine(bottle: bottle, game: appID)
        case "avx": GameConfig.avx(bottle: bottle, game: appID)
        case "large-address-aware": GameConfig.largeAddressAware(bottle: bottle, game: appID)
        default: nil
        }
    }
}

/// The values `sevo bottle config` and `sevo app config` accept for the keys
/// the settings hierarchy resolves; `inherit` clears the level.
enum ConfigKeyParsing {
    static func windows(_ value: String) throws -> WindowTreatment? {
        if value == "inherit" { return nil }
        guard let treatment = WindowTreatment(rawValue: value) else {
            Sevo.printError("windows must be one of:\n\(WindowTreatment.help)")
            throw SevoExit.badInvocation
        }
        return treatment
    }

    static func mouse(_ value: String) throws -> MouseCurve? {
        if value == "inherit" { return nil }
        guard let curve = MouseCurve(rawValue: value) else {
            Sevo.printError("mouse must be system, linear or inherit")
            throw SevoExit.badInvocation
        }
        return curve
    }

    /// How many processors a game is told of: `all` for every one (stored as
    /// `0`), a count, or the level-clearing value.
    static func processors(_ value: String) throws -> Int? {
        switch value {
        case "inherit": return nil
        case "all": return 0
        default:
            guard let count = Int(value), count > 0 else {
                Sevo.printError("processors must be all, a count such as 8, or inherit")
                throw SevoExit.badInvocation
            }
            return count
        }
    }

    /// A processor count as the command line spells it.
    static func processorsLabel(_ count: Int) -> String {
        count > 0 ? String(count) : "all"
    }

    /// A switch: on, off, or the level-clearing value.
    static func flag(_ value: String, key: String) throws -> Bool? {
        switch value {
        case "inherit": nil
        case "on", "true", "yes": true
        case "off", "false", "no": false
        default:
            Sevo.printError("\(key) must be on, off or inherit")
            throw SevoExit.badInvocation
        }
    }

    /// One `<dll>=<mode>` pair for a game's own load order, `<dll>=` to drop
    /// the entry, or `inherit` to drop the whole table. The modes are Wine's
    /// own spelling, so what is typed is what the registry holds.
    static let overrideModes = ["n,b", "b,n", "n", "b", ""]

    static func dllOverride(_ value: String) throws -> (dll: String, mode: String?)? {
        if value == "inherit" { return nil }
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            Sevo.printError("dll takes <name>=<mode>, <name>= to drop one, or inherit; "
                + "mode is one of n,b | b,n | n | b | \"\" (disabled)")
            throw SevoExit.badInvocation
        }
        let dll = String(parts[0]).lowercased()
        let mode = String(parts[1])
        if mode.isEmpty { return (dll, nil) }
        guard overrideModes.contains(mode) else {
            Sevo.printError("\(dll): mode must be one of n,b | b,n | n | b")
            throw SevoExit.badInvocation
        }
        return (dll, mode)
    }

    /// A game's own translation layer. `auto` is the bottle's business — it
    /// consults CrossOver's per-game database — so a game names a layer or
    /// inherits.
    static func renderer(_ value: String) throws -> Renderer? {
        if value == "inherit" { return nil }
        guard let renderer = Renderer(rawValue: value), renderer != .auto else {
            Sevo.printError("renderer must be \(Renderer.gameRungs)")
            throw SevoExit.badInvocation
        }
        return renderer
    }

    static func filter(_ value: String) throws -> FinalFilter? {
        if value == "inherit" { return nil }
        guard let filter = FinalFilter(rawValue: value) else {
            Sevo.printError("filter must be nearest, bilinear, lanczos or inherit")
            throw SevoExit.badInvocation
        }
        return filter
    }

    /// A fixed choice, or the name of a package that is installed or in the
    /// catalog. A catalog package that is not installed is accepted and
    /// said so: the driver falls back to lanczos until it lands.
    static func upscaler(_ value: String) async throws -> String? {
        if value == "inherit" { return nil }
        if UpscalerChoice(rawValue: value) != nil { return value }
        let manifest = try? await EngineManifest.fetch()
        let catalog = ShaderPackages.catalog(manifest: manifest)
        switch ShaderPackages.choice(for: value, installed: ShaderPackages.installed(), catalog: catalog) {
        case .fixed, .installed:
            return value
        case let .downloadable(entry):
            Sevo.printError("\(entry.title) is in the catalog and not installed: the driver falls back to "
                + "lanczos until `sevo shaders install \(value)`")
            return value
        case nil:
            Sevo.printError("upscaler must be off, lanczos, metalfx, the name of an installed or "
                + "downloadable shader package (sevo shaders list), or inherit; with '\(value)' the "
                + "driver would fall back to lanczos and log one error line")
            throw SevoExit.badInvocation
        }
    }
}

struct BottleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottle",
        abstract: "Bottles, whether Steam is installed in each, and their settings.",
        discussion: "windows takes one of:\n\(WindowTreatment.help)",
    )

    @Argument(help: "list | config | deps [install <id>]") var verb: String = "list"
    @Argument(help: "Config key: renderer | msync (msync+ on or off; msync+ works as the key too) | windows | upscaler | filter | mouse | retina | emulate-modeset | processors | \(ConfigSwitches.names) | wine-debug. Omit to print every key.")
    var key: String?
    @Argument(help: "New value; for windows: \(WindowTreatment.rungs); for processors: all, a count such as 8, or inherit; for wine-debug: on to add exception traces and every library load, off for the errors the log always keeps, or Wine channels. Omit to read the key.")
    var value: String?
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        switch verb {
        case "list":
            try await list()
        case "config":
            try await config()
        case "deps":
            try await dependencies()
        default:
            Sevo.printError("bottle \(verb): unknown verb (list | config | deps)")
            throw SevoExit.badInvocation
        }
    }

    /// The fonts and runtimes Settings › Engine lists for the bottle: what is
    /// installed, and `deps install <id>` for one that is missing.
    private func dependencies() async throws {
        guard key == "install" else {
            let rows = BottleDependencies.catalog.map { dependency in
                (dependency, BottleDependencies.isInstalled(dependency))
            }
            if asJSON {
                print(Sevo.json(rows.map { dependency, installed in
                    [
                        "id": dependency.id,
                        "name": dependency.name,
                        "required": dependency.required,
                        "installed": installed,
                        "download": dependency.download,
                    ]
                }))
                return
            }
            for (dependency, installed) in rows {
                let state = installed ? "installed" : "missing, \(dependency.download)"
                let need = dependency.required ? "required" : "optional"
                print("\(installed ? "✔" : "✖") \(dependency.id)  \(dependency.name) (\(need), \(state))")
            }
            return
        }
        guard let id = value, BottleDependencies.catalog.contains(where: { $0.id == id }) else {
            let ids = BottleDependencies.catalog.map(\.id).joined(separator: " | ")
            Sevo.printError("bottle deps install: name one of \(ids)")
            throw SevoExit.badInvocation
        }
        let failure = await BottleDependencies.install(id) { phase in
            FileHandle.standardError.write(Data("\(phase)\n".utf8))
        }
        if let failure {
            Sevo.printError("bottle deps install \(id): \(failure)")
            throw SevoExit.failed
        }
        print("\(id) installed in bottle '\(SteamBottle.name)'")
    }

    /// Reads or writes the graphics knobs the app's Settings › Graphics pane
    /// drives, against the same store (`Core/BottleGraphics.swift`).
    private func config() async throws {
        // Debug mode folds its own channels into what a game carries, so the
        // effective set the operator sees has to account for its file.
        let debugMode = DebugMode.isWritten(prefix: SteamBottle.root)
        guard let key = key.map(Self.canonicalKey) else {
            printEveryKey(debugMode: debugMode)
            return
        }
        guard let value else {
            try printKey(key, debugMode: debugMode)
            return
        }
        if try await setPresenterKey(key, to: value) { return }
        if try await setPrefixKey(key, to: value, debugMode: debugMode) { return }
        try setGraphicsKey(key, to: value)
    }

    /// Every key with its value, as text or JSON.
    private func printEveryKey(debugMode: Bool) {
        let selection = current()
        guard asJSON else {
            print("renderer \(selection.renderer.rawValue)")
            print("msync+ \(selection.msync)")
            print("windows \(Self.windowsSummary)")
            print("upscaler \(Self.upscalerSummary)")
            print("filter \(Self.filterSummary)")
            print("mouse \(Self.mouseSummary)")
            print("retina \(Self.retinaSummary)")
            print("emulate-modeset \(Self.modesetSummary)")
            print("processors \(Self.processorsSummary)")
            for entry in ConfigSwitches.all {
                print("\(entry.key) \(Self.switchSummary(entry.key))")
            }
            print("wine-debug \(WineLog.summary(debugMode: debugMode))")
            return
        }
        print(Sevo.json([
            "renderer": selection.renderer.rawValue,
            "msync": selection.msync,
            "windows": GameConfig.windows(bottle: SteamBottle.name).value.rawValue,
            "upscaler": GameConfig.upscaler(bottle: SteamBottle.name).value,
            "filter": GameConfig.filter(bottle: SteamBottle.name).value.rawValue,
            "mouse": GameConfig.mouse(bottle: SteamBottle.name).value.rawValue,
            "retina": GameConfig.retina(bottle: SteamBottle.name).value,
            "emulate-modeset": GameConfig.emulateModeset(bottle: SteamBottle.name).value,
            "processors": GameConfig.processors(bottle: SteamBottle.name).value,
            "switches": Dictionary(uniqueKeysWithValues: ConfigSwitches.all.map {
                ($0.key, ConfigSwitches.resolved(
                    $0.key, bottle: SteamBottle.name, game: nil,
                )?.value ?? false)
            }),
            "wine-debug": debugMode || WineLog.isDiagnosing,
            "wine-debug-channels": WineLog.channels,
            "wine-debug-effective": WineLog.effectiveChannels(debugMode: debugMode),
            "debug-mode": debugMode,
        ], pretty: true))
    }

    /// One key's value.
    private func printKey(_ key: String, debugMode: Bool) throws {
        switch key {
        case "renderer": print(current().renderer.rawValue)
        case "msync": print(current().msync)
        case _ where ConfigSwitches.path(for: key) != nil:
            print(Self.switchSummary(key))
        case "retina": print(Self.retinaSummary)
        case "emulate-modeset": print(Self.modesetSummary)
        case "processors": print(Self.processorsSummary)
        case "windows": print(Self.windowsSummary)
        case "upscaler": print(Self.upscalerSummary)
        case "filter": print(Self.filterSummary)
        case "mouse": print(Self.mouseSummary)
        case "wine-debug": print(WineLog.summary(debugMode: debugMode))
        default:
            Sevo.printError("unknown key '\(key)' \(Self.keys)")
            throw SevoExit.badInvocation
        }
    }

    /// Writes one of the keys the presenter reads at the bottle level, and
    /// whether `key` was one of them.
    private func setPresenterKey(_ key: String, to value: String) async throws -> Bool {
        switch key {
        case "windows":
            // The built-in engine's window treatment at the bottle level;
            // `WindowTreatment.help` carries the rungs, and a game overrides
            // the bottle through `sevo app config`.
            let treatment = try ConfigKeyParsing.windows(value)
            updateBottle { $0.windows = treatment }
            print("windows \(Self.windowsSummary) — \(Self.gameReach)")
        case "upscaler":
            // The presenter's upscaler at the bottle level: `off`, `lanczos`,
            // `metalfx`, a shader package's name, or `inherit`.
            let upscaler = try await ConfigKeyParsing.upscaler(value)
            updateBottle { $0.upscaler = upscaler }
            print("upscaler \(Self.upscalerSummary) — \(Self.gameReach)")
        case "filter":
            // How the upscaler's last pass reaches the window: `nearest`,
            // `bilinear`, `lanczos`, or `inherit`.
            let filter = try ConfigKeyParsing.filter(value)
            updateBottle { $0.filter = filter }
            print("filter \(Self.filterSummary) — \(Self.gameReach)")
        case "mouse":
            // What a game holding the cursor for mouse-look is given as
            // movement: `system` for the pointer curve everything else on the
            // Mac gets, `linear` for the mouse's own displacement, or
            // `inherit` for the global default.
            let curve = try ConfigKeyParsing.mouse(value)
            updateBottle { $0.mouse = curve }
            print("mouse \(Self.mouseSummary) — \(Self.gameReach)")
        default:
            return false
        }
        return true
    }

    /// Writes one of the switches, the prefix's registry-backed keys or the
    /// Wine log channels, and whether `key` was one of them.
    private func setPrefixKey(_ key: String, to value: String, debugMode: Bool) async throws -> Bool {
        switch key {
        case _ where ConfigSwitches.path(for: key) != nil:
            let path = ConfigSwitches.path(for: key)!
            let flag = try ConfigKeyParsing.flag(value, key: key)
            updateBottle { $0[keyPath: path] = flag }
            print("\(key) \(Self.switchSummary(key)) — \(Self.gameReach)")
        case "processors":
            // How many processors every game in the bottle is told of: `all`,
            // a count, or `inherit` for the global default.
            let processors = try ConfigKeyParsing.processors(value)
            updateBottle { $0.processors = processors }
            print("processors \(Self.processorsSummary) — \(Self.gameReach)")
        case "retina":
            // The prefix's own HiDPI switch, written to the bottle's
            // `Mac Driver\\RetinaMode`; one answer for every process in it.
            let retina = try ConfigKeyParsing.flag(value, key: "retina")
            updateBottle { $0.retina = retina }
            await ConfigRegistry.settle(bottle: SteamBottle.name, prefix: SteamBottle.root)
            print("retina \(Self.retinaSummary) — \(Self.gameReach)")
        case "emulate-modeset":
            // Whether a game that switches the display mode has the switch
            // faked and its picture put in a window it can be resized in.
            let modeset = try ConfigKeyParsing.flag(value, key: "emulate-modeset")
            updateBottle { $0.emulateModeset = modeset }
            await ConfigRegistry.settle(bottle: SteamBottle.name, prefix: SteamBottle.root)
            print("emulate-modeset \(Self.modesetSummary) — \(Self.gameReach)")
        case "wine-debug":
            // `on` adds every library load to the errors and exceptions the
            // log always keeps, `off` returns to those alone, anything else
            // is Wine's own channel syntax, e.g. `+seh,+loaddll`. Read by the
            // next client start, and inherited by every game it launches.
            switch value {
            case "on", "off": WineLog.setDiagnosing(value == "on")
            default: WineLog.setChannels(value)
            }
            ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
            print("wine-debug \(WineLog.summary(debugMode: debugMode)) — \(Self.gameReach); in the "
                + "client from its next boot: sevo client restart; trail at \(WineLog.fileURL.path)")
        default:
            return false
        }
        return true
    }

    /// Writes the renderer or msync through the engine's own graphics store.
    private func setGraphicsKey(_ key: String, to value: String) throws {
        var selection = current()
        switch key {
        case "renderer":
            guard let renderer = Renderer(rawValue: value) else {
                Sevo.printError("renderer must be one of: "
                    + Renderer.allCases.map(\.rawValue).joined(separator: ", "))
                throw SevoExit.badInvocation
            }
            selection.renderer = renderer
        case "msync":
            guard let flag = Bool(value) else {
                Sevo.printError("msync must be true or false")
                throw SevoExit.badInvocation
            }
            selection.msync = flag
        default:
            Sevo.printError("unknown key '\(key)' \(Self.keys)")
            throw SevoExit.badInvocation
        }
        do {
            try apply(selection)
        } catch {
            Sevo.printError("\(error)")
            throw SevoExit.failed
        }
        print(key == "msync"
            ? "msync+ \(value) — takes effect at the client's next start: sevo client restart"
            : "\(key) \(value) — takes effect at the next game launch")
    }

    private func updateBottle(_ change: (inout ConfigValues) -> Void) {
        GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root, change)
    }

    private func current() -> BottleGraphics.Selection {
        Engine.active.isCrossOver
            ? BottleGraphics.selection(forBottle: SteamBottle.root)
            : BottleGraphics.managedSelection()
    }

    private static let keys = "(renderer | msync | windows | upscaler | filter | mouse | "
        + "retina | emulate-modeset | processors | \(ConfigSwitches.names) | wine-debug)"

    /// The key a setting is stored and scripted under. The listing labels the
    /// sync switch `msync+`, its name everywhere a person reads it, so that
    /// label works as the key too; `msync` stays the key JSON and scripts use.
    static func canonicalKey(_ key: String) -> String {
        key == "msync+" ? "msync" : key
    }

    /// One switch's resolved value and where it comes from.
    static func switchSummary(_ key: String) -> String {
        guard let resolved = ConfigSwitches.resolved(key, bottle: SteamBottle.name, game: nil)
        else { return "unknown" }
        return "\(resolved.value) (\(resolved.source))"
    }

    /// Whether the prefix draws at the display's full resolution, and where
    /// that comes from.
    static var retinaSummary: String {
        let resolved = GameConfig.retina(bottle: SteamBottle.name)
        return "\(resolved.value) (\(resolved.source))"
    }

    /// Whether a display-mode switch is faked, and where that comes from.
    static var modesetSummary: String {
        let resolved = GameConfig.emulateModeset(bottle: SteamBottle.name)
        return "\(resolved.value) (\(resolved.source))"
    }

    /// How many processors the bottle's games are told of, and where that
    /// comes from.
    static var processorsSummary: String {
        let resolved = GameConfig.processors(bottle: SteamBottle.name)
        return "\(ConfigKeyParsing.processorsLabel(resolved.value)) (\(resolved.source))"
    }

    /// The bottle's window treatment, where it comes from, and what it
    /// covers — the rung a reader cannot compare against its neighbors
    /// without being told what those are.
    static var windowsSummary: String {
        let resolved = GameConfig.windows(bottle: SteamBottle.name)
        return "\(resolved.value.rawValue) (\(resolved.source)) — \(resolved.value.summary)"
    }

    /// The bottle's upscaler and where it comes from.
    static var upscalerSummary: String {
        let resolved = GameConfig.upscaler(bottle: SteamBottle.name)
        return "\(resolved.value) (\(resolved.source))"
    }

    /// The bottle's final filter and where it comes from.
    static var filterSummary: String {
        let resolved = GameConfig.filter(bottle: SteamBottle.name)
        return "\(resolved.value.rawValue) (\(resolved.source))"
    }

    /// The bottle's mouse curve and where it comes from.
    static var mouseSummary: String {
        let resolved = GameConfig.mouse(bottle: SteamBottle.name)
        return "\(resolved.value.rawValue) (\(resolved.source))"
    }

    /// When a bottle-level value reaches games: at their next launch on an
    /// engine that reads the env files, after a client restart otherwise.
    static var gameReach: String {
        Engine.active.supportsEnvFiles
            ? "in games from their next launch"
            : "in games started after the client's next boot: sevo client restart"
    }

    private func apply(_ selection: BottleGraphics.Selection) throws {
        switch Engine.active {
        case .crossover, .crossoverPreview:
            try BottleGraphics.apply(selection, toBottle: SteamBottle.root)
        case .managed:
            BottleGraphics.setManagedSelection(selection)
        }
    }

    private func list() async throws {
        let bottles = await SetupProbe.detect().bottles
        if asJSON {
            let rows = bottles.map { ["name": $0.name, "steam": $0.hasSteam] as [String: Any] }
            print(Sevo.json(rows, pretty: true))
        } else if bottles.isEmpty {
            print("no bottles")
        } else {
            for bottle in bottles {
                print("\(bottle.name)  [\(bottle.hasSteam ? "steam" : "empty")]")
            }
        }
    }
}
