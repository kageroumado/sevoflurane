import Foundation

/// Programs that only start as a child of `C:\windows\system32\steam.exe`, in
/// a prefix where no other `steam.exe` runs: HoYoverse's games.
///
/// Otherwise they load a kernel anti-cheat driver (`HoYoKProtect.sys`, which
/// imports `WDFLDR.SYS`) that no Wine can load, write `driverError.log`
/// (`initDriver Failed: Error [4,1114,0]`) and quit within about twenty
/// seconds. A `steam.exe` outside system32, the running Steam client, or
/// `start /unix` without that parent all send them down the driver path
/// (measured on Dormison r18 with GenshinImpact, 2026-09). So they run in a
/// companion prefix with no Steam in it, under the app's `steam-parent.exe`
/// installed as its `system32\steam.exe`; a bare `wineboot -i` prefix is
/// enough, and the engine, renderer staging and settings are the bottle's.
nonisolated enum SteamParent {
    /// The executables, lowercased, that get the parent. The same list the
    /// Linux runners start through their steam.exe stub.
    static let executables: Set<String> = [
        "genshinimpact.exe", "yuanshen.exe", "zenlesszonezero.exe", "bh3.exe",
    ]

    /// How long a launch waits for the companion's previous wineserver to
    /// exit. Wine's own linger is a few seconds; a program still running
    /// there holds it much longer.
    static let lastSessionWait: Duration = .seconds(20)

    /// Whether a program is one of them.
    static func wants(_ program: AdoptedProgram) -> Bool {
        executables.contains(program.url.lastPathComponent.lowercased())
    }

    /// Where companion prefixes live: outside `Bottles`, where the supervisor
    /// would stop their wineservers as stray bottles.
    static let root = SteamBottle.companionsRoot

    /// The companion prefix of one bottle.
    static func prefix(for bottle: String) -> URL {
        root.appendingPathComponent(bottle)
    }

    /// The bundled parent, as the app ships it.
    static let bundledName = "steam-parent.exe"

    /// Where the parent goes inside a prefix.
    static func parentPath(in prefix: URL) -> URL {
        prefix.appendingPathComponent("drive_c/windows/system32/steam.exe")
    }

    /// The argument list that starts a program under the parent, which passes
    /// its command line on untouched.
    static func invocation(_ program: AdoptedProgram) -> [String] {
        [#"C:\windows\system32\steam.exe"#, windowsPath(program.path)] + program.arguments
    }

    /// A macOS path as the prefix's `Z:` drive names it.
    static func windowsPath(_ path: String) -> String {
        "Z:" + path.replacingOccurrences(of: "/", with: #"\"#)
    }

    /// The bottle's own environment, pointed at its companion prefix.
    static func environment(bottle: String, engine: Engine) -> [String: String] {
        var environment = engine.environment(bottle: bottle)
        environment["WINEPREFIX"] = prefix(for: bottle).path
        return environment
    }

    /// Makes the companion prefix ready: its Windows on `engine`, created on
    /// first use, a loader file for every renderer DLL, the parent in place
    /// and current. Answers a refusal, or `nil` when it is ready.
    static func prepare(bottle: String, engine: Engine) async -> String? {
        guard case .managed = engine else {
            return "a program that needs a steam.exe parent runs on a Dormison engine, not \(engine)"
        }
        guard let parent = BundledResources.url(bundledName) else {
            return "this build of Sevoflurane carries no \(bundledName)"
        }
        let prefix = prefix(for: bottle)
        let manager = FileManager.default
        if let stale = serverEngine(of: prefix), stale != engine {
            // The bottle's teardown never reaches the companion, and the new
            // engine's processes cannot join an old engine's server.
            await ClientLifecycle.killWineservers([BottleTarget(prefix: prefix, engine: stale)])
            await EventLog.shared.log(.client, "stopped \(bottle)'s companion prefix, still running on \(stale.description)")
        }
        if !manager.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) {
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)
            let environment = environment(bottle: bottle, engine: engine)
            let boot = await Subprocess.run(
                engine.wineURL.path, ["wineboot", "-i"],
                environment: environment, capture: .combined, timeout: .seconds(180),
            )
            _ = await Subprocess.run(
                engine.wineserverURL.path, ["-w"], environment: environment, timeout: .seconds(60),
            )
            guard manager.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
                return "could not create the companion prefix (wineboot status \(boot.status.map(String.init) ?? "none"))"
            }
            await EventLog.shared.log(.setup, "created \(bottle)'s companion prefix for programs that need a steam.exe parent")
        }
        // The bottle's staging fills only the bottle's system32, and Wine
        // loads a renderer DLL only through a file there.
        EngineRenderers.ensureLoaderFiles(engine: engine.root, prefix: prefix)
        let target = parentPath(in: prefix)
        if !manager.contentsEqual(atPath: parent.path, andPath: target.path) {
            try? manager.removeItem(at: target)
            do {
                try manager.copyItem(at: parent, to: target)
            } catch {
                return "could not put steam.exe into the companion prefix: \(error.localizedDescription)"
            }
        }
        return nil
    }

    /// The managed engine whose wineserver holds `prefix` now, or `nil` when
    /// none runs there.
    static func serverEngine(of prefix: URL) -> Engine? {
        guard let directory = WineOrphans.serverDirectory(forPrefix: prefix.path) else { return nil }
        return BottleIdentity.liveServers()
            .first { $0.serverDirectory == directory }?
            .engineVersion
            .map { .managed(version: $0) }
    }
}
