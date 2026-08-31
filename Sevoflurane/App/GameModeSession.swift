import Foundation

/// Puts macOS Game Mode behind a launched game.
///
/// macOS turns Game Mode on by itself only for a full-screen app whose
/// bundle declares the games category — which a Wine process never does. The
/// developer override in `gamepolicyctl` forces the policy system-wide, so a
/// session here is: force `on` when a game's window appears, restore `auto`
/// when the game goes away or the app quits.
///
/// This is best-effort and often inert. `gamepolicyctl` ships **only inside
/// Xcode**, not the Command Line Tools, so on a user's machine every call is
/// a cheap no-op after the first probe. The daemon underneath
/// (`gamepolicyd`, XPC `com.apple.gamepolicyd.tool`,
/// `requestSetEnablementRequirement:enabled:`) is walled off from us
/// directly: it rejects unentitled callers, and the entitlement it wants
/// (`com.apple.gamepolicyd.tool.xpc`) is restricted — amfi SIGKILLs any
/// non-Apple binary that claims it. Measured, not reasoned; the full
/// investigation is the research notes. The
/// durable path for users is the games category baked into the engine's wine
/// loader at package time, not this.
///
/// The override is only taken when the current policy is `auto` — a policy
/// the user set by hand (`on` or `off`) is theirs, and is left alone.
@MainActor
enum GameModeSession {
    private static var forcedOn = false
    private static var starting = false

    /// A game's window is up. Idempotent; safe to call from both the launch
    /// watch (fast) and the supervisor's scan (authoritative).
    static func gameDidAppear() {
        guard !forcedOn, !starting else { return }
        starting = true
        Task(name: "Game Mode on") {
            defer { starting = false }
            guard await toolPresent(), await policyIsAutomatic() else { return }
            if await set("on") {
                forcedOn = true
                EventLog.shared.log(.app, "Game Mode forced on for the running game")
            }
        }
    }

    /// No game window remains.
    static func gameDidExit() {
        guard forcedOn else { return }
        forcedOn = false
        Task(name: "Game Mode auto") {
            if await set("auto") {
                EventLog.shared.log(.app, "Game Mode restored to automatic")
            }
        }
    }

    /// The app is quitting; a forced policy must not outlive it.
    static func restoreForQuit() async {
        guard forcedOn else { return }
        forcedOn = false
        _ = await set("auto")
    }

    private static func set(_ policy: String) async -> Bool {
        let result = await Subprocess.run(
            "/usr/bin/xcrun", ["gamepolicyctl", "game-mode", "set", policy],
            capture: .combined, timeout: .seconds(10),
        )
        if result.status != 0 {
            EventLog.shared.log(
                .app, "gamepolicyctl set \(policy) failed: \(result.output.prefix(120))",
            )
        }
        return result.status == 0
    }

    private static func policyIsAutomatic() async -> Bool {
        let result = await Subprocess.run(
            "/usr/bin/xcrun", ["gamepolicyctl", "game-mode", "status"],
            capture: .combined, timeout: .seconds(10),
        )
        return result.output.contains("automatic")
    }

    private static var toolPresence: Bool?

    private static func toolPresent() async -> Bool {
        if let toolPresence { return toolPresence }
        let present = await Subprocess.run(
            "/usr/bin/xcrun", ["--find", "gamepolicyctl"], timeout: .seconds(10),
        ).status == 0
        toolPresence = present
        if !present {
            EventLog.shared.log(
                .app, "Game Mode session unavailable — gamepolicyctl needs Xcode's tools",
            )
        }
        return present
    }
}
