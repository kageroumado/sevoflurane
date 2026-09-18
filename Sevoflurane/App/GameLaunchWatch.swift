import AppKit
import CoreGraphics

/// Brings a freshly launched game's window to the front, and names the
/// processes the launch started.
///
/// Wine's processes are background apps to macOS, so a game window opens
/// *behind* whatever is frontmost — on Windows, Steam foregrounds the game.
/// Every launch path (menu bar, library Play button, `steam://run`) funnels
/// through `SteamClient.Apps.RunGame` on the bridge, which arms this watch;
/// the first on-screen window owned by a bottle process that is neither
/// client infrastructure nor another game's gets activated exactly once.
///
/// A window is the slower of the two supplies and the launches worth
/// diagnosing are the ones that never draw, so the watch also reads the dock
/// shim's chronicle (``WineChronicle``), which names every bottle process the
/// moment winemac.drv loads it.
@MainActor
final class GameLaunchWatch {
    /// How long a launch stays armed: game engines can take this long to put
    /// up their first real window (shader precompilation, updates).
    private static let armedFor: Duration = .seconds(180)
    private static let pollEvery: Duration = .seconds(1)

    /// Windows programs that are the client's own plumbing, never the game.
    /// Steam's dialogs surface under `steam.exe`/`steamwebhelper.exe`
    /// (`WineWindowWatch`), and the game's window belongs to the game's own
    /// exe.
    private static let infrastructureOwners = WineWindowWatch.gameInfrastructureOwners

    private var watch: Task<Void, Never>?
    private let activation = Activation()

    /// A window of the launch's own game is up — the host clears the
    /// launch-status line on it.
    var onGameWindowUp: ((_ owner: String) -> Void)?

    /// A bottle process the launch started reached winemac.drv, named by the
    /// shim's chronicle with the macOS pid it runs under. Fires whether or
    /// not that process ever draws.
    var onGameProcessArmed: ((_ exe: String, _ pid: pid_t) -> Void)?

    /// The window a launch may claim, and how its program was named.
    struct Sighting {
        let owner: String
        let pid: pid_t
        /// Whether the game is running through its own launcher bundle,
        /// which is what puts its name and icon in the Dock.
        let viaBundle: Bool
    }

    /// Arms (or re-arms) the watch; called when the bridge sees `RunGame` and
    /// when the client reports a launch starting, which is the path that
    /// knows which app it is.
    func noteLaunchRequested(appID: Int? = nil) {
        watch?.cancel()
        EventLog.shared.log(.window, "game launch requested — watching for its window")
        // From here on: what the shim wrote before this launch is another
        // launch's story.
        let chronicle = WineChronicleTail()
        watch = Task(name: "Game window watch") { [weak self] in
            let deadline = ContinuousClock.now + Self.armedFor
            var reported: Set<String> = []
            var programs = ProgramCache()
            while !Task.isCancelled, ContinuousClock.now < deadline {
                self?.noteArmedProcesses(chronicle.newEntries())
                let sighting = Self.firstGameWindow(launching: appID, programs: &programs) { line in
                    guard reported.insert(line).inserted else { return }
                    EventLog.shared.log(.window, line)
                }
                if let sighting {
                    await self?.activate(sighting)
                    return
                }
                try? await Task.sleep(for: Self.pollEvery)
            }
            guard !Task.isCancelled else { return }
            EventLog.shared.log(.window, "no game window in three minutes — no longer watching")
            // The right the launch took is spent or worthless by now, and the
            // Dock tile it came with belongs to a window that never arrived.
            ActivationPolicy.recedeIfLastWindow(closing: nil)
        }
    }

    /// The chronicle's `armed` lines name a launch's processes before any of
    /// them draws, which is the only record of a game that dies without a
    /// window.
    private func noteArmedProcesses(_ entries: [WineChronicle.Entry]) {
        for entry in entries where entry.verb == .armed {
            let exe = entry.executable.lowercased()
            // A game's own crash handler and installers load the driver too,
            // and a per-program env file for one of those would be a setting
            // written against the wrong process.
            guard WineWindowWatch.isGameProgram(exe), GameExecutables.isGameLike(exe) else {
                continue
            }
            onGameProcessArmed?(exe, entry.pid)
        }
    }

