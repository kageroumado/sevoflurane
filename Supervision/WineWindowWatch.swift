import CoreGraphics
import Darwin
import Foundation
import os

/// Detects visible windows of the bottle's Wine processes.
///
/// The `-silent` client is windowless, so an on-screen Wine window is most
/// often Steam's watchdog dialog (`CRescueDialog` in steamui.dll,
/// "Steamwebhelper is not responding") or an update/EULA dialog: a symptom,
/// never clicked. Matching uses the owner name, which needs no permission;
/// titles need Screen Recording and are used only when present.
nonisolated enum WineWindowWatch {
    struct Window: Equatable, Sendable {
        let owner: String
        let pid: pid_t
        let title: String?
        let width: Int
        let height: Int
    }

    /// Owner names of the engine's loader, which say nothing of the program
    /// inside it (`windowsProgram(of:)` does).
    private static let bottleLoaders: Set<String> = [
        "wine", "wine64", "wine-preloader", "wine64-preloader",
    ]

    /// A window's program and what named it.
    struct Program: Equatable, Sendable {
        /// Where the name came from: the first four from the bottle's or the
        /// engine's records, `owner` from what macOS calls the application.
        enum Source: Equatable, Sendable {
            /// The process is the engine's loader; the name is its command line.
            case loader
            /// The process runs through a game's launcher bundle (``GameLaunchers``).
            case bundle
            /// An NW.js game run outside the bottle (``NWJSRunner``), named
            /// after its exe.
            case native
            /// A macOS build Steam Play installed (``SteamPlayMacOS``), running
            /// under the engine's native supervisor (``NativeSessions``) and
            /// named after its `.app`.
            case macOSBuild
            /// Nothing claimed the process, so the window's owner names it.
            case owner
        }

        let name: String
        let source: Source
        /// The app whose session runs the process; set for ``Source/macOSBuild``.
        var appID: Int?

        /// Whether the window is a game's: a macOS build's, or an `.exe`
        /// window owned by none of the client's infrastructure.
        var isGame: Bool {
            source == .macOSBuild || WineWindowWatch.isGameProgram(name)
        }
    }

    /// The program behind an on-screen window, lowercased. `sessions` are the
    /// running macOS builds, read once per pass over the window list.
    static func program(owner: String, pid: pid_t, sessions: [NativeSessions.Session]) -> String? {
        resolve(owner: owner, pid: pid, sessions: sessions)?.name
    }

    /// As ``program(owner:pid:sessions:)``, and says which source answered.
    static func resolve(owner: String, pid: pid_t, sessions: [NativeSessions.Session]) -> Program? {
        if let build = macOSBuild(of: pid, sessions: sessions) {
            return build
        }
        let name = owner.lowercased()
        if bottleLoaders.contains(name) {
            return windowsProgram(of: pid).map { Program(name: $0, source: .loader) }
        }
        // Arguments cost a KERN_ARGMAX buffer per window: read them only when a
        // bundle or wrapper exists.
        guard GameLaunchers.hasBundles || NWJSRunner.hasWrappers else {
            return Program(name: name, source: .owner)
        }
        let fields = arguments(of: pid)
        if let bundled = bundledProgram(fields) {
            return Program(name: bundled, source: .bundle)
        }
        if let native = nativeProgram(fields) {
            return Program(name: native, source: .native)
        }
        // The dock shim renames a loader process; its first argument still
        // names the Windows program, and a Mac application's never ends in `.exe`.
        if let windows = windowsProgram(fields), windows.hasSuffix(".exe") {
            return Program(name: windows, source: .loader)
        }
        return Program(name: name, source: .owner)
    }

    /// The macOS build a process or its group belongs to, from the native
    /// supervisor's session files. NW.js sessions are left out: their windows
    /// stay named after the game's exe (``nativeProgram(_:)``).
    static func macOSBuild(of pid: pid_t, sessions: [NativeSessions.Session]) -> Program? {
        NativeSessions.session(owning: pid, in: sessions.filter { !$0.isNWJS }).map {
            Program(name: $0.name, source: .macOSBuild, appID: $0.appID)
        }
    }

    /// The Windows program a game running through its own loader bundle is
    /// on, or `nil` when this window belongs to something else.
    private static func bundledProgram(_ fields: [String]) -> String? {
        guard fields.count >= 2, fields[0].hasPrefix(GameLaunchers.root.path) else { return nil }
        return windowsProgram(fields)
    }

    /// The exe a native NW.js run (``NWJSRunner``) stands in for: its first
    /// argument is its wrapper directory, named after the app id.
    private static func nativeProgram(_ fields: [String]) -> String? {
        guard fields.count >= 3, fields[2].hasPrefix(NWJSRunner.root.path),
              let appID = Int(URL(fileURLWithPath: fields[2]).lastPathComponent),
              let exe = GameConfig.game(appID).exes?.first
        else { return nil }
        return exe.lowercased()
    }

    /// The client's two window-bearing processes. The Mac Steam client's own
    /// windows ("Steam", "steam_osx") match neither.
    private static let clientPrograms: Set<String> = [
        "steam.exe", "steamwebhelper.exe",
    ]

    /// Whether a resolved program name is a game's: an `.exe` window owned by
    /// none of the client's own infrastructure.
    static func isGameProgram(_ name: String) -> Bool {
        name.hasSuffix(".exe") && !gameInfrastructureOwners.contains(name)
    }

    /// Wine's and Steam's plumbing; `GameLaunchWatch` uses the same set.
    static let gameInfrastructureOwners = clientOwners.union(bottleOwners).union(GameExecutables.windowsTools)

    /// Steam's processes in the bottle, its boot and System Information probes
    /// included: a probe that orders a window during a launch otherwise reads
    /// as the game (`steamsysinfo.exe` as a 166 s run). The same list as
    /// dormison's `sevo_dock_shim.c` (`is_steam_infrastructure`).
    private static let clientOwners: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "steamservice.exe",
        "steamerrorreporter.exe", "steamerrorreporter64.exe",
        "explorer.exe", "conhost.exe", "tabtip.exe",
        "gameoverlayui.exe", "gameoverlayui64.exe",
        "steamsysinfo.exe", "hardwareupdater.exe", "steamsetup.exe",
        "gldriverquery.exe", "gldriverquery64.exe",
        "vulkandriverquery.exe", "vulkandriverquery64.exe",
        "steamxboxutil.exe", "steamxboxutil64.exe",
        "fossilize-replay.exe", "fossilize-replay64.exe",
        "x64launcher.exe", "x86launcher.exe", "writeminidump.exe",
        "steam_monitor.exe", "secure_desktop_capture.exe",
        "streaming_client.exe", "drivers.exe",
    ]

    /// Wine's services and Sevoflurane's own bottle programs, whose brief
    /// windows would otherwise hold the display awake and spend a launch's
    /// activation right.
    private static let bottleOwners: Set<String> = [
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe",
        "rpcss.exe", "wineboot.exe", "winemenubuilder.exe", "start.exe",
        "rundll32.exe",
        "sevo-discord-bridge.exe", "sevo-steamstub.exe", "sevo-steamstub32.exe",
        // What setup's dependency step runs (``BottleDependencies``).
        "vc_redist.x64.exe", "vc_redist.x86.exe", "directx_jun2010_redist.exe", "dxsetup.exe",
        "reg.exe", "regedit.exe",
    ]

    /// One pass over the window list: the anomalous Wine windows, and the
    /// game window if one is up.
    struct Scan: Sendable {
        let wineWindows: [Window]
        /// The largest game window the pass found; it names what holds the
        /// display awake.
        let game: Window?

        var gameWindowUp: Bool { game != nil }
    }

    /// The smallest side a game's own window has. The engine's frame-rate
    /// counter is a child window of the game's in front of it: a capsule 22
    /// points tall, or with the frame-time graph a card 96 points tall.
    static let smallestGameWindowSide = 128

    static func isOverlay(width: Int, height: Int) -> Bool {
        min(width, height) < smallestGameWindowSide
    }

    /// `@concurrent`: `CGWindowListCopyWindowInfo` is a synchronous
    /// window-server round trip, slow on a busy host.
    @concurrent
    static func scan() async -> Scan {
        let interval = PerfProbe.system.beginInterval("WineWindowScan")
        defer { PerfProbe.system.endInterval("WineWindowScan", interval) }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return Scan(wineWindows: [], game: nil) }
        var wineWindows: [Window] = []
        var game: Window?
        var resolved: [pid_t: Program] = [:]
        let sessions = NativeSessions.live()
        for entry in list {
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let owner = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let program = resolved[pid] ?? resolve(owner: owner, pid: pid, sessions: sessions) else { continue }
            resolved[pid] = program
            let name = program.name
            let isGame = program.isGame
            guard isGame || clientPrograms.contains(name) else { continue }
            let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let window = Window(
                owner: name,
                pid: pid,
                title: entry[kCGWindowName as String] as? String,
                width: (bounds["Width"] as? NSNumber)?.intValue ?? 0,
                height: (bounds["Height"] as? NSNumber)?.intValue ?? 0,
            )
            if isGame {
                // The largest: a game can show a launcher, a splash and its own window at once.
                if !isOverlay(width: window.width, height: window.height),
                   window.width * window.height > (game.map { $0.width * $0.height } ?? 0) {
                    game = window
                }
            } else {
                wineWindows.append(window)
            }
        }
        return Scan(wineWindows: wineWindows, game: game)
    }

    /// The game's on-screen window: its owning process and its frame, in
    /// CGWindowList coordinates (top-left origin, the space
    /// ``SteamScreenSpace`` calls Steam's). The Steam overlay window is placed
    /// over this, and focus is returned to this pid when the overlay closes.
    struct GameWindow: Equatable, Sendable {
        let pid: pid_t
        /// Top-left-origin bounds as CGWindowList reports them; convert with
        /// `SteamScreenSpace.appKitOrigin(steamX:steamY:size:)`.
        let bounds: CGRect
        /// The window's `kCGWindowLayer`; the overlay sits at `layer + 1`
        /// because a Wine game's level changes as it gains and loses the front.
        let layer: Int
    }

    /// The largest on-screen game window, at any level: a frontmost
    /// fullscreen game is not at level zero.
    @concurrent
    static func gameWindow() async -> GameWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        var best: GameWindow?
        var bestArea: CGFloat = 0
        var resolved: [pid_t: Program] = [:]
        let sessions = NativeSessions.live()
        for entry in list {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            guard let program = resolved[pid] ?? resolve(owner: owner, pid: pid, sessions: sessions) else { continue }
            resolved[pid] = program
            guard program.isGame else { continue }
            let rect = CGRect(
                x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0,
            )
            let area = rect.width * rect.height
            if area > bestArea {
                bestArea = area
                best = GameWindow(pid: pid, bounds: rect, layer: layer)
            }
        }
        return best
    }

    /// The Windows program a bottle process runs, as a lowercased file name:
    /// Wine rewrites `argv` to the Windows command line
    /// (`C:\Program Files (x86)\Steam\steam.exe`).
    private static func windowsProgram(of pid: pid_t) -> String? {
        windowsProgram(arguments(of: pid))
    }

    private static func windowsProgram(_ fields: [String]) -> String? {
        guard fields.count >= 2 else { return nil }
        let program = fields[1].split(separator: "\\").last.map(String.init) ?? fields[1]
        return program.lowercased()
    }

    /// A process's executable path followed by its arguments, as the kernel
    /// keeps them: `[executable, argv[0], argv[1], …]`.
    private static func arguments(of pid: pid_t, upTo count: Int = 3) -> [String] {
        var limit: Int32 = 0
        var limitSize = MemoryLayout<Int32>.size
        var limitName = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limitName, 2, &limit, &limitSize, nil, 0) == 0, limit > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(limit))
        var size = Int(limit)
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return [] }
        // An argument count, then the executable's path, then NUL padding,
        // then the arguments themselves.
        return buffer[MemoryLayout<Int32>.size ..< size]
            .split(separator: 0, omittingEmptySubsequences: true)
            .prefix(count)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func describe(_ windows: [Window]) -> String {
        windows.map { window in
            let title = window.title.map { " “\($0)”" } ?? ""
            return "\(window.owner)\(title) \(window.width)×\(window.height) (pid \(window.pid))"
        }.joined(separator: ", ")
    }
}
