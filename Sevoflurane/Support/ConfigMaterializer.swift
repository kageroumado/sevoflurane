import Foundation

/// Turns the settings hierarchy into what the engine reads at process start:
/// `<prefix>/.sevo/bottle.env` for the bottle's resolved values and
/// `<prefix>/.sevo/apps/<exe>.env` for every game with a value of its own
/// (methylpentynol ntdll, `load_sevo_env`). Whole-file rewrites, idempotent;
/// run after every store change and at every client start.
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
        removeStale(in: appsDir, keeping: wanted)
        GameLaunchers.remove(keeping: launchers)
        // A game switched back to wine keeps its browsing-data link (the two
        // runners share one store by design) and loses the wrapper package,
        // which describes a run that is no longer arranged.
        NWJSRunner.removeWrappers(keeping: native)
    }

    /// The bottle level: the resolved value of every setting the engine takes
    /// from the environment.
    private static func bottleLines(_ name: String) -> [String] {
        var lines = ["SEVO_RESIZABLE_WINDOWS=\(GameConfig.windows(bottle: name).value.rawValue)"]
        if GameConfig.mouse(bottle: name).value == .linear {
            lines.append("SEVO_LINEAR_MOUSE=1")
        }
        lines.append("WINEDEBUG=\(WineLog.channels)")
        return lines
    }

    /// A game's file carries only what the game sets; everything else falls
    /// through to the bottle's file, which the engine reads first.
    private static func gameLines(_ appID: Int, _ values: ConfigValues) -> [String] {
        var lines = ["# app \(appID)" + (values.name.map { " \($0)" } ?? "")]
        if let windows = values.windows {
            lines.append("SEVO_RESIZABLE_WINDOWS=\(windows.rawValue)")
        }
        // A game asking for the system curve where the bottle is linear needs
        // the key written, not omitted: the bottle's file is read first and
        // an absent key leaves its value standing.
        if let mouse = values.mouse {
            lines.append("SEVO_LINEAR_MOUSE=\(mouse == .linear ? "1" : "0")")
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
