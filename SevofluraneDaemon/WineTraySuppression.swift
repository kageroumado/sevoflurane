import AppKit
import Foundation

/// What winemac.drv did to the bottle's processes on the Mac side, and the
/// one thing to be done about it.
extension BottleSupervisor {
    /// The bottle processes winemac.drv promoted into the Dock — matched by
    /// executable path under the managed engines or CrossOver, never by
    /// name (a name match once caught Microsoft Teams).
    static func promotedBottlePIDs() -> [pid_t] {
        let roots = [Engine.managedRoot.path, SetupProbe.crossoverApp.path]
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  let path = app.executableURL?.path else { return false }
            return roots.contains { path.hasPrefix($0) }
        }.map(\.processIdentifier)
    }

    /// Ends the bottle's `explorer.exe`, the only process that can turn Steam's
    /// Windows tray icon into a macOS status item.
    ///
    /// Neither `ShowSystray` nor `NoTrayItemsDisplay` can stop it: decompiling
    /// CrossOver 26.3's explorer.exe shows `handle_incoming` forwarding every
    /// `NIM_ADD` to the display driver (`NtUserMessageCall … 0x306`) and
    /// returning before `show_icon`, which is where both registry gates are
    /// read. The driver then owns a real `NSStatusItem` we cannot reach. So the
    /// suppression is the process itself — the bottled client neither needs nor
    /// notices its absence (verified live: full CDP target list, working UI).
    ///
    /// Only called once the client is fully up: explorer also owns the desktop
    /// during startup, and killing it there stops the client from starting at
    /// all (measured — CDP never arrived within 180s). Skipped while a game is
    /// running for the same reason, untested there.
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
    /// client's own infrastructure — the cheap "a game is up" signal.
    nonisolated static func isGameRunning() async -> Bool {
        let infrastructure: Set = [
            "steam.exe", "steamwebhelper.exe", "steamservice.exe", "explorer.exe",
            "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe",
            "rpcss.exe", "conhost.exe", "wineboot.exe", "start.exe", "rundll32.exe",
            "steamerrorreporter.exe", "steamerrorreporter64.exe", "tabtip.exe",
            "gameoverlayui64.exe", "cefwebhelper.exe",
        ]
        let out = await Subprocess.run("/usr/bin/pgrep", ["-af", "\\.exe"]).output
        for line in out.split(whereSeparator: \.isNewline) {
            guard let executable = line.split(separator: " ").first(where: {
                $0.lowercased().hasSuffix(".exe")
            }) else { continue }
            let name = String(executable.split(separator: "\\").last ?? executable).lowercased()
            if !infrastructure.contains(name) { return true }
        }
        return false
    }
}
