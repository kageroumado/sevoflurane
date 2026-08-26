import AppKit
import CoreGraphics

/// Brings a freshly launched game's window to the front.
///
/// Wine's processes are background apps to macOS, so a game window opens
/// *behind* whatever is frontmost — on Windows, Steam foregrounds the game.
/// Every launch path (menu bar, library Play button, `steam://run`) funnels
/// through `SteamClient.Apps.RunGame` on the bridge, which arms this watch;
/// the first on-screen window owned by a bottle process that is not client
/// infrastructure is the game, and its app gets activated exactly once.
@MainActor
final class GameLaunchWatch {
    /// How long a launch stays armed: game engines can take this long to put
    /// up their first real window (shader precompilation, updates).
    private static let armedFor: Duration = .seconds(180)
    private static let pollEvery: Duration = .seconds(1)

    /// Window owners that are the client's own plumbing, never the game.
    /// Steam's dialogs surface under `steam.exe`/`steamwebhelper.exe`
    /// (`WineWindowWatch`), and the game window's owner is the game's own
    /// exe name.
    private static let infrastructureOwners: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "steamservice.exe",
        "steamerrorreporter.exe", "steamerrorreporter64.exe",
        "explorer.exe", "conhost.exe", "tabtip.exe",
        "gameoverlayui.exe", "gameoverlayui64.exe",
    ]

    private var watch: Task<Void, Never>?

    /// Fired when the game's first window is up — the host clears the
    /// launch-status line on it.
    var onGameWindowUp: (() -> Void)?

    /// Arms (or re-arms) the watch; called when the bridge sees `RunGame`.
    func noteLaunchRequested() {
        watch?.cancel()
        EventLog.shared.log(.window, "game launch requested — watching for its window")
        watch = Task(name: "Game window watch") { [weak self] in
            let deadline = ContinuousClock.now + Self.armedFor
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if let game = Self.firstGameWindow() {
                    self?.activate(game)
                    return
                }
                try? await Task.sleep(for: Self.pollEvery)
            }
        }
    }

    private func activate(_ game: (owner: String, pid: pid_t)) {
        defer { onGameWindowUp?() }
        guard let app = NSRunningApplication(processIdentifier: game.pid) else {
            EventLog.shared.log(
                .window, "game window up (\(game.owner)) but pid \(game.pid) has no app to activate",
            )
            return
        }
        let activated = app.activate()
        EventLog.shared.log(
            .window,
            activated
                ? "game window up — brought \(game.owner) to the front"
                : "game window up (\(game.owner)) but macOS declined the activation",
        )
    }

    /// The first on-screen, normal-level window owned by a game process.
    private static func firstGameWindow() -> (owner: String, pid: pid_t)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for entry in list {
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let owner = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let name = owner.lowercased()
            guard name.hasSuffix(".exe"), !infrastructureOwners.contains(name) else { continue }
            return (owner, pid)
        }
        return nil
    }
}
