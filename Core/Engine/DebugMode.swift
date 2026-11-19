import Foundation

/// The playtest switch: every parameter the test protocol needs, on and off
/// in one step. It lives in app memory and `<prefix>/.sevo/debug.env`, read
/// between `bottle.env` and a game's file, so deleting the file turns it off.
/// A file found at launch is a killed session's; ``clearStale`` removes it.
nonisolated enum DebugMode {
    /// Writes the engine half and the log directory DXMT does not make.
    static func turnOn(prefix: URL) {
        try? FileManager.default.createDirectory(
            at: rendererLogDirectory(prefix: prefix), withIntermediateDirectories: true,
        )
        ConfigMaterializer.writeDebugEnv(lines(), prefix: prefix)
    }

    /// Takes the engine half off; renderer logs stay.
    static func turnOff(prefix: URL) {
        ConfigMaterializer.removeDebugEnv(prefix: prefix)
    }

    /// Removes a file no session owns; answers whether one was there.
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

    /// Library loads, the renderer's errors and the three presentation logs.
    /// The channels fold in the bottle's (``WineLog/debugModeChannels``), since
    /// this file is read after `bottle.env` and would otherwise drop `+d3d`.
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

    /// Where DXMT writes, inside the prefix so the report collects it.
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
