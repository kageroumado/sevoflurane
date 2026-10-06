import Foundation

extension SteamBridge {
    // MARK: - Store titles in Steam's library

    /// How long a launch from Steam's library waits for the store's launch
    /// plan before Steam starts the shortcut as it was saved.
    static let storePlanBudget: Duration = .seconds(20)

    /// Ahead of a `RunGame` call for the shortcut of an Epic or GOG title:
    /// asks the store for this launch's program (``StoreLibrary/refreshed(_:)``)
    /// and points the shortcut at it, so a start from Steam's library or Big
    /// Picture carries Epic's sign-in for this launch the way a Quick Launch
    /// start does. Steam then starts the shortcut itself, as the parent of the
    /// game, with its overlay and Input.
    func retargetStoreShortcut(beforeRunning request: [String: Any], cdp: CDPClient) async {
        guard let first = (request["args"] as? [Any])?.first,
              let entry = SteamShortcuts.storeProgram(launching: "\(first)", in: AdoptedPrograms.all()),
              let shortcut = entry.program.steamShortcutID else { return }
        let program = entry.program
        let refreshed: (program: AdoptedProgram, note: String?)
        do {
            refreshed = try await withDeadline(Self.storePlanBudget) { await StoreLibrary.refreshed(program) }
        } catch {
            log(.client, "launch \(entry.name): the store gave no launch plan within \(Self.storePlanBudget); Steam starts the shortcut as it was saved")
            return
        }
        if let note = refreshed.note { log(.client, "launch \(entry.name): \(note)") }
        let script = SteamShortcuts.retargetScript(shortcut, SteamShortcuts.target(refreshed.program))
        let answer = try? await withDeadline(ClientLifecycle.cdpCallCap) { try await cdp.evaluate(script) }
        if answer == nil {
            log(.client, "launch \(entry.name): Steam's shortcut could not take this launch's program; it starts as it was saved")
        }
    }
}
