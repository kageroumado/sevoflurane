import Foundation
import Synchronization

/// Turns the settings hierarchy into what the engine reads at process start
/// (dormison ntdll `load_sevo_env`): `<prefix>/.sevo/bottle.env`, then
/// ``DebugMode``'s `debug.env`, then `apps/<exe>.env` and, from r9,
/// `apps/<install folder>/<exe>.env`. Whole-file rewrites, idempotent, run
/// after every store change and at every client start.
///
/// Only files carrying `header` are ever removed; a hand-written file is
/// the user's.
nonisolated enum ConfigMaterializer {
    private static let header = "# written by Sevoflurane; edits are overwritten"

    /// The engine a pass writes for: ``Engine/running`` in the app and `sevo`;
    /// the daemon, which boots the client, answers its own `active`.
    nonisolated(unsafe) static var engine: @Sendable () -> Engine = { Engine.running }

    /// Rewrites the bottle's env files from the store. Calls made during a
    /// pass are answered together by one pass after it (``CoalescingGate``).
    static func materialize(bottle name: String, prefix: URL) {
        passes.run(key: "\(name)\n\(prefix.standardizedFileURL.path)") {
            pass(bottle: name, prefix: prefix)
        }
    }

    /// ``materialize(bottle:prefix:)`` off the main actor: a pass waits on
    /// `codesign`.
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
        // Debug mode's file folds the bottle's wine-debug channels in and is
        // read after bottle.env, so it is rewritten too, or a stale debug.env
        // would drop a new `+d3d` set while the mode is on.
        if DebugMode.isWritten(prefix: prefix) {
            writeDebugEnv(DebugMode.lines(), prefix: prefix)
        }

        // Registry settings, queued: a pass that changes nothing spawns no
        // `reg.exe`.
        ConfigRegistry.apply(bottle: name, prefix: prefix)

        removeStale(in: appsDir, keeping: Set(files.keys))
        GameLaunchers.remove(keeping: launchers)
        GamesFolder.sync(appIDs: launchers)
        // A game switched back to wine loses its wrapper package and keeps its
        // shared browsing data.
        NWJSRunner.removeWrappers(keeping: native)
    }

    /// The games a pass writes for, in app id order: every claimant
    /// (``GameConfig/claims(_:installed:)``) with a setting or an executable
    /// on record, since the loader bundle gives even an unconfigured game its
    /// name, icon and Game Mode.
    static func materializedGames(
        _ games: [Int: ConfigValues], installed: Set<Int>,
    ) -> [(appID: Int, values: ConfigValues)] {
        GameConfig.claimants(in: games, installed: installed)
            .filter { $0.value.hasSettings || $0.value.exes != nil }
            .sorted { $0.key < $1.key }
            .map { (appID: $0.key, values: $0.value) }
    }

    /// One game's lines, loader bundle and native runner variables.
    private static func gameFiles(
        appID: Int, values: ConfigValues, bottle name: String, prefix: URL, engine: Engine,
    ) -> GameFiles {
        // A recorded tool that is no game executable would start through the
        // game's bundle, with its settings, from any launch.
        let exes = (values.exes ?? []).filter(GameExecutables.isRecordable)
        var game = GameFiles(appID: appID, settings: gameLines(appID, values, bottle: name, engine: engine.root), exes: exes)
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

    /// The app whose launch last began in this process
    /// (``appFiles(_:launching:)``).
    private static let launching = Mutex<Int?>(nil)

    /// Rewrites the env file of every executable `appID` shares with another
    /// game with its own lines, so the process starting now starts as this
    /// game; later passes keep them until another claimant launches. Written
    /// ahead of the next pass because Steam starts the process within moments.
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
        /// ``gameLines(_:_:bottle:engine:)``: the game's own settings.
        var settings: [String]
        /// The lowercased executables the game has on record.
        var exes: [String]
        /// `SEVO_LOADER=…`, the bundle that is the game's Dock identity.
        var loader: String?
        /// The native runner's variables, which run the exe as this game.
        var runner: [String] = []
        /// The install folder under `steamapps/common`, as
        /// ``ConfigMaterializer/folderKey(_:)`` spells it; files under it are
        /// this game's alone.
        var folder: String?
    }

    /// The env file of every executable, by path under the apps directory,
    /// independent of the order of `games`.
    ///
    /// Games share exe names (every RPG Maker MV/MZ game ships `game.exe`). A
    /// file claimed by several games carries only the settings they all agree
    /// on, except for the claimant whose launch is in flight, which gets its
    /// full lines. A game with an install folder also gets
    /// `<folder>/<exe>.env` with its full lines.
    static func appFiles(_ games: [GameFiles], launching: Int? = nil) -> [String: [String]] {
        let ordered = games.sorted { $0.appID < $1.appID }
        var claimants: [String: [GameFiles]] = [:]
        for game in ordered {
            // A game that ships a program of the bottle's own name gets only
            // its folder's file: the bare one is read by the bottle's own
            // `steam.exe`, which would start with that game's settings.
            for exe in Set(game.exes) where !bottlePrograms.contains(exe.lowercased()) {
                claimants[exe, default: []].append(game)
            }
        }
        var files: [String: [String]] = [:]
        for game in ordered {
            guard let folder = game.folder else { continue }
            for exe in Set(game.exes) {
                // The bottle's own programs run from these folders, so a game
                // installed under one of the names gets no file for them.
                if bottlePrograms.contains(exe.lowercased()), bottleFolders.contains(folder.lowercased()) { continue }
                files["\(folder)/\(exe).env"] = ownLines(of: game, for: exe)
            }
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

    /// Programs the bottle runs for itself, by the name their env file has.
    static let bottlePrograms: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "steamservice.exe", "steamerrorreporter.exe",
        "gameoverlayui.exe", "explorer.exe", "services.exe", "winedevice.exe", "wineboot.exe",
        "rundll32.exe", "start.exe", "conhost.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
        "winemenubuilder.exe",
    ]

    /// The folders those programs run from, as a folder key spells them.
    static let bottleFolders: Set<String> = ["steam", "windows", "system32", "syswow64", "bin", "cef", "cef.win64", "cef.win7x64"]

    /// A file that is one game's alone; a companion program never takes the
    /// loader (``GameConfig/isCompanionExecutable(_:)``).
    private static func ownLines(of game: GameFiles, for exe: String) -> [String] {
        let identity = GameConfig.isCompanionExecutable(exe) ? [] : [game.loader].compactMap(\.self)
        return game.settings + game.runner + identity
    }

    /// An install folder's name with ASCII letters lowered, matching the
    /// engine's byte-wise `tolower`.
    static func folderKey(_ folder: String) -> String {
        String(folder.map { $0.isASCII ? Character($0.lowercased()) : $0 })
    }

    /// Adds the Steam Play switch (``SteamPlayMacOS``) to `steam.exe`'s file.
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

    /// Share notes already logged, each said once per process.
    private static let narratedShares = Mutex<Set<String>>([])

    private static func noteShared(_ exe: String, by appIDs: [Int], launching: Int?) {
        let note = shareNote(exe, by: appIDs, launching: launching)
        let isNew = narratedShares.withLock { $0.insert(note).inserted }
        guard isNew else { return }
        GameExecutables.log(note)
    }

    /// The log line for an exe several games ship.
    static func shareNote(_ exe: String, by appIDs: [Int], launching: Int?) -> String {
        let apps = appIDs.map(String.init).joined(separator: ", ")
        if let launching, appIDs.contains(launching) {
            return "apps \(apps) all ship \(exe): its env file carries app \(launching)'s lines, for its launch"
        }
        return "apps \(apps) all ship \(exe): its env file carries only the settings they share"
    }

    /// Writes ``DebugMode``'s own file, so turning the mode off is a deletion
    /// that leaves `bottle.env` alone.
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

    /// The `sevo` inside the app bundle.
    private static var bundledCLI: URL? {
        Bundle.main.executableURL.flatMap { cli(forExecutable: $0.resolvingSymlinksInPath()) }
    }

    /// The `sevo` inside the app enclosing `executable` (the app or its daemon
    /// in `Contents/Library/LaunchAgents`), or `executable` itself when it is
    /// a `sevo`.
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

    /// The bottle level: every resolved env setting.
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
        // For a running game's View menu.
        lines.append("SEVO_ENGINE_NAME=\(engine.recordIdentifier)")
        if let cli = bundledCLI { lines.append("SEVO_CLI=\(cli.path)") }
        let level = DiagnosticLevel.current
        lines.append("WINEDEBUG=\(level.channels())")
        lines += level.rendererLines
        // Last, so a variable set by name wins over the rows above.
        lines += UserEnvironment.lines(GameConfig.bottle(name).environment)
        return lines
    }

    /// The boolean env switches and their resolvers. The bottle writes all;
    /// a game writes those it sets, off as well as on.
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

    /// A game's file carries only what the game sets, even where it equals
    /// the bottle's value, which can change under it. `bottle` answers for
    /// the half of a paired line the game leaves unset.
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
        // Written off as well as on: an absent key keeps the bottle's value.
        if let mouse = values.mouse {
            lines.append("SEVO_LINEAR_MOUSE=\(mouse == .linear ? "1" : "0")")
        }
        // `0` is no cap, written so it overrides a bottle that caps.
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
        // `0` is no limit, written so it overrides a bottle that limits.
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

    /// The level-2 switch for an engine older than `SEVO_OVERLAY_LEVEL`; on
    /// only where the counter already is, since it also shows the counter.
    static func frameGraphLine(_ detail: OverlayDetail, counterShown: Bool) -> String {
        "SEVO_FPS_GRAPH=\(detail.showsFrameGraph && counterShown ? "1" : "0")"
    }

    /// GStreamer's decoder ranks. Hardware is an empty value, which the engine
    /// unsets, so a game asking for it overrides a bottle on software.
    static func videoDecodingLine(_ decoding: VideoDecoding) -> String {
        switch decoding {
        case .hardware: "GST_PLUGIN_FEATURE_RANK="
        case .software: "GST_PLUGIN_FEATURE_RANK=vtdec_hw:NONE,vtdec:NONE"
        }
    }

    /// A game's own renderer: the payload directory first on the dll path,
    /// builtin resolution for its DLLs, and for D3DMetal the two variables
    /// ``Engine/environment(bottle:)`` sets. Empty unless
    /// ``EngineRenderers/supportsPerGame(_:)``.
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

    /// Writes each file at its path under `dir`, making the folder of a
    /// folder-keyed one, under the header ``removeStale(in:keeping:)`` knows
    /// the app's files by.
    static func writeFiles(_ files: [String: [String]], in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (file, lines) in files {
            // A key is `<exe>.env` or `<folder>/<exe>.env`, both names from a
            // game's own files: one that climbs out of `dir` is not written.
            let parts = file.split(separator: "/", omittingEmptySubsequences: false)
            guard (1 ... 2).contains(parts.count), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else { continue }
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
        let text = ([header] + lines.map(singleLine)).joined(separator: "\n") + "\n"
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == text { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// One entry as one line. A game's or program's name goes into its file,
    /// and a line break in it would add a line of the name's choosing, past
    /// every check on which variables a file may set.
    static func singleLine(_ line: String) -> String {
        guard line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x2028 || $0.value == 0x2029 })
        else { return line }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: line.unicodeScalars.map { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029 ? " " : scalar
        })
        return String(scalars)
    }

    /// Removes our files under `dir` not in `wanted`, and folders left empty.
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

/// Runs one pass at a time per key; calls arriving during a pass share one
/// pass after it, and each returns once a pass begun after its call is done.
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
