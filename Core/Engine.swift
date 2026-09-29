import Foundation
import Synchronization

/// Which Wine runs the bottle: CrossOver's, or a managed engine Sevoflurane
/// installed itself.
///
/// Everything above this type — bottle paths inside the prefix, launch lines,
/// the kill ladder — is engine-agnostic; the differences live entirely in how
/// a wine invocation is assembled (`CrossOver's wrapper takes `--bottle`,
/// plain WineHQ is driven by `WINEPREFIX`) and where bottles live on disk.
nonisolated enum Engine: Equatable, Sendable, CustomStringConvertible {
    case crossover
    /// CodeWeavers' preview app, installed alongside stable CrossOver. It
    /// keeps its own bottle directory when it has made one; adopting stable
    /// bottles is an opt-in inside Preview's UI, never something this app
    /// migrates.
    case crossoverPreview
    /// A managed engine under ``managedRoot``, one directory per version
    /// (layout produced by `dormison/build-macos/package-engine.sh`).
    case managed(version: String)

    /// Both CodeWeavers apps: bottles carry `cxbottle.conf`, invocations
    /// take `--bottle`, and the Windows user inside is `crossover`.
    var isCrossOver: Bool {
        switch self {
        case .crossover, .crossoverPreview: true
        case .managed: false
        }
    }

    /// Managed engines, one directory per version:
    /// `wine/` (WineHQ tree), `dxvk/`, `dxmt/`, `d3dmetal/`, the dock shim
    /// and the Steamworks stub.
    static let managedRoot = AppIdentity.supportFolder
        .appendingPathComponent("Engines")

    /// Where managed engines keep their bottles (plain `WINEPREFIX` trees).
    static let managedBottlesRoot = AppIdentity.supportFolder
        .appendingPathComponent("Bottles")

    /// The engine every wine invocation routes through. Resolved from disk on
    /// first use (so the CLI needs no entry-point ceremony); the app reasserts
    /// it whenever a full detection lands. Read from every actor and from
    /// `@concurrent` work, so the value is kept under a lock; resolution runs
    /// outside it, and two first readers that race both resolve and store the
    /// same answer.
    static var active: Engine {
        get {
            if let engine = resolved.withLock({ $0 }) { return engine }
            let engine = resolveFromDisk()
            resolved.withLock { $0 = engine }
            return engine
        }
        set { resolved.withLock { $0 = newValue } }
    }

    private static let resolved = Mutex<Engine?>(nil)

    /// The user's explicit choice first (Settings › Engine, validated
    /// against what's actually on disk); otherwise CrossOver (its Steam/CEF
    /// fixes exist in no OSS binary — SPEC "Engine strategy"), then the
    /// newest managed engine.
    static func resolve(from detection: SetupDetection) -> Engine {
        if let chosen = preferred(), chosen.existsOnDisk {
            return chosen
        }
        if detection.usableCrossOver != nil {
            return .crossover
        }
        if let newest = detection.managedEngineVersions.last {
            return .managed(version: newest)
        }
        return .crossover
    }

    /// The synchronous subset of ``SetupProbe/detect()`` that decides the
    /// engine: the stored choice, CrossOver's license state, the
    /// managed-engine directory. Uncached: ``active`` keeps the first answer
    /// for the life of the process, and this is how a long-lived process sees
    /// an engine installed after it started.
    static func resolveFromDisk() -> Engine {
        if let chosen = preferred(), chosen.existsOnDisk {
            return chosen
        }
        let usableCrossOver = SetupProbe.crossoverInfo()
            .map { $0.licensed || !$0.trialExpired } ?? false
        if usableCrossOver {
            return .crossover
        }
        if let newest = SetupProbe.managedEngineVersions().last {
            return .managed(version: newest)
        }
        return .crossover
    }

    // MARK: - The stored choice

    private static let preferenceKey = "engine"

    /// Names this engine as the one every invocation routes through, now and
    /// on every future launch. Both faces read the shared suite, so `sevo`
    /// and the app never drive different engines. The client is restarted
    /// around it, like a bottle change.
    static func choose(_ engine: Engine) {
        Preferences.shared.set(engine.preferenceValue, forKey: preferenceKey)
        active = engine
    }

    /// After the app installs a newer release or beta engine: a stored choice
    /// that names an older one (`managed:dormison-b1`) moves to it, so the
    /// client's next start runs what the app carries, and this process's
    /// ``active`` moves with it. A hand-picked build (`dormison-b1-tray`),
    /// CrossOver, or a bare `managed` stays as it is. Answers whether the
    /// choice moved.
    @discardableResult
    static func adoptNewerRelease(_ version: String) -> Bool {
        guard let adopted = adoptedChoice(stored: Preferences.shared.string(forKey: preferenceKey), installed: version)
        else { return false }
        Preferences.shared.set(adopted, forKey: preferenceKey)
        active = .managed(version: version)
        return true
    }

    /// The stored choice after installing release or beta `version`, or nil
    /// when the stored one stays.
    static func adoptedChoice(stored: String?, installed version: String) -> String? {
        guard let stored, stored.hasPrefix(managedPrefix) else { return nil }
        let old = String(stored.dropFirst(managedPrefix.count))
        guard isReleaseName(old), isReleaseName(version), isOlderVersion(old, than: version)
        else { return nil }
        return managedPrefix + version
    }

    /// The engine the bottle's processes run on: the one the client booted
    /// from, which is the engine a game started now runs on. ``active`` can
    /// already name the next restart's engine — an install adopted a newer
    /// release, a switch waits for its restart — so it answers only when no
    /// boot is on record.
    static var running: Engine {
        running(bootedRoot: BottleGraphics.bootedEngineRoot(), active: active)
    }

    static func running(bootedRoot: String?, active: Engine) -> Engine {
        bootedRoot.flatMap(booted(fromRoot:)) ?? active
    }

    /// Whether `version` names a published engine: a release `dormison-r<N>`
    /// or a beta `dormison-b<N>`, and not a build named after one
    /// (`dormison-b1-tray`).
    static func isReleaseName(_ version: String) -> Bool {
        version.wholeMatch(of: /dormison-[rb]\d+/) != nil
    }

    /// Orders managed engine names the way they were published: `dormison-r9`
    /// before `dormison-r10`, and a beta after the release before it and
    /// before its own release, `dormison-r10` < `dormison-b11` <
    /// `dormison-r11`. A build named after one sorts right after it, and any
    /// other name compares its runs of digits as numbers.
    static func isOlderVersion(_ lhs: String, than rhs: String) -> Bool {
        orderingKey(lhs).localizedStandardCompare(orderingKey(rhs)) == .orderedAscending
    }

    /// `dormison-11.0` for the beta `dormison-b11` and `dormison-11.1` for the
    /// release, so digit-aware comparison puts a beta before its release
    /// whatever the letters would say; the rest of the name follows unchanged.
    private static func orderingKey(_ version: String) -> String {
        guard let match = version.prefixMatch(of: /dormison-([rb])(\d+)/) else { return version }
        let stage = match.1 == "r" ? 1 : 0
        return "dormison-\(match.2).\(stage)" + version[match.range.upperBound...]
    }

    /// The stored form of the choice. A managed engine is stored by its
    /// directory name (`managed:<version>`), so the Engine pane can pick any
    /// installed build — a Gcenx release, a sevo-wine candidate, a hand-built
    /// experiment — and that exact one boots. `managed` alone is "whichever
    /// built-in engine fits", the form a not-yet-installed choice takes.
    var preferenceValue: String {
        switch self {
        case .crossover: "crossover"
        case .crossoverPreview: "crossover-preview"
        case let .managed(version):
            version.isEmpty ? "managed" : "managed:\(version)"
        }
    }

    private static let managedPrefix = "managed:"

    /// The stored choice as a runnable engine, or `nil` when nothing is
    /// stored or the chosen engine isn't on disk (managed chosen but never
    /// installed, a deleted app) — those fall to policy. A named managed
    /// engine wins as long as its directory exists; a bare `managed`, or a
    /// name whose directory is gone (an engine update replaced it) or that
    /// names no folder of ``managedRoot``, follows the renderer, so the
    /// engine that can host the chosen renderer boots.
    static func preferred() -> Engine? {
        guard let stored = Preferences.shared.string(forKey: preferenceKey) else { return nil }
        switch stored {
        case "crossover": return .crossover
        case "crossover-preview": return .crossoverPreview
        case "managed": return managedEngine(hosting: BottleGraphics.managedSelection().renderer)
        default:
            guard stored.hasPrefix(managedPrefix) else { return nil }
            if let named = try? Engine.named(String(stored.dropFirst(managedPrefix.count))),
               named.existsOnDisk {
                return named
            }
            return managedEngine(hosting: BottleGraphics.managedSelection().renderer)
        }
    }

    // MARK: - Naming an engine

    /// Why a name selects no engine.
    struct NameRefusal: Error, Equatable, CustomStringConvertible {
        let name: String

        var description: String {
            "\"\(name)\" is not an engine name: a managed engine is one folder inside "
                + "\(Engine.managedRoot.path), named without /, NUL, . or .."
        }
    }

    /// The engine a caller outside this process names: `sevo engine use`, the
    /// MCP tool, the control port's `/engine/use` and the stored choice.
    /// CrossOver goes by its short id, a managed engine by its folder name.
    /// Whether that engine is installed is ``existsOnDisk``'s question.
    static func named(_ name: String) throws(NameRefusal) -> Engine {
        switch name {
        case "crossover": return .crossover
        case "crossover-preview": return .crossoverPreview
        default:
            guard isManagedName(name) else { throw NameRefusal(name: name) }
            return .managed(version: name)
        }
    }

    /// Whether `name` can be a folder directly inside ``managedRoot``: one
    /// non-empty path component, not `.` or `..`, with no `/` and no NUL.
    static func isManagedName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// `name`'s folder inside `root`, every symbolic link resolved; nil when
    /// the name is not one path component, the folder does not exist, or it
    /// resolves anywhere but directly inside the resolved `root`.
    static func managedDirectory(_ name: String, in root: URL = managedRoot) -> URL? {
        guard isManagedName(name),
              let resolvedRoot = resolvedPath(root.path),
              let resolved = resolvedPath(root.appendingPathComponent(name).path),
              (resolved as NSString).deletingLastPathComponent == resolvedRoot
        else { return nil }
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    /// `realpath(3)`: Foundation's own resolution maps `/private/var` to
    /// `/var`, which would move a path out of a root it resolved the other
    /// way.
    private static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The installed managed engine that can host `renderer` — the newest
    /// among those that declare it, the newest overall otherwise (an engine
    /// that predates the declaration hosts the classic staging set).
    /// "Newest" is the last directory name in sort order, so this is only
    /// the fallback for an unnamed choice; a named engine is exact.
    static func managedEngine(hosting renderer: Renderer) -> Engine? {
        let candidates = SetupProbe.managedEngineVersions()
            .map { Engine.managed(version: $0) }
        return candidates.last { $0.supportedRenderers.contains(renderer) }
            ?? candidates.last
    }

    /// Forgets the resolved engine so the next access re-reads preferences
    /// and disk — the renderer selection is part of managed resolution, so
    /// its writers call this.
    static func refreshResolution() {
        resolved.withLock { $0 = nil }
    }

    /// What this engine can render through. CrossOver hosts everything; a
    /// managed engine declares its set in `engine-info.json` ("renderers"),
    /// and one that predates the field is the classic wine-staging build
    /// with the DXMT/DXVK payloads.
    var supportedRenderers: [Renderer] {
        switch self {
        case .crossover, .crossoverPreview:
            return Renderer.allCases
        case .managed:
            if let declared = engineInfo?["renderers"] as? [String] {
                return declared.compactMap(Renderer.init(rawValue:))
            }
            return [.auto, .dxmt, .dxvk, .wined3d]
        }
    }

    /// A managed engine's `engine-info.json`, written by `package-engine.sh`;
    /// `nil` for CrossOver or an engine without the file.
    private var engineInfo: [String: Any]? {
        guard case .managed = self else { return nil }
        let info = root.appendingPathComponent("engine-info.json")
        guard let data = try? Data(contentsOf: info) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Whether the engine reads `<prefix>/.sevo/bottle.env` and
    /// `<prefix>/.sevo/apps/<exe>.env` at process start (dormison
    /// ntdll `load_sevo_env`; declared as `env-files` in `engine-info.json`).
    /// With it, a setting reaches a game at its next launch; without it, the
    /// game inherits the client's environment and waits for a Steam restart.
    var supportsEnvFiles: Bool {
        (engineInfo?["features"] as? [String])?.contains("env-files") == true
    }

    /// The relay that serves `\\.\pipe\discord-ipc-0` inside the bottle and
    /// carries it to the Discord client's socket on macOS, so a game that
    /// ships discord-rpc or the Game SDK reaches Discord with its own artwork
    /// and buttons. `nil` for CrossOver and for an engine built before the
    /// bridge, where the app's own presence is all there is.
    var discordBridge: URL? {
        guard case .managed = self else { return nil }
        let bridge = root.appendingPathComponent("sevo-discord-bridge.exe")
        return FileManager.default.fileExists(atPath: bridge.path) ? bridge : nil
    }

    /// Whether the stored choice asks for the built-in engine, installed or
    /// not — provisioning reads this to know an install is wanted even with
    /// a usable CrossOver on the machine.
    static var preferenceWantsManaged: Bool {
        Preferences.shared.string(forKey: preferenceKey)?.hasPrefix("managed") == true
    }

    /// Whether the engine's own binaries are still where the choice left
    /// them — a stored choice pointing at a deleted app must lose to policy.
    /// A managed engine exists only as a folder of ``managedRoot``
    /// (``managedDirectory(_:in:)``), whatever its name spells.
    var existsOnDisk: Bool {
        switch self {
        case .crossover, .crossoverPreview:
            crossoverBin.map { FileManager.default.fileExists(atPath: $0) } ?? false
        case let .managed(version):
            Self.managedDirectory(version).map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("wine/bin").path)
            } ?? false
        }
    }

    var description: String {
        switch self {
        case .crossover: "CrossOver"
        case .crossoverPreview: "CrossOver Preview"
        case let .managed(version):
            version.isEmpty ? "Dormison" : Self.managedDisplayName(version)
        }
    }

    /// The release number of a managed engine, `11` for `dormison-r11` and for
    /// the beta `dormison-b11` that precedes it; nil for CrossOver and for a
    /// managed directory named another way.
    var managedRelease: Int? {
        guard case let .managed(version) = self, version.hasPrefix("dormison-") else { return nil }
        let tag = version.dropFirst("dormison-".count)
        guard let kind = tag.first, kind == "r" || kind == "b" else { return nil }
        return Int(tag.dropFirst())
    }

    /// Whether winebus keeps its SDL backend. Dormison's SDL bus polls instead
    /// of waking every millisecond, and it is the backend that delivers an Xbox
    /// Wireless Controller over Bluetooth to a game; the IOHID backend alone
    /// never does. Other engines' SDL bus wakes every millisecond, about 2.6 %
    /// CPU at idle, so they run without it.
    var keepsSDLBus: Bool {
        managedRelease != nil
    }

    /// "Dormison b1" for the engine directory `dormison-b1`, "Dormison r3"
    /// for `dormison-r3`.
    static func managedDisplayName(_ version: String) -> String {
        version.hasPrefix("dormison-")
            ? "Dormison \(version.dropFirst("dormison-".count))"
            : "Dormison \(version)"
    }

    /// How a run record names this engine: the managed directory's version
    /// (`dormison-r7`) or the CodeWeavers app's short id. It is matched against
    /// an issue, so it keeps the directory name the display form prettifies.
    var recordIdentifier: String {
        switch self {
        case .crossover: "crossover"
        case .crossoverPreview: "crossover-preview"
        case let .managed(version): version
        }
    }

    /// The engine a boot record's root path names, reversing ``root``: the
    /// wineserver a game inherited was booted from this directory, which is the
    /// engine that actually ran it. `nil` when the path matches no engine.
    static func booted(fromRoot path: String) -> Engine? {
        if path.hasPrefix(managedRoot.path + "/") {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return isManagedName(name) ? .managed(version: name) : nil
        }
        for engine: Engine in [.crossover, .crossoverPreview] where engine.root.path == path {
            return engine
        }
        return nil
    }

    // MARK: - Paths

    /// The CodeWeavers app this engine runs out of; `nil` for managed.
    var crossoverApp: URL? {
        switch self {
        case .crossover: URL(fileURLWithPath: "/Applications/CrossOver.app")
        case .crossoverPreview: URL(fileURLWithPath: "/Applications/CrossOver Preview.app")
        case .managed: nil
        }
    }

    /// The CLI tools (wine, wineserver, cxbottle) inside that app.
    var crossoverBin: String? {
        crossoverApp.map { $0.path + "/Contents/SharedSupport/CrossOver/bin" }
    }

    /// The engine's own directory (the CrossOver tree, or the versioned
    /// managed directory).
    var root: URL {
        switch self {
        case .crossover, .crossoverPreview:
            URL(fileURLWithPath: crossoverBin ?? "").deletingLastPathComponent()
        case let .managed(version):
            Self.managedRoot.appendingPathComponent(version)
        }
    }

    /// Preview's own bottle directory, which it creates the first time it
    /// makes (or adopts) a bottle of its own.
    static let previewBottlesRoot = UserHome.url
        .appendingPathComponent("Library/Application Support/CrossOver Preview/Bottles")

    /// Where this engine's bottles live. CrossOver bottles stay in
    /// CrossOver's directory so the user's existing installation is adopted,
    /// never migrated; Preview reads its own directory when one exists and
    /// the shared one otherwise.
    var bottlesRoot: URL {
        switch self {
        case .crossover:
            SteamBottle.bottlesRoot
        case .crossoverPreview:
            FileManager.default.fileExists(atPath: Self.previewBottlesRoot.path)
                ? Self.previewBottlesRoot : SteamBottle.bottlesRoot
        case .managed:
            Self.managedBottlesRoot
        }
    }

    var wineURL: URL {
        switch self {
        case .crossover:
            // Through the shadow tree when the user has pinned a D3DMetal of
            // their own, so CrossOver's launcher computes its graphics paths
            // inside ours. Its own launcher otherwise, unchanged.
            return CrossOverShadow.preparedLauncher()
                ?? URL(fileURLWithPath: (crossoverBin ?? "") + "/wine")
        case .crossoverPreview:
            // The shadow tree mirrors the stable app only; Preview runs its
            // own launcher untouched.
            return URL(fileURLWithPath: (crossoverBin ?? "") + "/wine")
        case .managed:
            let bin = root.appendingPathComponent("wine/bin")
            let wine64 = bin.appendingPathComponent("wine64")
            return FileManager.default.fileExists(atPath: wine64.path)
                ? wine64 : bin.appendingPathComponent("wine")
        }
    }

    /// The unix loader a managed engine starts every Windows program with —
    /// the binary ntdll's `wineloader` names, and the one a game's own bundle
    /// carries a copy of (``GameLaunchers``). `nil` for CrossOver, whose tree
    /// is not ours to copy out of.
    var unixLoader: URL? {
        guard case .managed = self else { return nil }
        let loader = root.appendingPathComponent("wine/lib/wine/x86_64-unix/wine")
        return FileManager.default.isExecutableFile(atPath: loader.path) ? loader : nil
    }

    var wineserverURL: URL {
        switch self {
        case .crossover, .crossoverPreview:
            URL(fileURLWithPath: (crossoverBin ?? "") + "/wineserver")
        case .managed:
            root.appendingPathComponent("wine/bin/wineserver")
        }
    }

    /// CEF needs its GPU process disabled under plain Wine or the client's
    /// windows render black. `steam.exe` forwards these to steamwebhelper
    /// itself — `-cef-disable-gpu` expands to `--disable-gpu`,
    /// `--disable-gpu-compositing` and `--in-process-gpu`, and
    /// `-cef-disable-sandbox` to `--no-sandbox` (measured on a clean
    /// machine). CrossOver's own wine already injects the same set, so it
    /// needs nothing here.
    ///
    /// Passing them on Steam's own command line is what makes this durable:
    /// the client's bootstrapper verifies and restores its files on every
    /// start, so anything that patches steamwebhelper.exe is reverted before
    /// it ever runs.
    var cefArguments: [String] {
        switch self {
        case .crossover, .crossoverPreview:
            []
        case .managed:
            ["-cef-disable-gpu", "-cef-disable-sandbox"]
        }
    }

    // MARK: - Invocation assembly

    /// How long the launcher lingers after starting the program.
    enum Wait: Sendable {
        /// Return as soon as the program is started (CrossOver `--no-wait`;
        /// plain wine approximates it — the caller must not await the exit).
        case none
        /// Wait for the program and everything it spawns (CrossOver
        /// `--wait-children`). Plain wine only waits for the direct child, so
        /// managed-engine callers judge by what landed on disk, not by exit.
        case children
    }

    /// A ready-to-run wine invocation for a program inside a bottle.
    func wineInvocation(
        bottle: String, wait: Wait, program: [String],
    ) -> (executable: URL, arguments: [String], environment: [String: String]?) {
        switch self {
        case .crossover, .crossoverPreview:
            let flag = switch wait {
            case .none: "--no-wait"
            case .children: "--wait-children"
            }
            return (wineURL, ["--bottle", bottle, flag] + program, nil)
        case .managed:
            return (wineURL, program, environment(bottle: bottle))
        }
    }

    /// The env a managed-engine invocation needs: `WINEPREFIX` addressing,
    /// sync primitives, and the renderer's DLL overrides. CrossOver assembles
    /// all of this itself from `cxbottle.conf`.
    func environment(bottle: String) -> [String: String] {
        var env = [
            "WINEPREFIX": bottlesRoot.appendingPathComponent(bottle).path,
            "PATH": wineURL.deletingLastPathComponent().path + ":/usr/bin:/bin",
            "WINEDEBUG": WineLog.channels,
        ]
        // The process the prefix cannot outlive (``BottleOwner``). A managed
        // spawn is handed an environment rather than inheriting one, so the
        // owner has to be copied in by hand here.
        if let owner = BottleOwner.pid {
            env[BottleOwner.variable] = owner
        }
        // Keeps Steam's own processes out of the Dock and off the screen:
        // winemac.drv promotes any wine process that shows a window, and
        // there is no demotion API — so the promotion and the window
        // ordering are both taken away from Steam's infrastructure
        // (dormison/build-macos/dock-shim). The shim decides per process by the Windows exe
        // name, so a game keeps the Dock promotion and orders its windows
        // normally; the suppression flag rides on every managed spawn
        // because a spawn that forgets it is a bare Wine window on screen.
        // Ships inside the engine; an engine without it just gets the Dock
        // icon and the windows back.
        let dockShim = root.appendingPathComponent("libsevodockshim.dylib")
        if FileManager.default.fileExists(atPath: dockShim.path) {
            env["DYLD_INSERT_LIBRARIES"] = dockShim.path
            env["SEVO_SUPPRESS_WINDOWS"] = "1"
        }
        // The bottle's window treatment (dormison winemac.drv,
        // `ResizableWindows`). An engine with the env files reads the same
        // value, and a game's own, from `<prefix>/.sevo` at every process
        // start; one without inherits this from the client, so a change
        // reaches its games once Steam restarts.
        env["SEVO_RESIZABLE_WINDOWS"] = GameConfig.windows(bottle: bottle).value.rawValue
        // The presenter's upscaler and its final filter, same contract; the
        // shader directory is where a package named by the upscaler lives.
        env["SEVO_UPSCALER"] = GameConfig.upscaler(bottle: bottle).value
        env["SEVO_FINAL_FILTER"] = GameConfig.filter(bottle: bottle).value.rawValue
        env["SEVO_SHADER_DIR"] = ShaderPackages.root.path
        let graphics = BottleGraphics.managedSelection()
        if graphics.msync {
            // The Whisky-documented quirk: msync must ride with esync or
            // D3DMetal deadlocks (SPEC "Engine strategy").
            env["WINEMSYNC"] = "1"
            env["WINEESYNC"] = "1"
        }
        if let overrides = graphics.renderer.managedDLLOverrides {
            env["WINEDLLOVERRIDES"] = overrides
        }
        if graphics.renderer == .d3dmetal {
            // The tree's copy, which staging fills with the picked version:
            // the `.so` stubs a game loads are symlinks to this same file, so
            // ntdll's early dlopen and the game's stubs share one image —
            // one dispatch table, one code range for the ms_abi trampoline.
            // Never point this at the toolkit's own copy: a second image
            // means a second dispatch table.
            let sharedLib = D3DMetalInstaller.bridgeLibrary(inEngine: root)
            if FileManager.default.fileExists(atPath: sharedLib.path) {
                env["SEVO_LIBD3DSHARED_PATH"] = sharedLib.path
            }
            env["D3DM_WINE_UNIX_CALL"] = "1"
        }
        env.merge(BottleGraphics.translationDefaults) { current, _ in current }
        env.merge(graphics.gpu.environment.filter { !$0.value.isEmpty }) { current, _ in current }
        return env
    }
}
