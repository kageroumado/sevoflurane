import AppKit
import Foundation

/// What winemac.drv did to the bottle's processes on the Mac side, and the
/// one thing to be done about it.
extension BottleSupervisor {
    /// The bottle processes winemac.drv promoted into the Dock — matched by
    /// executable path under the managed engines or CrossOver. Never match by
    /// name: a name match catches unrelated apps such as Microsoft Teams.
    static func promotedBottlePIDs() -> [pid_t] {
        let roots = [Engine.managedRoot.path, SetupProbe.crossoverApp.path]
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  let path = app.executableURL?.path else { return false }
            return roots.contains { path.hasPrefix($0) }
        }.map(\.processIdentifier)
    }

    /// Ends the bottle's `explorer.exe`, the only process that turns Steam's
    /// tray icon into a macOS status item; the client works without it.
    ///
    /// The `ShowSystray` and `NoTrayItemsDisplay` registry gates cannot stop
    /// it: CrossOver 26.3's `handle_incoming` forwards every `NIM_ADD` to the
    /// driver before reading them. Only once the client is up and no game
    /// runs: killed during startup, the client never starts (no CDP in 180 s).
    nonisolated static func suppressWineTray() async {
        guard await Subprocess.run("/usr/bin/pgrep", ["-f", "explorer.exe /desktop"]).status == 0 else {
            return
        }
        guard await !isGameRunning() else { return }
        let explorers = await ClientLifecycle.bottleProcessIDs(matching: "explorer.exe")
        guard !explorers.isEmpty else { return }
        for pid in explorers {
            kill(pid, SIGTERM)
        }
        await MainActor.run {
            EventLog.shared.log(
                .client,
                "suppressed the bottle's Wine tray host (explorer.exe \(explorers))",
            )
        }
    }

    /// True when a bottle process runs an executable that is not part of the
    /// client's own infrastructure or Wine's — the cheap "a game is up" signal.
    nonisolated static func isGameRunning() async -> Bool {
        let infrastructure: Set = [
            "steam.exe", "steamwebhelper.exe", "steamservice.exe", "explorer.exe",
            "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe",
            "rpcss.exe", "conhost.exe", "wineboot.exe", "start.exe", "rundll32.exe",
            "winemenubuilder.exe", "steamerrorreporter.exe", "steamerrorreporter64.exe",
            "tabtip.exe", "gameoverlayui64.exe", "cefwebhelper.exe", "sevo-discord-bridge.exe",
        ]
        let out = await Subprocess.run("/usr/bin/pgrep", WineProcessList.pgrepArguments).output
        return WineProcessList.entries(fromPgrepLong: out).contains {
            !infrastructure.contains($0.name)
        }
    }
}
