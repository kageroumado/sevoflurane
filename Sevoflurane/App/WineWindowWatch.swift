import CoreGraphics
import Foundation

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
    struct Window: Equatable {
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

    static func visibleWineWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  wineOwners.contains(owner.lowercased()),
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }
            return Window(owner: owner, pid: pid,
                          title: entry[kCGWindowName as String] as? String,
                          width: (bounds["Width"] as? NSNumber)?.intValue ?? 0,
                          height: (bounds["Height"] as? NSNumber)?.intValue ?? 0)
        }
    }

    static func describe(_ windows: [Window]) -> String {
        windows.map { window in
            let title = window.title.map { " “\($0)”" } ?? ""
            return "\(window.owner)\(title) \(window.width)×\(window.height) (pid \(window.pid))"
        }.joined(separator: ", ")
    }
}
