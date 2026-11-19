import Foundation

/// Native NW.js as the default runner for a detected NW.js game: Chromium inside the bottle is
/// slow, and recent NW.js draws nothing there. A game qualifies when known fixes apply
/// automatically (``Preferences/appliesKnownFixes``), it has no runner chosen, its NW.js version is
/// known, and it keeps nothing in Steam Cloud (``NWJSInfo/caution``). `sevo app config <id> runner
/// wine` is stored, so a game sent back stays.
nonisolated enum NWJSDefault {
    /// Whether a game with these values takes the native runner unasked.
    static func isCandidate(_ values: ConfigValues, enabled: Bool = Preferences.appliesKnownFixes) -> Bool {
        guard enabled, values.runner == nil, let info = values.nwjs else { return false }
        return !info.version.isEmpty && info.caution == nil
    }

    /// Switches the game from its next launch, fetching its runtime first when missing.
    @discardableResult
    static func adopt(appID: Int, log: (String) -> Void = { _ in }) async -> Bool {
        let values = GameConfig.game(appID)
        guard isCandidate(values), let info = values.nwjs else { return false }
        guard let wanted = NWJSRuntime.release(forGameVersion: info.version) else {
            log("app \(appID): no NW.js release fits version \(info.version), so the game stays in the bottle")
            return false
        }
        do {
            _ = try await NWJSRuntime.ensure(version: wanted)
        } catch {
            log("app \(appID): NW.js \(wanted) could not be fetched, so the game stays in the bottle — \(error)")
            return false
        }
        return switchToNative(appID: appID, runtime: wanted, log: log)
    }

    /// ``adopt(appID:log:)`` over the library, sequentially so games of one series fetch their
    /// runtime once.
    static func adoptLibrary(log: (String) -> Void = { _ in }) async {
        for game in SharedGames.installedGames() {
            await adopt(appID: game.appID, log: log)
        }
    }

    private static func switchToNative(appID: Int, runtime: String, log: (String) -> Void) -> Bool {
        var switched = false
        GameConfig.update(game: appID, bottle: SteamBottle.name, prefix: SteamBottle.root) { values in
            // Re-checked under the write: the player may have chosen since.
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
