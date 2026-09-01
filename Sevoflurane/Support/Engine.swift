import Foundation

/// Which Wine runs the bottle: CrossOver's, or a managed engine Sevoflurane
/// installed itself (`Docs/onboarding-spec.md` S1, release-plan R2.2).
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
    /// (layout produced by `Tools/package-engine.sh`).
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
    /// `wine/` (WineHQ tree), `dxvk/`, `dxmt/`, `d3dmetal/`,
    /// `webhelper-wrapper.exe`.
    static let managedRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/Engines")

    /// Where managed engines keep their bottles (plain `WINEPREFIX` trees).
    static let managedBottlesRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/Bottles")

    /// The engine every wine invocation routes through. Resolved from disk on
    /// first use (so the CLI needs no entry-point ceremony); the app reasserts
    /// it whenever a full detection lands. Resolution is idempotent, so a
    /// first-access race between callers is benign.
    private nonisolated(unsafe) static var resolved: Engine?
    static var active: Engine {
        get {
            if let resolved { return resolved }
            let engine = resolveFromDisk()
            resolved = engine
            return engine
        }
        set { resolved = newValue }
    }

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
    /// managed-engine directory.
    private static func resolveFromDisk() -> Engine {
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

    /// The stored form of the choice. Managed is stored version-agnostically
    /// — "the built-in engine", whichever version is newest — so an engine
    /// update keeps the choice working instead of pinning a directory that
    /// no longer exists.
    var preferenceValue: String {
        switch self {
        case .crossover: "crossover"
        case .crossoverPreview: "crossover-preview"
        case .managed: "managed"
        }
    }

    /// The stored choice as a runnable engine, or `nil` when nothing is
    /// stored or the chosen engine isn't on disk (managed chosen but never
    /// installed, a deleted app) — those fall to policy.
    static func preferred() -> Engine? {
        switch Preferences.shared.string(forKey: preferenceKey) {
        case "crossover": .crossover
        case "crossover-preview": .crossoverPreview
        case "managed":
            SetupProbe.managedEngineVersions().last.map { .managed(version: $0) }
        default: nil
        }
    }

    /// Whether the stored choice asks for the built-in engine, installed or
    /// not — provisioning reads this to know an install is wanted even with
    /// a usable CrossOver on the machine.
    static var preferenceWantsManaged: Bool {
        Preferences.shared.string(forKey: preferenceKey) == "managed"
    }

    /// Whether the engine's own binaries are still where the choice left
    /// them — a stored choice pointing at a deleted app must lose to policy.
    var existsOnDisk: Bool {
        switch self {
        case .crossover, .crossoverPreview:
            crossoverBin.map { FileManager.default.fileExists(atPath: $0) } ?? false
        case .managed:
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("wine/bin").path)
        }
    }

    var description: String {
        switch self {
        case .crossover: "CrossOver"
        case .crossoverPreview: "CrossOver Preview"
        case let .managed(version):
            version.isEmpty ? "the built-in engine" : "built-in \(version)"
        }
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
    static let previewBottlesRoot = URL(fileURLWithPath: NSHomeDirectory())
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
            "WINEDEBUG": "-all",
        ]
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
        env.merge(BottleGraphics.translationDefaults) { current, _ in current }
        env.merge(graphics.gpu.environment.filter { !$0.value.isEmpty }) { current, _ in current }
        return env
    }
}
