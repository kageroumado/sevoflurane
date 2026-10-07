import Foundation

/// Programs that only start as a child of `C:\windows\system32\steam.exe`, in
/// a prefix where no other `steam.exe` runs: HoYoverse's games.
///
/// These games load a kernel anti-cheat driver (`HoYoKProtect.sys`, which
/// imports `WDFLDR.SYS`) that no Wine can load. When they try, the load fails
/// with `c0000142`, the game writes `driverError.log` beside itself
/// (`initDriver Failed: Error [4,1114,0]`) and quits within about twenty
/// seconds, before its graphics device or its Unity log exist. They skip the
/// driver when their parent is a `steam.exe` in system32 and every `steam.exe`
/// they can see lives there too, which is the arrangement Proton's own
/// `steam.exe` gives them and the one every Linux and macOS launcher for these
/// games relies on.
///
/// A bottle cannot give them that: it always runs the real Steam client from
/// `Program Files (x86)\Steam`, and that process alone sends the game down the
/// driver path, whoever its parent is. Measured on Dormison r18, GenshinImpact
/// 2026-09 (the pull request that added this has the trials):
///
/// - parent `system32\steam.exe`, no other `steam.exe`: no driver, plays;
/// - the same with a second `steam.exe` in system32: plays;
/// - the same with a `steam.exe` anywhere else, or the Steam client running,
///   or the Steam client itself as the parent: driver, dies;
/// - `start /unix` without that parent: driver, dies, in any prefix.
///
/// So these programs run in a companion prefix beside the bottle, with Steam
/// nowhere in it, started by the app's own `steam-parent.exe` installed as
/// that prefix's `system32\steam.exe`. A bare prefix is enough: the trials
/// played in one made by `wineboot -i` a minute earlier. The engine, the
/// renderer staging and the per-game settings are the bottle's own.
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

    /// Where companion prefixes live. Outside `Bottles` on purpose: the
    /// supervisor stops any client or wineserver of another bottle it finds
    /// there, and a companion is not a bottle, nor one the setup assistant
    /// should offer.
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

    /// The argument list that starts a program under the parent.
    ///
    /// The program is named by its `Z:` path, which the prefix maps to the
    /// Mac's root, and the parent passes the rest of its command line on
    /// untouched, so each argument stays its own token.
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
            // A program the last launch started outlived an engine switch, and
            // the bottle's teardown never reaches the companion. The new
            // engine's processes cannot join that server, so it goes, with
            // whatever still runs on it.
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
