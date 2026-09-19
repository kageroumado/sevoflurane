import Foundation

/// Turns the settings hierarchy into what the engine reads at process start:
/// `<prefix>/.sevo/bottle.env` for the bottle's resolved values and
/// `<prefix>/.sevo/apps/<exe>.env` for every game with a value of its own
/// (dormison ntdll, `load_sevo_env`). Whole-file rewrites, idempotent;
/// run after every store change and at every client start. ``DebugMode``'s
/// `debug.env` is read between those two and is written here as well, so one
/// type owns every file in that directory.
///
/// The files carry a header naming this app, and only files with it are
/// removed when a game's values go away — a file someone wrote by hand in the
/// same directory is theirs.
nonisolated enum ConfigMaterializer {
    private static let header = "# written by Sevoflurane; edits are overwritten"

    /// Rewrites the bottle's env files from the store.
    static func materialize(bottle name: String, prefix: URL) {
        let manager = FileManager.default
        let dir = prefix.appendingPathComponent(".sevo")
        let appsDir = dir.appendingPathComponent("apps")
        try? manager.createDirectory(at: appsDir, withIntermediateDirectories: true)

        write(bottleLines(name), to: dir.appendingPathComponent("bottle.env"))

        var wanted: Set<String> = []
        var native: Set<Int> = []
        var launchers: Set<Int> = []
        // Every game with an executable on record, not only one with settings:
        // the loader bundle is what gives a game its own name, icon and Game
        // Mode, and a game nobody has configured wants those too.
        for (appID, values) in GameConfig.games() where values.hasSettings || values.exes != nil {
            var lines = gameLines(appID, values)
            if let title = values.name, !values.runsNatively,
               let loader = GameLaunchers.materialize(
                   appID: appID, title: title, engine: Engine.active,
               ) {
                launchers.insert(appID)
                lines.append("SEVO_LOADER=\(loader.path)")
            }
            if values.runsNatively, let info = values.nwjs,
               let environment = NWJSRunner.environment(
                   appID: appID, info: info, runtimeVersion: values.nwjsRuntime, prefix: prefix,
               ) {
                native.insert(appID)
                lines += environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            }
            for exe in values.exes ?? [] {
                let file = "\(exe).env"
                wanted.insert(file)
                write(lines, to: appsDir.appendingPathComponent(file))
            }
        }
        // Debug mode's file folds the bottle's wine-debug channels in, so a
        // change to them has to reach the file the engine reads after
        // bottle.env; without this a new `+d3d` set while the mode is on would
        // stand in bottle.env yet stay dropped by a stale debug.env.
        if DebugMode.isWritten(prefix: prefix) {
            writeDebugEnv(DebugMode.lines(), prefix: prefix)
        }

        // The registry's own settings, which no env file carries. Queued
        // rather than written here: they take a `reg.exe` inside the bottle,
        // and the record beside these files is what keeps a pass that changes
        // nothing from spawning anything.
        ConfigRegistry.apply(bottle: name, prefix: prefix)

        removeStale(in: appsDir, keeping: wanted)
        GameLaunchers.remove(keeping: launchers)
        // A game switched back to wine keeps its browsing-data link (the two
        // runners share one store by design) and loses the wrapper package,
        // which describes a run that is no longer arranged.
        NWJSRunner.removeWrappers(keeping: native)
    }

    /// Writes ``DebugMode``'s own file, which the engine reads after the
    /// bottle's and before a game's. It is a whole file of its own rather
    /// than lines in `bottle.env` so that turning the mode off is a deletion
    /// and the user's own bottle settings are never rewritten.
    static func writeDebugEnv(_ lines: [String], prefix: URL) {
        let url = debugEnvURL(prefix: prefix)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        write(lines, to: url)
    }

    /// Deletes the debug file, answering whether one was there.
    @discardableResult
    static func removeDebugEnv(prefix: URL) -> Bool {
        let url = debugEnvURL(prefix: prefix)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    static func debugEnvURL(prefix: URL) -> URL {
        prefix.appendingPathComponent(".sevo/debug.env")
    }

    /// The bottle level: the resolved value of every setting the engine takes
    /// from the environment.
    static func bottleLines(_ name: String) -> [String] {
        var lines = [
            "SEVO_RESIZABLE_WINDOWS=\(GameConfig.windows(bottle: name).value.rawValue)",
            "SEVO_UPSCALER=\(GameConfig.upscaler(bottle: name).value)",
            "SEVO_FINAL_FILTER=\(GameConfig.filter(bottle: name).value.rawValue)",
            "SEVO_SHADER_DIR=\(ShaderPackages.root.path)",
        ]
        if GameConfig.mouse(bottle: name).value == .linear {
            lines.append("SEVO_LINEAR_MOUSE=1")
        }
        lines += switches.map { key, resolve in
            "\(key)=\(resolve(name, nil) ? "1" : "0")"
        }
        let level = DiagnosticLevel.current
        lines.append("WINEDEBUG=\(level.channels())")
        lines += level.rendererLines
        return lines
    }

    /// The switches that reach a game as one environment variable each, and
    /// the resolver behind each one. The bottle writes all of them and a game
    /// writes the ones it sets, both ways: the bottle's file is read first, so
    /// an absent key leaves its value standing.
    ///
    /// `SEVO_LARGE_ADDRESS_AWARE` is the one nothing reads yet — the engine
    /// takes a 32-bit image's address space from the image's own characteristic
    /// (``ConfigValues/largeAddressAware``).
    private static let switches: [(key: String, resolve: @Sendable (String, Int?) -> Bool)] = [
        ("MTL_HUD_ENABLED", { GameConfig.hud(bottle: $0, game: $1).value }),
        ("SEVO_LARGE_ADDRESS_AWARE", { GameConfig.largeAddressAware(bottle: $0, game: $1).value }),
        ("ROSETTA_ADVERTISE_AVX", { GameConfig.avx(bottle: $0, game: $1).value }),
        ("SEVO_CURSOR_CONFINE", { GameConfig.cursorConfine(bottle: $0, game: $1).value }),
        ("SEVO_FORCE_UMA", { GameConfig.unifiedMemory(bottle: $0, game: $1).value }),
    ]

    /// Which of ``switches`` this level sets for itself, by key.
    private static func ownSwitches(_ values: ConfigValues) -> [String: Bool] {
        var own: [String: Bool] = [:]
        own["MTL_HUD_ENABLED"] = values.hud
        own["SEVO_LARGE_ADDRESS_AWARE"] = values.largeAddressAware
        own["ROSETTA_ADVERTISE_AVX"] = values.avx
        own["SEVO_CURSOR_CONFINE"] = values.cursorConfine
        own["SEVO_FORCE_UMA"] = values.unifiedMemory
        return own
    }

    /// A game's file carries only what the game sets; everything else falls
    /// through to the bottle's file, which the engine reads first. What the
    /// game sets is written even when it equals the bottle's value: the
    /// bottle's file can change under it, and the game's own choice holds.
    static func gameLines(
        _ appID: Int, _ values: ConfigValues, engine: URL = Engine.active.root,
    ) -> [String] {
        var lines = ["# app \(appID)" + (values.name.map { " \($0)" } ?? "")]
        if let renderer = values.renderer {
            lines += rendererLines(renderer, engine: engine)
        }
        if let windows = values.windows {
            lines.append("SEVO_RESIZABLE_WINDOWS=\(windows.rawValue)")
        }
        if let upscaler = values.upscaler {
            lines.append("SEVO_UPSCALER=\(upscaler)")
        }
        if let filter = values.filter {
            lines.append("SEVO_FINAL_FILTER=\(filter.rawValue)")
        }
        // A game asking for the system curve where the bottle is linear needs
        // the key written, not omitted: the bottle's file is read first and
        // an absent key leaves its value standing.
        if let mouse = values.mouse {
            lines.append("SEVO_LINEAR_MOUSE=\(mouse == .linear ? "1" : "0")")
        }
        let own = ownSwitches(values)
        lines += switches.compactMap { key, _ in
            own[key].map { "\(key)=\($0 ? "1" : "0")" }
        }
        return lines
    }

    /// What gives one game a renderer of its own: the payload's own directory
    /// ahead of the Wine tree on the dll path, builtin resolution forced for
    /// the DLLs that directory carries, and D3DMetal's two unix-call variables
    /// where the payload is the toolkit's — the pair ``Engine/environment(bottle:)``
    /// hands the client for the bottle-wide choice.
    ///
    /// Empty for a renderer this engine cannot hand to one game
    /// (``EngineRenderers/supportsPerGame(_:)``), which leaves the game on the
    /// bottle's staged tree until the client restarts on its renderer.
    private static func rendererLines(_ renderer: Renderer, engine: URL) -> [String] {
        guard let directory = EngineRenderers.prependDirectory(
            for: renderer, engine: engine,
        ) else { return [] }
        var lines = ["WINEDLLPATH_PREPEND=\(directory.path)"]
        if let overrides = EngineRenderers.perGameDLLOverrides(in: directory) {
            lines.append("WINEDLLOVERRIDES=\(overrides)")
        }
        if renderer == .d3dmetal {
            let shared = D3DMetalInstaller.bridgeLibrary(inEngine: engine)
            if FileManager.default.fileExists(atPath: shared.path) {
                lines.append("SEVO_LIBD3DSHARED_PATH=\(shared.path)")
            }
            lines.append("D3DM_WINE_UNIX_CALL=1")
        }
        return lines
    }

    private static func write(_ lines: [String], to url: URL) {
        let text = ([header] + lines).joined(separator: "\n") + "\n"
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == text { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func removeStale(in dir: URL, keeping wanted: Set<String>) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
        ) else { return }
        for url in entries where !wanted.contains(url.lastPathComponent) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.hasPrefix(header) else { continue }
            try? manager.removeItem(at: url)
        }
    }
}
