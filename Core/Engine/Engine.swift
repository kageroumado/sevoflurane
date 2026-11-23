import Foundation
import Synchronization

/// Which Wine runs the bottle: CrossOver's, or a managed engine Sevoflurane
/// installed itself.
///
/// The engines differ only in how a wine invocation is assembled (CrossOver's
/// wrapper takes `--bottle`, plain WineHQ reads `WINEPREFIX`) and where
/// bottles live on disk.
nonisolated enum Engine: Equatable, Sendable, CustomStringConvertible {
    case crossover
    /// CodeWeavers' preview app, beside stable CrossOver, with its own bottle
    /// directory once it has made one.
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

    /// Managed engines, one directory per version: `wine/`, `dxvk/`, `dxmt/`,
    /// `d3dmetal/`, the dock shim and the Steamworks stub.
    static let managedRoot = AppIdentity.supportFolder
        .appendingPathComponent("Engines")

    /// Where managed engines keep their bottles (plain `WINEPREFIX` trees).
    static let managedBottlesRoot = AppIdentity.supportFolder
        .appendingPathComponent("Bottles")

    /// The engine every wine invocation routes through, resolved from disk on
    /// first use; the app reasserts it whenever a full detection lands. Kept
    /// under a lock because every actor reads it; resolution runs outside the
    /// lock, so two racing first readers both store the same answer.
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

    /// The user's choice when it is on disk; otherwise a usable CrossOver
    /// (SPEC "Engine strategy"), then the newest managed engine.
    static func resolve(from detection: SetupDetection) -> Engine {
        if let chosen = preferred(), chosen.existsOnDisk, chosen.runsHere {
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

    /// ``resolve(from:)`` read synchronously from disk, uncached, so a
    /// long-lived process sees an engine installed after it started.
    static func resolveFromDisk() -> Engine {
        if let chosen = preferred(), chosen.existsOnDisk, chosen.runsHere {
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

    /// Stores the choice in the shared suite, which `sevo` and the app both
    /// read, and makes it ``active``.
    static func choose(_ engine: Engine) {
        Preferences.shared.set(engine.preferenceValue, forKey: preferenceKey)
        active = engine
    }

    /// Stores the first-run assistant's answer and moves ``active`` to it.
    /// With no Dormison installed yet, ``active`` is a versionless managed
    /// engine until the engine stage installs one. A stored choice of the
    /// same kind stays, so a hand-picked build survives a second run.
    static func chooseAtSetup(managed: Bool) {
        let stored = Preferences.shared.string(forKey: preferenceKey)
        if stored == nil || managed != preferenceWantsManaged {
            Preferences.shared.set(managed ? "managed" : "crossover", forKey: preferenceKey)
        }
        active = preferred() ?? (managed ? .managed(version: "") : .crossover)
    }

    /// The engine the first-run assistant starts on: the stored choice, else
    /// CrossOver where Steam is already set up in a CrossOver bottle, else
    /// Dormison.
    static var setupStartsOnCrossOver: Bool {
        let usable = SetupProbe.crossoverInfo().map { $0.licensed || !$0.trialExpired } ?? false
        return SetupFlow.startsOnCrossOver(
            hasUsableCrossOver: usable,
            storedChoiceIsManaged: storedChoiceIsManaged,
            steamIsInCrossOver: SetupProbe.bottles(for: .crossover).contains { $0.name == SteamBottle.name && $0.hasSteam },
        )
    }

    /// The stored choice's kind: the built-in engine, CrossOver, or none.
    static var storedChoiceIsManaged: Bool? {
        Preferences.shared.string(forKey: preferenceKey).map { $0.hasPrefix("managed") }
    }

    /// Moves a stored choice naming an older release or beta
    /// (`managed:dormison-b1`) to the newly installed `version`. A hand-picked
    /// build (`dormison-b1-tray`), CrossOver or a bare `managed` stays.
    /// Answers whether the choice moved.
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

    /// The engine the client booted from, which a game started now runs on.
    /// ``active`` can already name the next restart's engine, so it answers
    /// only when no boot is on record.
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

    /// Publication order: `dormison-r9` < `dormison-r10` < `dormison-b11` <
    /// `dormison-r11`. A build named after one sorts right after it; other
    /// names compare runs of digits as numbers.
    static func isOlderVersion(_ lhs: String, than rhs: String) -> Bool {
        orderingKey(lhs).localizedStandardCompare(orderingKey(rhs)) == .orderedAscending
    }

    /// `dormison-11.0` for `dormison-b11` and `dormison-11.1` for
    /// `dormison-r11`, so a beta sorts before its release.
    private static func orderingKey(_ version: String) -> String {
        guard let match = version.prefixMatch(of: /dormison-([rb])(\d+)/) else { return version }
        let stage = match.1 == "r" ? 1 : 0
        return "dormison-\(match.2).\(stage)" + version[match.range.upperBound...]
    }

    /// The stored form: `managed:<directory>` boots that exact build, and
    /// `managed` alone means whichever installed engine fits.
    var preferenceValue: String {
        switch self {
        case .crossover: "crossover"
        case .crossoverPreview: "crossover-preview"
        case let .managed(version):
            version.isEmpty ? "managed" : "managed:\(version)"
        }
    }

    private static let managedPrefix = "managed:"

    /// The stored choice as a runnable engine, or `nil` when nothing usable is
    /// stored, which leaves the choice to policy. A named managed engine wins
    /// while its directory exists; a bare `managed`, or a name with no folder
    /// in ``managedRoot``, follows the renderer, so the engine that can host
    /// the chosen renderer boots.
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

    /// The engine a name selects: CrossOver by its short id, a managed engine
    /// by its folder name. Installation is ``existsOnDisk``'s question.
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

    /// `name`'s folder inside `root`, links resolved; nil unless it exists and
    /// resolves directly inside the resolved `root`.
    static func managedDirectory(_ name: String, in root: URL = managedRoot) -> URL? {
        guard isManagedName(name),
              let resolvedRoot = resolvedPath(root.path),
              let resolved = resolvedPath(root.appendingPathComponent(name).path),
              (resolved as NSString).deletingLastPathComponent == resolvedRoot
        else { return nil }
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    /// `realpath(3)`: Foundation maps `/private/var` to `/var`, which would
    /// move a path out of a root resolved the other way.
    private static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The newest installed managed engine that hosts `renderer`, else the
    /// newest overall; the fallback for an unnamed choice.
    static func managedEngine(hosting renderer: Renderer) -> Engine? {
        let candidates = SetupProbe.managedEngineVersions()
            .map { Engine.managed(version: $0) }
        return candidates.last { $0.supportedRenderers.contains(renderer) }
            ?? candidates.last
    }

    /// Forgets the resolved engine; renderer writers call this, since the
    /// renderer is part of managed resolution.
    static func refreshResolution() {
        resolved.withLock { $0 = nil }
    }

    /// What this engine can render through: everything for CrossOver, the
    /// `renderers` of a managed engine's `engine-info.json`, and the classic
    /// staging set for one without the field.
    var supportedRenderers: [Renderer] {
        let hostable = Renderer.hostable()
        switch self {
        case .crossover, .crossoverPreview:
            return hostable
        case .managed:
            if let declared = engineInfo?["renderers"] as? [String] {
                return declared.compactMap(Renderer.init(rawValue:)).filter(hostable.contains)
            }
            return [.auto, .dxmt, .dxvk, .wined3d]
        }
    }

    /// A managed engine's `engine-info.json`, written by `package-engine.sh`.
    private var engineInfo: [String: Any]? {
        guard case .managed = self else { return nil }
        let info = root.appendingPathComponent("engine-info.json")
        guard let data = try? Data(contentsOf: info) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Whether the engine reads `<prefix>/.sevo/bottle.env` and
    /// `<prefix>/.sevo/apps/<exe>.env` at process start (dormison ntdll
    /// `load_sevo_env`, declared as `env-files`); without it a setting waits
    /// for a Steam restart.
    var supportsEnvFiles: Bool {
        features.contains("env-files")
    }

    /// The `features` a managed engine's `engine-info.json` declares.
    var features: [String] {
        engineInfo.map(Self.features(inEngineInfo:)) ?? []
    }

    /// The `features` an `engine-info.json` declares.
    static func features(inEngineInfo info: [String: Any]) -> [String] {
        info["features"] as? [String] ?? []
    }

    /// The relay that carries `\\.\pipe\discord-ipc-0` inside the bottle to
    /// the Discord client's socket on macOS, for games that ship discord-rpc
    /// or the Game SDK. `nil` for an engine without it.
    var discordBridge: URL? {
        guard case .managed = self else { return nil }
        let bridge = root.appendingPathComponent("sevo-discord-bridge.exe")
        return FileManager.default.fileExists(atPath: bridge.path) ? bridge : nil
    }

    /// The engine's own frame-rate unlocker for Genshin Impact, with its stub
    /// DLL beside it (Dormison's `build-macos/fps-unlock`).
    static let fpsUnlockerName = "sevo-fpsunlock.exe"

    /// The engine's frame-rate unlocker, or `nil` for an engine without it.
    var fpsUnlocker: URL? {
        guard case .managed = self else { return nil }
        let unlocker = root.appendingPathComponent(Self.fpsUnlockerName)
        return FileManager.default.fileExists(atPath: unlocker.path) ? unlocker : nil
    }

    /// Whether the stored choice asks for the built-in engine, installed or
    /// not, so provisioning installs one even beside a usable CrossOver.
    static var preferenceWantsManaged: Bool {
        Preferences.shared.string(forKey: preferenceKey)?.hasPrefix("managed") == true
    }

    /// Whether this Mac can run the engine's wineserver. CrossOver installs
    /// for the Mac it is on, so only a managed engine can be the wrong build.
    var runsHere: Bool {
        guard case let .managed(version) = self, let root = Self.managedDirectory(version) else { return true }
        return Self.serverRuns(inEngineAt: root)
    }

    /// An Intel Mac needs an x86_64 wineserver slice; Apple silicon runs
    /// either. An unreadable header counts as runnable, so the launch's own
    /// failure names the file.
    static func serverRuns(inEngineAt root: URL, appleSilicon: Bool = MacHardware.isAppleSilicon) -> Bool {
        guard !appleSilicon else { return true }
        guard let types = MachOIdentity.cpuTypes(ofFile: root.appendingPathComponent("wine/bin/wineserver"))
        else { return true }
        return types.contains(CPU_TYPE_X86_64)
    }

    /// What ``EngineInstaller`` and `engine use` say about an engine
    /// ``runsHere`` refuses.
    static func intelRefusal(_ version: String) -> String {
        String(localized: "\(version) has an Apple silicon wineserver only, so it cannot run on this Intel Mac. Dormison r10 and later run on Intel.")
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

    /// `11` for `dormison-r11` and `dormison-b11`; nil for other names.
    var managedRelease: Int? {
        guard case let .managed(version) = self, version.hasPrefix("dormison-") else { return nil }
        let tag = version.dropFirst("dormison-".count)
        guard let kind = tag.first, kind == "r" || kind == "b" else { return nil }
        return Int(tag.dropFirst())
    }

    /// Whether winebus keeps its SDL backend, the only one that delivers an
    /// Xbox Wireless Controller over Bluetooth. Every Dormison build's SDL bus
    /// polls; other engines' wakes every millisecond (about 2.6 % CPU idle),
    /// so they run without it.
    var keepsSDLBus: Bool {
        guard case let .managed(version) = self else { return false }
        return version.hasPrefix("dormison-")
    }

    /// "Dormison b1" for the directory `dormison-b1`.
    static func managedDisplayName(_ version: String) -> String {
        version.hasPrefix("dormison-")
            ? "Dormison \(version.dropFirst("dormison-".count))"
            : "Dormison \(version)"
    }

    /// How a run record names this engine: the directory name (`dormison-r7`)
    /// or CrossOver's short id, unprettified so issues can match it.
    var recordIdentifier: String {
        switch self {
        case .crossover: "crossover"
        case .crossoverPreview: "crossover-preview"
        case let .managed(version): version
        }
    }

    /// The engine a boot record's root path names, reversing ``root``.
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

    /// The CrossOver tree or the versioned managed directory.
    var root: URL {
        switch self {
        case .crossover, .crossoverPreview:
            URL(fileURLWithPath: crossoverBin ?? "").deletingLastPathComponent()
        case let .managed(version):
            Self.managedRoot.appendingPathComponent(version)
        }
    }

    /// Preview's own bottle directory, created with its first bottle.
    static let previewBottlesRoot = UserHome.url
        .appendingPathComponent("Library/Application Support/CrossOver Preview/Bottles")

    /// Where this engine's bottles live: CrossOver's own directory, so an
    /// existing installation is adopted in place; Preview's own when it
    /// exists, the shared one otherwise.
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
            // The shadow tree when the user pinned a D3DMetal of their own.
            return CrossOverShadow.preparedLauncher()
                ?? URL(fileURLWithPath: (crossoverBin ?? "") + "/wine")
        case .crossoverPreview:
            // The shadow tree mirrors the stable app only.
            return URL(fileURLWithPath: (crossoverBin ?? "") + "/wine")
        case .managed:
            let bin = root.appendingPathComponent("wine/bin")
            let wine64 = bin.appendingPathComponent("wine64")
            return FileManager.default.fileExists(atPath: wine64.path)
                ? wine64 : bin.appendingPathComponent("wine")
        }
    }

    /// The unix loader ntdll's `wineloader` names, which a game's bundle
    /// copies (``GameLaunchers``). `nil` for CrossOver.
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
    /// windows render black. `steam.exe` forwards these to steamwebhelper:
    /// `-cef-disable-gpu` expands to `--disable-gpu`,
    /// `--disable-gpu-compositing` and `--in-process-gpu`, and
    /// `-cef-disable-sandbox` to `--no-sandbox`. CrossOver injects the same
    /// set itself.
    ///
    /// Never patch steamwebhelper.exe for this: the bootstrapper restores its
    /// files on every start, so only Steam's own command line is durable.
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
        /// Return once the program starts (CrossOver `--no-wait`).
        case none
        /// Wait for the program and its children (CrossOver
        /// `--wait-children`); plain wine waits for the direct child only, so
        /// managed-engine callers judge by what landed on disk.
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

    /// The env a managed-engine invocation needs; CrossOver assembles its own
    /// from `cxbottle.conf`.
    func environment(bottle: String) -> [String: String] {
        var env = [
            "WINEPREFIX": bottlesRoot.appendingPathComponent(bottle).path,
            "PATH": wineURL.deletingLastPathComponent().path + ":/usr/bin:/bin",
            "WINEDEBUG": WineLog.channels,
        ]
        // A managed spawn gets a fresh environment, so ``BottleOwner`` is
        // copied in.
        if let owner = BottleOwner.pid {
            env[BottleOwner.variable] = owner
        }
        // Keeps Steam's own processes out of the Dock and off the screen:
        // winemac.drv promotes any wine process that shows a window, and
        // there is no demotion API (dormison/build-macos/dock-shim). The shim
        // decides per process by the Windows exe name, so a game keeps its
        // Dock promotion; the suppression flag rides on every managed spawn
        // because a spawn without it is a bare Wine window on screen.
        let dockShim = root.appendingPathComponent("libsevodockshim.dylib")
        if FileManager.default.fileExists(atPath: dockShim.path) {
            env["DYLD_INSERT_LIBRARIES"] = dockShim.path
            env["SEVO_SUPPRESS_WINDOWS"] = "1"
        }
        // For an engine without env files, which games inherit from the
        // client.
        env["SEVO_RESIZABLE_WINDOWS"] = GameConfig.windows(bottle: bottle).value.rawValue
        env["SEVO_UPSCALER"] = GameConfig.upscaler(bottle: bottle).value
        env["SEVO_FINAL_FILTER"] = GameConfig.filter(bottle: bottle).value.rawValue
        env["SEVO_SHADER_DIR"] = ShaderPackages.root.path
        let graphics = BottleGraphics.managedSelection()
        if graphics.msync {
            // msync must ride with esync or D3DMetal deadlocks.
            env["WINEMSYNC"] = "1"
            env["WINEESYNC"] = "1"
        }
        if let overrides = graphics.renderer.managedDLLOverrides {
            env["WINEDLLOVERRIDES"] = overrides
        }
        if graphics.renderer == .d3dmetal {
            // Never point this at the toolkit's own copy: the game's `.so`
            // stubs symlink to the tree's copy, and a second image means a
            // second dispatch table.
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
