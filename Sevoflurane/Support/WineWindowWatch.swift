import CoreGraphics
import Foundation
import os

/// Detects visible windows belonging to the bottle's Wine processes.
///
/// In normal operation the bottled client is `-silent` and windowless, so any
/// on-screen Wine window is an anomaly — most often Steam's own watchdog
/// dialog (`CRescueDialog` in steamui.dll, "Steamwebhelper is not
/// responding"), occasionally an update/EULA dialog. The supervisor treats
/// such a window as a symptom to log and, when probes are failing too, as
/// confirmation that the client is wedged; it is never clicked
/// (`Docs/resilience-spec.md`).
///
/// Matching is by window owner name, which CGWindowList provides without any
/// permission. Window titles need Screen Recording and are used only when
/// present.
nonisolated enum WineWindowWatch {
    struct Window: Equatable, Sendable {
        let owner: String
        let pid: pid_t
        let title: String?
        let width: Int
        let height: Int
    }

    /// Process names winemac.drv windows appear under. The Mac Steam client's
    /// own windows ("Steam", "steam_osx") match none of these.
    private static let wineOwners: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "wine64-preloader", "wine-preloader",
    ]

    /// Wine's plumbing: an on-screen `.exe` window owned by none of these is
    /// a game. `GameLaunchWatch` uses the same set to spot a launch's first
    /// window.
    static let gameInfrastructureOwners: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "steamservice.exe",
        "steamerrorreporter.exe", "steamerrorreporter64.exe",
        "explorer.exe", "conhost.exe", "tabtip.exe",
        "gameoverlayui.exe", "gameoverlayui64.exe",
    ]

    /// One pass over the window list: the anomalous Wine windows, and
    /// whether a game's window is up.
    struct Scan: Sendable {
        let wineWindows: [Window]
        let gameWindowUp: Bool
    }

    /// `@concurrent`: `CGWindowListCopyWindowInfo` is a synchronous round trip
    /// to the window server, which answers in its own time on a busy host —
    /// on the main thread that time would be a UI stall every probe cycle.
    @concurrent
    static func scan() async -> Scan {
        let interval = PerfProbe.system.beginInterval("WineWindowScan")
        defer { PerfProbe.system.endInterval("WineWindowScan", interval) }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return Scan(wineWindows: [], gameWindowUp: false) }
        var wineWindows: [Window] = []
        var gameWindowUp = false
        for entry in list {
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let owner = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let name = owner.lowercased()
            if name.hasSuffix(".exe"), !gameInfrastructureOwners.contains(name) {
                gameWindowUp = true
            }
            guard wineOwners.contains(name),
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            wineWindows.append(Window(
                owner: owner,
                pid: pid,
                title: entry[kCGWindowName as String] as? String,
                width: (bounds["Width"] as? NSNumber)?.intValue ?? 0,
                height: (bounds["Height"] as? NSNumber)?.intValue ?? 0,
            ))
        }
        return Scan(wineWindows: wineWindows, gameWindowUp: gameWindowUp)
    }

    static func describe(_ windows: [Window]) -> String {
        windows.map { window in
            let title = window.title.map { " “\($0)”" } ?? ""
            return "\(window.owner)\(title) \(window.width)×\(window.height) (pid \(window.pid))"
        }.joined(separator: ", ")
    }
}
