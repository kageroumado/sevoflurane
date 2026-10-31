import Foundation
import Synchronization

/// Turns the settings hierarchy into what the engine reads at process start:
/// `<prefix>/.sevo/bottle.env` for the bottle's resolved values,
/// `<prefix>/.sevo/apps/<exe>.env` for every game with a value of its own,
/// and `<prefix>/.sevo/apps/<install folder>/<exe>.env` for a game whose
/// install folder is known, which an engine from r9 reads after the exe's own
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

    /// The engine a pass writes the files for: its name for a game's readout,
    /// and the loader the launcher bundles carry. ``Engine/running`` in the
    /// app and `sevo`, where ``Engine/active`` can lead the booted client by a
    /// restart. The daemon boots the client, and its own `active` is always
    /// the engine booting or booted, so the pass right before a boot writes
    /// for the engine about to run; it answers that instead.
    nonisolated(unsafe) static var engine: @Sendable () -> Engine = { Engine.running }

    /// Rewrites the bottle's env files from the store.
    ///
    /// Passes over one prefix run one at a time, and a call that arrives while
    /// one runs waits for the next pass rather than starting its own: any
    /// number of calls made during a pass are answered by a single pass after
    /// it, which reads the store as it stands by then.
    static func materialize(bottle name: String, prefix: URL) {
        passes.run(key: "\(name)\n\(prefix.standardizedFileURL.path)") {
            pass(bottle: name, prefix: prefix)
        }
    }

    /// ``materialize(bottle:prefix:)`` on a detached task, for a caller on the
    /// main actor: a pass signs loader bundles and waits on `codesign`.
    static func materializeInBackground(bottle name: String, prefix: URL) {
        Task.detached(name: "Write the env files") {
            materialize(bottle: name, prefix: prefix)
        }
    }

    private static let passes = CoalescingGate()

    private static func pass(bottle name: String, prefix: URL) {
        let manager = FileManager.default
        let dir = prefix.appendingPathComponent(".sevo")
        let appsDir = dir.appendingPathComponent("apps")
        try? manager.createDirectory(at: appsDir, withIntermediateDirectories: true)

        let engine = engine()
        write(bottleLines(name, engine: engine), to: dir.appendingPathComponent("bottle.env"))

        var games: [GameFiles] = []
        var native: Set<Int> = []
        var launchers: Set<Int> = []
        let installed = Dictionary(
            SharedGames.installedGames().map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first },
        )
        for (appID, values) in materializedGames(GameConfig.games(), installed: Set(installed.keys)) {
            var game = gameFiles(appID: appID, values: values, bottle: name, prefix: prefix, engine: engine)
            game.folder = installed[appID].map { folderKey($0.directory.lastPathComponent) }
            if game.loader != nil { launchers.insert(appID) }
            if !game.runner.isEmpty { native.insert(appID) }
            games.append(game)
        }
        let inFlight = launching.withLock { $0 }
        let files = withClientFile(appFiles(games, launching: inFlight), steamPlay: engine.supportsSteamPlayMacOS)
        for (exe, claimants) in sharedExecutables(games) {
            noteShared(exe, by: claimants, launching: inFlight)
        }
        writeFiles(files, in: appsDir)
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

        removeStale(in: appsDir, keeping: Set(files.keys))
        GameLaunchers.remove(keeping: launchers)
        GamesFolder.sync(appIDs: launchers)
        // A game switched back to wine keeps its browsing-data link (the two
        // runners share one store by design) and loses the wrapper package,
        // which describes a run that is no longer arranged.
        NWJSRunner.removeWrappers(keeping: native)
    }

    /// The games a pass writes for, in app id order: every game with a
    /// setting or an executable on record whose records claim executables
    /// (``GameConfig/claims(_:installed:)``). Every game with an executable
    /// on record is written, not only one with settings: the loader bundle
    /// is what gives a game its own name, icon and Game Mode, and a game
    /// nobody has configured wants those too. A Steam game with no manifest
    /// is left out: it cannot start, and its exes would otherwise take the
    /// env file, and the loader, from a game that can.
    static func materializedGames(
        _ games: [Int: ConfigValues], installed: Set<Int>,
    ) -> [(appID: Int, values: ConfigValues)] {
        GameConfig.claimants(in: games, installed: installed)
            .filter { $0.value.hasSettings || $0.value.exes != nil }
            .sorted { $0.key < $1.key }
            .map { (appID: $0.key, values: $0.value) }
    }

    /// One game's lines, its loader bundle built or refreshed and its native
    /// runner's variables resolved.
    private static func gameFiles(
        appID: Int, values: ConfigValues, bottle name: String, prefix: URL, engine: Engine,
    ) -> GameFiles {
        // A tool recorded as a game's before the filter knew it would start
        // through the game's bundle, with its settings, from any launch.
        let exes = (values.exes ?? []).filter(GameExecutables.isRecordable)
        var game = GameFiles(appID: appID, settings: gameLines(appID, values, bottle: name), exes: exes)
        if let title = values.name, !values.runsNatively,
           let loader = GameLaunchers.materialize(
               appID: appID, title: title, engine: engine,
           ) {
            game.loader = "SEVO_LOADER=\(loader.path)"
        }
        if values.runsNatively, let info = values.nwjs,
           let environment = NWJSRunner.environment(
               appID: appID, info: info, runtimeVersion: values.nwjsRuntime, prefix: prefix,
           ) {
            game.runner = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }
        return game
    }

    // MARK: - The launch in flight

    /// The app whose launch last began in this process. Its lines fill the
    /// file of every executable it shares with another game
    /// (``appFiles(_:launching:)``) until another claimant launches.
    private static let launching = Mutex<Int?>(nil)

    /// A launch of `appID` is about to start its process: the env file of
    /// every executable it shares with another game is rewritten with its own
    /// lines, so the process starts as this game, with its loader and its
    /// settings. The engine finds the file by exe name alone, and a shared
    /// file otherwise carries only what its claimants agree on. Passes from
    /// here on keep this game's lines in those files, until another claimant
    /// launches and takes them.
    ///
    /// Written here, ahead of the next pass, because Steam starts the process
    /// within moments of the launch beginning, and a pass signs loader
    /// bundles first.
    static func noteLaunch(of appID: Int, bottle name: String, prefix: URL) {
        launching.withLock { $0 = appID }
        let games = materializedGames(GameConfig.games(), installed: SharedGames.installedAppIDs)
        guard let own = games.first(where: { $0.appID == appID }) else { return }
        let engine = engine()
        let launched = gameFiles(appID: appID, values: own.values, bottle: name, prefix: prefix, engine: engine)
        let others = games.filter { $0.appID != appID }.map { other in
            GameFiles(appID: other.appID, settings: [], exes: (other.values.exes ?? []).filter(GameExecutables.isRecordable))
        }
        let files = withClientFile(launchFiles(for: launched, among: others), steamPlay: engine.supportsSteamPlayMacOS)
        guard !files.isEmpty else { return }
        writeFiles(files, in: prefix.appendingPathComponent(".sevo/apps"))
        GameExecutables.log("launch \(appID): \(files.keys.sorted().joined(separator: ", ")) written with its lines, for its launch")
    }

    /// The files of the executables `game` shares with `others`, each with
    /// `game`'s lines, by file name. Empty when it shares none.
    static func launchFiles(for game: GameFiles, among others: [GameFiles]) -> [String: [String]] {
        let shared = sharedExecutables(others + [game]).filter { $0.appIDs.contains(game.appID) }.map(\.exe)
        let files = appFiles(others + [game], launching: game.appID)
        return Dictionary(uniqueKeysWithValues: shared.compactMap { exe in
            files["\(exe).env"].map { ("\(exe).env", $0) }
        })
    }

    // MARK: - One file per executable

    /// What one game puts in the env file of each executable it owns.
    struct GameFiles {
        var appID: Int
        /// ``gameLines(_:_:engine:)``: the game's own settings.
        var settings: [String]
        /// The lowercased executables the game has on record.
        var exes: [String]
        /// `SEVO_LOADER=…`, the bundle that is the game's Dock identity.
        var loader: String?
        /// The native runner's variables, which run the exe as this game.
        var runner: [String] = []
        /// The game's install folder under `steamapps/common`, as
        /// ``ConfigMaterializer/folderKey(_:)`` spells it, when the game is a
        /// Steam game on disk. It is one game's, so the files under it are
        /// the game's alone whatever other game ships the exe.
        var folder: String?
    }

    /// The env file of every executable, by path under the apps directory.
    ///
    /// The engine finds a file by exe name alone, and games do share names:
    /// every RPG Maker MV/MZ game ships `game.exe`, and many a game ships
    /// `launcher.exe`. A file claimed by one game carries its settings, its
    /// runner and its Dock identity. A file claimed by several carries only
    /// the settings every one of them agrees on: another game's loader or
    /// runner would start the exe as that other game. The exception is the
    /// claimant whose launch is in flight (`launching`): its process is the
    /// one about to read the file, so the file carries its full lines. The
    /// result is the same whatever order `games` comes in.
    ///
    /// A game with an install folder gets `<folder>/<exe>.env` as well, with
    /// its full lines: an engine from r9 reads it after the exe's own file
    /// and finds the game's identity there without the launch rewrite.
    static func appFiles(_ games: [GameFiles], launching: Int? = nil) -> [String: [String]] {
        let ordered = games.sorted { $0.appID < $1.appID }
        var claimants: [String: [GameFiles]] = [:]
        for game in ordered {
            for exe in Set(game.exes) { claimants[exe, default: []].append(game) }
        }
        var files: [String: [String]] = [:]
        for game in ordered {
            guard let folder = game.folder else { continue }
            for exe in Set(game.exes) { files["\(folder)/\(exe).env"] = ownLines(of: game, for: exe) }
        }
        for (exe, owners) in claimants {
            let file = "\(exe).env"
            guard owners.count > 1 else {
                files[file] = ownLines(of: owners[0], for: exe)
                continue
            }
            let apps = owners.map { String($0.appID) }.joined(separator: ", ")
            if let launching, let owner = owners.first(where: { $0.appID == launching }) {
                files[file] = ["# apps \(apps) all ship \(exe); written for app \(launching)'s launch"]
                    + ownLines(of: owner, for: exe)
                continue
            }
            let settings = owners.map { $0.settings.filter { !$0.hasPrefix("#") } }
            let agreed = settings[0].filter { line in settings.allSatisfy { $0.contains(line) } }
            files[file] = ["# apps \(apps) all ship \(exe)"] + agreed
        }
        return files
    }

    /// A file that is one game's alone: its settings, its runner and its
    /// Dock identity. The loader is that identity, which a companion program
    /// never takes (``GameConfig/isCompanionExecutable(_:)``).
    private static func ownLines(of game: GameFiles, for exe: String) -> [String] {
        let identity = GameConfig.isCompanionExecutable(exe) ? [] : [game.loader].compactMap(\.self)
        return game.settings + game.runner + identity
    }

    /// An install folder's name as the engine keys a file on it: the folder
    /// names of the program's path with ASCII letters lowered, which is what
    /// `tolower` does byte by byte on the engine's side.
    static func folderKey(_ folder: String) -> String {
        String(folder.map { $0.isASCII ? Character($0.lowercased()) : $0 })
    }

    /// `steam.exe`'s own file, with Steam Play switched on for an engine that
    /// runs macOS builds (``SteamPlayMacOS``). A game that ships its own
    /// `steam.exe` keeps its lines, and the switch is added to them; the
    /// engine reads the file at the client's next start.
    static func withClientFile(_ files: [String: [String]], steamPlay: Bool) -> [String: [String]] {
        guard steamPlay else { return files }
        var files = files
        let line = SteamPlayMacOS.environmentLine
        files[SteamPlayMacOS.clientEnvFile] = (files[SteamPlayMacOS.clientEnvFile] ?? []).filter { $0 != line } + [line]
        return files
    }

    /// Executables more than one game claims, each with its claimants in
    /// app id order.
    static func sharedExecutables(_ games: [GameFiles]) -> [(exe: String, appIDs: [Int])] {
        var claimants: [String: [Int]] = [:]
        for game in games {
            for exe in Set(game.exes) { claimants[exe, default: []].append(game.appID) }
        }
        return claimants.filter { $0.value.count > 1 }
            .map { ($0.key, $0.value.sorted()) }
            .sorted { $0.exe < $1.exe }
    }

    /// Shared executables already narrated, so each state of each is said
    /// once per process: once as shared, once per claimant whose launch took
    /// the file.
    private static let narratedShares = Mutex<Set<String>>([])

    private static func noteShared(_ exe: String, by appIDs: [Int], launching: Int?) {
        let note = shareNote(exe, by: appIDs, launching: launching)
        let isNew = narratedShares.withLock { $0.insert(note).inserted }
        guard isNew else { return }
        GameExecutables.log(note)
    }

    /// What the log says of an exe several games ship: whose lines its file
    /// carries, which is the launching claimant's while one is in flight and
    /// otherwise only what the claimants agree on.
    static func shareNote(_ exe: String, by appIDs: [Int], launching: Int?) -> String {
        let apps = appIDs.map(String.init).joined(separator: ", ")
        if let launching, appIDs.contains(launching) {
            return "apps \(apps) all ship \(exe): its env file carries app \(launching)'s lines, for its launch"
        }
        return "apps \(apps) all ship \(exe): its env file carries only the settings they share"
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

    /// The `sevo` inside the app bundle, whether this code runs in the app or
    /// in that `sevo` itself.
    private static var bundledCLI: URL? {
        Bundle.main.executableURL.flatMap { cli(forExecutable: $0.resolvingSymlinksInPath()) }
    }

    /// The `sevo` a process running `executable` hands to the engine: the one inside the
    /// enclosing app — whether the process is the app or its daemon, which runs from
    /// `Contents/Library/LaunchAgents` — or the executable itself when it is a `sevo`.
    static func cli(forExecutable executable: URL) -> URL? {
        var candidates: [URL] = []
        var directory = executable.deletingLastPathComponent()
        while directory.path != "/", !directory.path.isEmpty {
            if directory.pathExtension == "app" {
                candidates.append(directory.appendingPathComponent("Contents/Helpers/sevo"))
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        if executable.lastPathComponent == "sevo" { candidates.append(executable) }
        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: candidate.path)
        }
    }

    static func debugEnvURL(prefix: URL) -> URL {
        prefix.appendingPathComponent(".sevo/debug.env")
    }

    /// The bottle level: the resolved value of every setting the engine takes
    /// from the environment.
    static func bottleLines(_ name: String, engine: Engine = Engine.running) -> [String] {
        var lines = [
            "SEVO_RESIZABLE_WINDOWS=\(GameConfig.windows(bottle: name).value.rawValue)",
            "SEVO_UPSCALER=\(GameConfig.upscaler(bottle: name).value)",
            "SEVO_FINAL_FILTER=\(GameConfig.filter(bottle: name).value.rawValue)",
            "SEVO_SHADER_DIR=\(ShaderPackages.root.path)",
        ]
        if GameConfig.mouse(bottle: name).value == .linear {
            lines.append("SEVO_LINEAR_MOUSE=1")
        }
        let processors = GameConfig.processors(bottle: name).value
        if processors > 0 {
            lines.append("SEVO_CPU_COUNT=\(processors)")
        }
        lines += switches.map { key, resolve in
            "\(key)=\(resolve(name, nil) ? "1" : "0")"
        }
        lines.append("SEVO_OVERLAY_LEVEL=\(GameConfig.overlayDetail(bottle: name).value.rawValue)")
        lines.append(frameGraphLine(
            GameConfig.overlayDetail(bottle: name).value, counterShown: GameConfig.fps(bottle: name).value,
        ))
        lines.append("SEVO_FPS_LIMIT=\(GameConfig.frameRateLimit(bottle: name).value.framesPerSecond)")
        lines.append(videoDecodingLine(GameConfig.videoDecoding(bottle: name).value))
        lines += GameConfig.tuningParameters(bottle: name).environment.map { "\($0.key)=\($0.value)" }
        // What a running game's View menu needs: the engine's name for its
        // readout, and the `sevo` that stores a choice made there.
        lines.append("SEVO_ENGINE_NAME=\(engine.recordIdentifier)")
        if let cli = bundledCLI { lines.append("SEVO_CLI=\(cli.path)") }
        let level = DiagnosticLevel.current
        lines.append("WINEDEBUG=\(level.channels())")
        lines += level.rendererLines
        // Last, so a variable set by name wins over the rows above.
        lines += UserEnvironment.lines(GameConfig.bottle(name).environment)
        return lines
    }

    /// The switches that reach a game as one environment variable each, and
    /// the resolver behind each one. The bottle writes all of them and a game
    /// writes the ones it sets, both ways: the bottle's file is read first, so
    /// an absent key leaves its value standing.
    private static let switches: [(key: String, resolve: @Sendable (String, Int?) -> Bool)] = [
        ("MTL_HUD_ENABLED", { GameConfig.hud(bottle: $0, game: $1).value }),
        ("SEVO_FPS", { GameConfig.fps(bottle: $0, game: $1).value }),
        ("SEVO_MENU_BAR", { GameConfig.nativeMenuBar(bottle: $0, game: $1).value }),
        ("SEVO_LARGE_ADDRESS_AWARE", { GameConfig.largeAddressAware(bottle: $0, game: $1).value }),
        ("ROSETTA_ADVERTISE_AVX", { GameConfig.avx(bottle: $0, game: $1).value }),
        ("SEVO_CURSOR_CONFINE", { GameConfig.cursorConfine(bottle: $0, game: $1).value }),
        ("SEVO_FORCE_UMA", { GameConfig.unifiedMemory(bottle: $0, game: $1).value }),
    ]

    /// Which of ``switches`` this level sets for itself, by key.
    private static func ownSwitches(_ values: ConfigValues) -> [String: Bool] {
        var own: [String: Bool] = [:]
        own["MTL_HUD_ENABLED"] = values.hud
        own["SEVO_FPS"] = values.fps
        own["SEVO_MENU_BAR"] = values.nativeMenuBar
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
    /// `bottle` answers for the half of a paired line the game leaves to it.
    static func gameLines(
        _ appID: Int, _ values: ConfigValues, bottle: String = SteamBottle.name, engine: URL = Engine.active.root,
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
        // Every processor is `SEVO_CPU_COUNT=0`, which the engine reads as no
        // cap: written rather than omitted, so a game asking for all of them
        // overrides a bottle that caps.
        if let processors = values.processors {
            lines.append("SEVO_CPU_COUNT=\(processors)")
        }
        let own = ownSwitches(values)
        lines += switches.compactMap { key, _ in
            own[key].map { "\(key)=\($0 ? "1" : "0")" }
        }
        if let detail = values.overlayDetail {
            lines.append("SEVO_OVERLAY_LEVEL=\(detail.rawValue)")
        }
        if values.overlayDetail != nil || values.fps != nil {
            lines.append(frameGraphLine(
                values.overlayDetail ?? GameConfig.overlayDetail(bottle: bottle).value,
                counterShown: values.fps ?? GameConfig.fps(bottle: bottle).value,
            ))
        }
        // No limit is `SEVO_FPS_LIMIT=0`, written so a game asking for none
        // overrides a bottle that limits.
        if let limit = values.frameRateLimit {
            lines.append("SEVO_FPS_LIMIT=\(limit.framesPerSecond)")
        }
        if let decoding = values.videoDecoding {
            lines.append(videoDecodingLine(decoding))
        }
        if let tuning = values.tuning {
            lines += tuning.parameters(custom: values.tuningParameters).environment
                .map { "\($0.key)=\($0.value)" }
        }
        lines += UserEnvironment.lines(values.environment)
        return lines
    }

    /// The variable an engine older than `SEVO_OVERLAY_LEVEL` reads for level
    /// 2, which also shows the counter; so it is on only where the counter
    /// already is. An engine that reads the level takes it from that line.
    static func frameGraphLine(_ detail: OverlayDetail, counterShown: Bool) -> String {
        "SEVO_FPS_GRAPH=\(detail.showsFrameGraph && counterShown ? "1" : "0")"
    }

    /// The decoder ranks GStreamer reads at start-up. Hardware is the
    /// engine's own order, written as an empty value: the engine unsets a
    /// variable given none, so a game asking for hardware overrides a bottle
    /// on software. Software ranks VideoToolbox out, and `avdec_h264` and its
    /// kin take the stream.
    static func videoDecodingLine(_ decoding: VideoDecoding) -> String {
        switch decoding {
        case .hardware: "GST_PLUGIN_FEATURE_RANK="
        case .software: "GST_PLUGIN_FEATURE_RANK=vtdec_hw:NONE,vtdec:NONE"
        }
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

    /// Writes every file of `files` into `dir`, each under the header
    /// ``removeStale(in:keeping:)`` knows the app's files by.
    /// Writes each file at its path under `dir`, making the folder of a
    /// folder-keyed one.
    static func writeFiles(_ files: [String: [String]], in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (file, lines) in files {
            let url = dir.appendingPathComponent(file)
            if file.contains("/") {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
            }
            write(lines, to: url)
        }
    }

    private static func write(_ lines: [String], to url: URL) {
        let text = ([header] + lines).joined(separator: "\n") + "\n"
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == text { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes every file of ours under `dir`, folders included, whose path
    /// under it is not in `wanted`, and a folder left empty by that.
    static func removeStale(in dir: URL, keeping wanted: Set<String>) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
        ) else { return }
        for url in entries {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let inside = Set(wanted.compactMap { path -> String? in
                    guard path.hasPrefix(name + "/") else { return nil }
                    return String(path.dropFirst(name.count + 1))
                })
                removeStale(in: url, keeping: inside)
                if inside.isEmpty, (try? manager.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                    try? manager.removeItem(at: url)
                }
                continue
            }
            guard !wanted.contains(name),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.hasPrefix(header) else { continue }
            try? manager.removeItem(at: url)
        }
    }
}

/// Runs one pass at a time per key, and answers every call that arrived during
/// a pass with a single pass after it.
///
/// A caller returns once a pass that began after its call has finished, so
/// what it changed before calling is on disk when it returns.
final nonisolated class CoalescingGate: @unchecked Sendable {
    private let condition = NSCondition()
    /// Keys with a pass in progress.
    private var running: Set<String> = []
    /// The newest request number handed out, per key.
    private var requested: [String: UInt64] = [:]
    /// The newest request number a finished pass began after, per key.
    private var answered: [String: UInt64] = [:]

    func run(key: String, _ pass: () -> Void) {
        condition.lock()
        let request = requested[key, default: 0] + 1
        requested[key] = request
        while running.contains(key) {
            condition.wait()
        }
        guard answered[key, default: 0] < request else {
            condition.unlock()
            return
        }
        running.insert(key)
        let covers = requested[key, default: request]
        condition.unlock()

        pass()

        condition.lock()
        running.remove(key)
        answered[key] = covers
        condition.broadcast()
        condition.unlock()
    }
}
