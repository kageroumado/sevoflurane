import Foundation

/// Native NW.js as the runner of a detected NW.js game whose player has
/// chosen none: Chromium inside the bottle is the slow path for a game that
/// is already a Chromium app, and recent NW.js draws nothing there.
///
/// A game is taken when known fixes apply automatically
/// (``Preferences/appliesKnownFixes``), it has no runner of its own, its
/// NW.js version was read, and it keeps nothing in Steam Cloud through
/// greenworks (``NWJSInfo/caution``). `sevo app config <id> runner wine`
/// stores the choice, so a game sent back to the bottle stays there.
nonisolated enum NWJSDefault {
    /// Whether a game with these values takes the native runner unasked.
    static func isCandidate(_ values: ConfigValues, enabled: Bool = Preferences.appliesKnownFixes) -> Bool {
        guard enabled, values.runner == nil, let info = values.nwjs else { return false }
        return !info.version.isEmpty && info.caution == nil
    }

    /// Switches the game, fetching its runtime first when it is not on disk.
    /// The switch reaches the game at its next launch.
    @discardableResult
    static func adopt(appID: Int, log: (String) -> Void = { _ in }) async -> Bool {
        let values = GameConfig.game(appID)
        guard isCandidate(values), let info = values.nwjs else { return false }
        let wanted = await NWJSRuntime.release(forGameVersion: info.version)
        do {
            _ = try await NWJSRuntime.ensure(version: wanted)
        } catch {
            log("app \(appID): NW.js \(wanted) could not be fetched, so the game stays in the bottle — \(error)")
            return false
        }
        return switchToNative(appID: appID, runtime: wanted, log: log)
    }

    /// ``adopt(appID:log:)`` over the installed library, one game at a time
    /// so two games of one series fetch their runtime once.
    static func adoptLibrary(log: (String) -> Void = { _ in }) async {
        for game in SharedGames.installedGames() {
            await adopt(appID: game.appID, log: log)
        }
    }

    private static func switchToNative(appID: Int, runtime: String, log: (String) -> Void) -> Bool {
        var switched = false
        GameConfig.update(game: appID, bottle: SteamBottle.name, prefix: SteamBottle.root) { values in
            // Read again under the write: the player may have chosen since.
            guard isCandidate(values) else { return }
            values.runner = GameRunner.nwjs
            values.nwjsRuntime = runtime
            switched = true
        }
        if switched {
            log("app \(appID): an NW.js game with no runner chosen — it runs natively on NW.js \(runtime) "
                + "from its next launch")
        }
        return switched
    }
}
