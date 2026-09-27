import Foundation

/// The playtest switch: one mode that sets every parameter the test protocol
/// would otherwise ask a tester to set by hand, and takes them all off again
/// when it ends.
///
/// Nothing is persisted. The mode lives in the running app's memory and in
/// `<prefix>/.sevo/debug.env`, which the engine reads after `bottle.env` and
/// before a game's own file — so the bottle's settings stand underneath it,
/// untouched, and deleting the file is the whole of turning the mode off.
/// The file goes when the mode goes and when the app quits; one found at
/// launch belongs to a session that was killed, and ``clearStale`` removes it
/// so a forgotten switch cannot fill the disk between sessions.
///
/// The engine half reaches a game at its next start, so Steam is restarted
/// around it.
nonisolated enum DebugMode {
    /// Writes the engine half. The renderer's log directory is created here:
    /// DXMT opens `<DXMT_LOG_PATH>/<exe>_d3d11.log` and does not make the
    /// directory itself.
    static func turnOn(prefix: URL) {
        try? FileManager.default.createDirectory(
            at: rendererLogDirectory(prefix: prefix), withIntermediateDirectories: true,
        )
        ConfigMaterializer.writeDebugEnv(lines(), prefix: prefix)
    }

    /// Takes the engine half off. The renderer logs already written stay
    /// where they are: they are what the session was turned on to collect.
    static func turnOff(prefix: URL) {
        ConfigMaterializer.removeDebugEnv(prefix: prefix)
    }

    /// Removes a file no session owns. Answers whether one was there, which
    /// is the app's cue to say that a previous run was killed with the mode
    /// still on.
    static func clearStale(prefix: URL) -> Bool {
        ConfigMaterializer.removeDebugEnv(prefix: prefix)
    }

    /// Whether the engine half is on disk for this bottle.
    static func isWritten(prefix: URL) -> Bool {
        FileManager.default.fileExists(atPath: envURL(prefix: prefix).path)
    }

    static func envURL(prefix: URL) -> URL {
        ConfigMaterializer.debugEnvURL(prefix: prefix)
    }

    /// What the file says: every library load in the Wine log, the renderer's
    /// own errors in a file of its own, and the three engine logs that
    /// describe how a frame reached the screen.
    ///
    /// The channels are Debug mode's own set folded together with the bottle's
    /// `wine-debug` channels (``WineLog/debugModeChannels``), so a custom
    /// channel string set by hand survives the mode instead of being replaced
    /// by it — `debug.env` is read after `bottle.env`, so a bare level-one set
    /// here would drop the bottle's `+d3d`.
    static func lines() -> [String] {
        [
            "WINEDEBUG=\(WineLog.debugModeChannels)",
            "DXMT_LOG_LEVEL=error",
            "DXMT_LOG_PATH=\(rendererLogWindowsPath)",
            "SEVO_PRESENTATION_LOG=1",
            "SEVO_PRESENTER_LOG=1",
            "SEVO_GFX_LOG=1",
        ]
    }

    /// Where DXMT writes, as the bottle sees it. Inside the prefix, so the
    /// report collects it and a tester never has to find it.
    static var rendererLogWindowsPath: String {
        "C:\\users\\" + SteamBottle.windowsUser + "\\Temp\\dxmt"
    }

    /// The same directory as macOS sees it.
    static func rendererLogDirectory(prefix: URL) -> URL {
        prefix.appendingPathComponent(
            "drive_c/users/\(SteamBottle.windowsUser)/Temp/dxmt",
        )
    }
}
