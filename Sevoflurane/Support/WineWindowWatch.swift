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
/// Matching starts from the window owner name, which CGWindowList provides
/// without any permission, and resolves to the Windows program the owning
/// process is running. Window titles need Screen Recording and are used only
/// when present.
nonisolated enum WineWindowWatch {
    struct Window: Equatable, Sendable {
        let owner: String
        let pid: pid_t
        let title: String?
        let width: Int
        let height: Int
    }

    /// Owner names that mean "some Windows program in the bottle": the unix
    /// binary the engine's loader is called, which reveals nothing about
    /// which program is inside it. `windowsProgram(of:)` answers that.
    private static let bottleLoaders: Set<String> = [
        "wine", "wine64", "wine-preloader", "wine64-preloader",
    ]

    /// The Windows program behind an on-screen window, lowercased: the owner
    /// name when the engine reports one, otherwise the program inside the
    /// loader process. `GameLaunchWatch` classifies by the same answer.
    static func program(owner: String, pid: pid_t) -> String? {
        let name = owner.lowercased()
        guard bottleLoaders.contains(name) else { return name }
        return windowsProgram(of: pid)
    }

    /// The client's two window-bearing processes. The Mac Steam client's own
    /// windows ("Steam", "steam_osx") match neither.
    private static let clientPrograms: Set<String> = [
        "steam.exe", "steamwebhelper.exe",
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
        var resolved: [pid_t: String] = [:]
        for entry in list {
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let owner = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let name = resolved[pid] ?? program(owner: owner, pid: pid) else { continue }
            resolved[pid] = name
            if name.hasSuffix(".exe"), !gameInfrastructureOwners.contains(name) {
                gameWindowUp = true
            }
            guard clientPrograms.contains(name),
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            wineWindows.append(Window(
                owner: name,
                pid: pid,
                title: entry[kCGWindowName as String] as? String,
                width: (bounds["Width"] as? NSNumber)?.intValue ?? 0,
                height: (bounds["Height"] as? NSNumber)?.intValue ?? 0,
            ))
        }
        return Scan(wineWindows: wineWindows, gameWindowUp: gameWindowUp)
    }

    /// The Windows program a bottle process is running, lowercased and
    /// stripped to its file name.
    ///
    /// Wine rewrites `argv` to the Windows command line, so a process whose
    /// executable on disk is the engine's `wine` reports
    /// `C:\Program Files (x86)\Steam\steam.exe` as its first argument. That
    /// rewrite is the only thing that distinguishes Steam's infrastructure
    /// from a game once both run under the same loader binary.
    private static func windowsProgram(of pid: pid_t) -> String? {
        var limit: Int32 = 0
        var limitSize = MemoryLayout<Int32>.size
        var limitName = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limitName, 2, &limit, &limitSize, nil, 0) == 0, limit > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: Int(limit))
        var size = Int(limit)
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        // An argument count, then the executable's path, then NUL padding,
        // then the arguments themselves.
        let fields = buffer[MemoryLayout<Int32>.size ..< size]
            .split(separator: 0, omittingEmptySubsequences: true)
            .prefix(2)
            .map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == 2 else { return nil }
        let program = fields[1].split(separator: "\\").last.map(String.init) ?? fields[1]
        return program.lowercased()
    }

    static func describe(_ windows: [Window]) -> String {
        windows.map { window in
            let title = window.title.map { " “\($0)”" } ?? ""
            return "\(window.owner)\(title) \(window.width)×\(window.height) (pid \(window.pid))"
        }.joined(separator: ", ")
    }
}
