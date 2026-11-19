import Foundation

extension SteamBridge {
    // MARK: - Steam's launch options

    /// A `SetAppLaunchOptions` call with the words ahead of `%command%` moved
    /// into the game's settings (``SteamLaunchCommand``).
    func adoptingLaunchCommand(in request: [String: Any]) async -> [String: Any] {
        guard var arguments = request["args"] as? [Any], arguments.count >= 2,
              let appID = SteamLaunchCommand.appID(inArguments: arguments),
              let options = arguments[1] as? String,
              let remainder = await adopt(options, appID: appID) else { return request }
        arguments[1] = remainder
        var request = request
        request["args"] = arguments
        return request
    }

    /// Ahead of a `RunGame` call, adopts a stored line Sevoflurane has not
    /// seen so the env files carry its variables, then logs the game's
    /// environment.
    func adoptLaunchCommand(beforeRunning request: [String: Any], cdp: CDPClient) async {
        guard let appID = SteamLaunchCommand.appID(inArguments: request["args"] as? [Any]) else { return }
        do {
            let options = try await withDeadline(Self.launchOptionsBudget) {
                try await cdp.evaluate(SteamLaunchCommand.readScript(appID: appID))
            }
            if let options, let remainder = await adopt(options, appID: appID) {
                _ = try await withDeadline(Self.launchOptionsBudget) {
                    try await cdp.evaluate(SteamLaunchCommand.storeScript(appID: appID, options: remainder))
                }
            }
        } catch {
            log(.client, "launch options \(appID): not read (\(error.localizedDescription)); the game starts with Steam's line as it is")
        }
        noteEnvironment(appID: appID)
    }

    /// How long a launch waits on Steam for an app's launch options.
    private static let launchOptionsBudget: Duration = .seconds(6)

    /// The line Steam keeps, with the settings and env files written before
    /// it returns; `nil` when `options` needs no change.
    private nonisolated func adopt(_ options: String, appID: Int) async -> String? {
        let adopted = await Task.detached(name: "Adopt launch options") {
            SteamLaunchCommand.adopt(options, appID: appID, bottle: SteamBottle.name, prefix: SteamBottle.root)
        }.value
        guard let adopted else { return nil }
        log(
            .client,
            "launch options \(appID): \(adopted.notes.joined(separator: "; ")); "
                + "Steam keeps \u{201C}\(adopted.remainder)\u{201D}",
        )
        return adopted.remainder
    }

    private nonisolated func noteEnvironment(appID: Int) {
        let game = GameConfig.game(appID).environment ?? [:]
        let bottle = (GameConfig.bottle(SteamBottle.name).environment ?? [:]).filter { game[$0.key] == nil }
        guard !bottle.isEmpty || !game.isEmpty else { return }
        let parts = [
            game.isEmpty ? nil : "game \(UserEnvironment.summary(game))",
            bottle.isEmpty ? nil : "bottle \(UserEnvironment.summary(bottle))",
        ].compactMap(\.self)
        log(.client, "launch \(appID): environment \(parts.joined(separator: ", "))")
    }
}
