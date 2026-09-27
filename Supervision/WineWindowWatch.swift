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
/// confirmation that the client is wedged; it is never clicked.
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

    /// A window's Windows program and what named it.
    struct Program: Equatable, Sendable {
        /// Where the name came from, which is also how much it is worth: the
        /// first three are the bottle's own answers about its own processes,
        /// while `owner` is whatever macOS calls the window's application.
        enum Source: Equatable, Sendable {
            /// The process is the engine's loader; the name is its command line.
            case loader
            /// The process runs through a game's launcher bundle (``GameLaunchers``).
            case bundle
            /// A game run outside the bottle (``NWJSRunner``).
            case native
            /// Nothing claimed the process, so the window's owner names it.
            case owner
        }

        let name: String
        let source: Source
    }

    /// The Windows program behind an on-screen window, lowercased: the owner
    /// name when the engine reports one, otherwise the program inside the
    /// loader process. `GameLaunchWatch` classifies by the same answer.
    static func program(owner: String, pid: pid_t) -> String? {
        resolve(owner: owner, pid: pid)?.name
    }

    /// As ``program(owner:pid:)``, and says which of the four supplies
    /// answered — what a launch's log line needs to report that a game came
    /// up through its own bundle.
    static func resolve(owner: String, pid: pid_t) -> Program? {
        let name = owner.lowercased()
        if bottleLoaders.contains(name) {
            return windowsProgram(of: pid).map { Program(name: $0, source: .loader) }
        }
        // A process's arguments cost a KERN_ARGMAX buffer each and this is
        // asked of every window on screen, so nothing is asked of the kernel
        // until there is a bundle or a wrapper to find.
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
        // A bottle process macOS names after something else: the dock shim
        // renames the application, and a game running on the engine's own
        // loader is then neither one of the loader names nor a bundle path.
        // Its command line still says which Windows program it is, and a Mac
        // application's first argument does not end in `.exe`.
        if let windows = windowsProgram(fields), windows.hasSuffix(".exe") {
            return Program(name: windows, source: .loader)
        }
        return Program(name: name, source: .owner)
    }

    /// The Windows program a game running through its own loader bundle is
    /// on, or `nil` when this window belongs to something else.
    private static func bundledProgram(_ fields: [String]) -> String? {
        guard fields.count >= 2, fields[0].hasPrefix(GameLaunchers.root.path) else { return nil }
        return windowsProgram(fields)
    }

    /// The exe a native run stands in for, or `nil` for a window that is not
    /// one. A game Sevoflurane runs outside the bottle (``NWJSRunner``) is
    /// started with its own wrapper directory as the first argument, and that
    /// directory is named after the app id — so the command line says which
    /// game the window belongs to, whatever the process ended up being called.
    /// It is called the game, in fact: a native run is exec'd through a bundle
    /// named after it, which is the whole point of the bundle.
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

    /// Wine's plumbing: an on-screen `.exe` window owned by none of these is
    /// a game. `GameLaunchWatch` uses the same set to spot a launch's first
    /// window.
    static let gameInfrastructureOwners = clientOwners.union(bottleOwners).union(GameExecutables.windowsTools)

    /// Steam's own processes in the bottle: the client, its helpers, and the
    /// probes it runs at boot and from Help ▸ System Information. Each probe
    /// loads the Mac driver and some order a window, so one that runs during
    /// a launch reads as the game's own process unless it is named here
    /// (`steamsysinfo.exe` was recorded as a 166 s run, 2026-09-26). The
    /// same list the engine's dock shim keeps off the screen (dormison
    /// `sevo_dock_shim.c`, `is_steam_infrastructure`).
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

    /// Wine's own services, and the programs Sevoflurane runs in the bottle
    /// beside the client. Each of these can put a window on screen for a
    /// moment — a service starting, the Discord relay reconnecting — and a
    /// window of theirs is not a game starting: taken for one, it holds the
    /// display awake and spends the launch's activation right on nothing.
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
        /// The first game window the pass found. It names what holds the
        /// display awake, so a window mistaken for a game's says which
        /// program it belonged to.
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

    /// `@concurrent`: `CGWindowListCopyWindowInfo` is a synchronous round trip
    /// to the window server, which answers in its own time on a busy host —
    /// on the main thread that time would be a UI stall every probe cycle.
    @concurrent
    static func scan() async -> Scan {
        let interval = PerfProbe.system.beginInterval("WineWindowScan")
        defer { PerfProbe.system.endInterval("WineWindowScan", interval) }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return Scan(wineWindows: [], game: nil) }
        var wineWindows: [Window] = []
        var game: Window?
        var resolved: [pid_t: String] = [:]
        for entry in list {
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let owner = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let name = resolved[pid] ?? program(owner: owner, pid: pid) else { continue }
            resolved[pid] = name
            let isGame = isGameProgram(name)
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
        /// The window's CGWindow level (`kCGWindowLayer`). A frontmost Wine
        /// game raises itself far above normal windows and drops below them
        /// when backgrounded, so the overlay is leveled at `layer + 1` to
        /// ride just above it rather than at a fixed floating level.
        let layer: Int
    }

    /// The largest on-screen game window (a `.exe` window owned by none of the
    /// client's infrastructure), or `nil` when no game window is up. Windows at
    /// every level are considered: a frontmost fullscreen game is not at level
    /// zero, which is exactly when the overlay needs to find it.
    @concurrent
    static func gameWindow() async -> GameWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        var best: GameWindow?
        var bestArea: CGFloat = 0
        var resolved: [pid_t: String] = [:]
        for entry in list {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            guard let name = resolved[pid] ?? program(owner: owner, pid: pid) else { continue }
            resolved[pid] = name
            guard isGameProgram(name) else { continue }
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

    /// The Windows program a bottle process is running, lowercased and
    /// stripped to its file name.
    ///
    /// Wine rewrites `argv` to the Windows command line, so a process whose
    /// executable on disk is the engine's `wine` reports
    /// `C:\Program Files (x86)\Steam\steam.exe` as its first argument. That
    /// rewrite is the only thing that distinguishes Steam's infrastructure
    /// from a game once both run under the same loader binary.
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
