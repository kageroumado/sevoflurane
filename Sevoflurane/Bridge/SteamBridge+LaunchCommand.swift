import Foundation

extension SteamBridge {
    // MARK: - Steam's launch options

    /// A `SetAppLaunchOptions` call with the line Steam keeps: the words ahead
    /// of `%command%` move into the game's own settings
    /// (``SteamLaunchCommand``), and the call stores the rest. Any other
    /// line passes as it came.
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

    /// Ahead of a `RunGame` call: the app's stored line taken apart the same
    /// way, for a line written before Sevoflurane saw it, so the env files
    /// carry the variables before Steam starts the game; then the variables
    /// the game starts with, in the event log.
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

    /// The line Steam keeps, with the settings written and the env files
    /// rewritten before it returns; `nil` when Steam runs `options` as it is.
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

    /// The variables set by name that a launch of this app starts with.
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
