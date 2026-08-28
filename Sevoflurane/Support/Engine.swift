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
    /// A managed engine under ``managedRoot``, one directory per version
    /// (layout produced by `Tools/package-engine.sh`).
    case managed(version: String)

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

    /// CrossOver first (its Steam/CEF fixes exist in no OSS binary — SPEC
    /// "Engine strategy"), newest managed engine otherwise.
    static func resolve(from detection: SetupDetection) -> Engine {
        if detection.usableCrossOver != nil {
            return .crossover
        }
        if let newest = detection.managedEngineVersions.last {
            return .managed(version: newest)
        }
        return .crossover
    }

    /// The synchronous subset of ``SetupProbe/detect()`` that decides the
    /// engine: CrossOver's license state and the managed-engine directory.
    private static func resolveFromDisk() -> Engine {
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

    var description: String {
        switch self {
        case .crossover: "CrossOver"
        case let .managed(version): "built-in \(version)"
        }
    }

    // MARK: - Paths

    /// The engine's own directory (the CrossOver tree, or the versioned
    /// managed directory).
    var root: URL {
        switch self {
        case .crossover:
            URL(fileURLWithPath: SteamBottle.crossoverBin).deletingLastPathComponent()
        case let .managed(version):
            Self.managedRoot.appendingPathComponent(version)
        }
    }

    /// Where this engine's bottles live. CrossOver bottles stay in
    /// CrossOver's directory so the user's existing installation is adopted,
    /// never migrated.
    var bottlesRoot: URL {
        switch self {
        case .crossover:
            SteamBottle.bottlesRoot
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
                ?? URL(fileURLWithPath: SteamBottle.crossoverBin + "/wine")
        case .managed:
            let bin = root.appendingPathComponent("wine/bin")
            let wine64 = bin.appendingPathComponent("wine64")
            return FileManager.default.fileExists(atPath: wine64.path)
                ? wine64 : bin.appendingPathComponent("wine")
        }
    }

    var wineserverURL: URL {
        switch self {
        case .crossover:
            URL(fileURLWithPath: SteamBottle.crossoverBin + "/wineserver")
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
        case .crossover:
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
        case .crossover:
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