    /// Spends the activation right the launch took on the window that just
    /// arrived, then hands the policy back: an app whose last window is a
    /// game's belongs in the menu bar, not the Dock.
    ///
    /// The launch's own story ends the moment the window is up, so the
    /// callback fires before the activation, which can take five seconds.
    private func activate(_ game: Sighting) async {
        GameDisplayHold.gameDidAppear()
        onGameWindowUp?(game.owner)
        let bundled = game.viaBundle ? ", via its own bundle" : ""
        EventLog.shared.log(.window, "game window up (\(game.owner))\(bundled)")
        let front = await activation.bringForward(
            pid: game.pid, describedAs: "game \(game.owner)",
        )
        EventLog.shared.log(
            .window,
            front
                ? "brought \(game.owner) to the front"
                : "\(game.owner) is not frontmost — macOS declined the activation",
        )
        ActivationPolicy.recedeIfLastWindow(closing: nil)
    }

    /// What a pid is running, kept for as long as one launch is watched:
    /// reading a process's command line costs a `KERN_ARGMAX` buffer, and the
    /// answer cannot change while the process lives. A pid reused by another
    /// process inside the same three minutes would be named after the dead
    /// one, which costs a wrong name in a log line.
    struct ProgramCache {
        private var programs: [pid_t: WineWindowWatch.Program?] = [:]

        mutating func program(owner: String, pid: pid_t) -> WineWindowWatch.Program? {
            if let known = programs[pid] { return known }
            let resolved = WineWindowWatch.resolve(owner: owner, pid: pid)
            programs[pid] = resolved
            return resolved
        }
    }

    /// Whether a game's window is on screen — the updater's gate reads it
    /// that way.
    static func firstGameWindow() -> (owner: String, pid: pid_t)? {
        var programs = ProgramCache()
        return firstGameWindow(launching: nil, programs: &programs).map { ($0.owner, $0.pid) }
    }

    /// The first window on screen that this launch may claim.
    ///
    /// A window whose program another game has already recorded is that
    /// game's — a launch that never draws must not adopt a bystander's
    /// window, and the caller keeps polling for its own. Every window that is
    /// not this launch's is handed to `report` with the reason it was passed
    /// over: which of the tests refuses a window that the shim did put on
    /// screen is otherwise unknowable after the fact.
    static func firstGameWindow(
        launching appID: Int?,
        programs: inout ProgramCache,
        report: (String) -> Void = { _ in },
    ) -> Sighting? {
        // Windows the window server keeps but does not show are listed too,
        // so a game that puts one up without ever showing it is reported
        // rather than silently passed over.
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for entry in list {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let program = programs.program(owner: owner, pid: pid) else { continue }
            // A window of some Mac application: there are dozens of those on
            // any Mac, and none of them is a game.
            guard program.source != .owner || program.name.hasSuffix(".exe") else { continue }
            guard program.name.hasSuffix(".exe") else {
                report("\(program.name) (pid \(pid)) is not an .exe — not a game window")
                continue
            }
            guard !infrastructureOwners.contains(program.name) else {
                report("game window (\(program.name)) is the client's own — still waiting")
                continue
            }
            guard entry[kCGWindowIsOnscreen as String] as? Bool ?? false else {
                report("game window (\(program.name)) is not on screen — still waiting")
                continue
            }
            if let appID, let claimant = GameConfig.app(claiming: program.name), claimant != appID {
                report("game window (\(program.name)) belongs to app \(claimant) — still waiting")
                continue
            }
            return Sighting(
                owner: program.name, pid: pid, viaBundle: program.source == .bundle,
            )
        }
        return nil
    }
}
