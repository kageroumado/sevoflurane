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
    private nonisolated static let infrastructureOwners = WineWindowWatch.gameInfrastructureOwners

    /// How recent an arm's chronicle tail has to be for the next arm to read
    /// on from it. The bridge's `RunGame` and the client's launch-start report
    /// arm the same launch a moment apart, and a fresh tail for the second
    /// would skip what the shim wrote between them.
    private static let tailReuseWindow: Duration = .seconds(10)
    /// How long a press's tail waits for the helper's reply: a first
    /// companion launch takes about a quarter of a minute to answer.
    private static let pressedTailLife: Duration = .seconds(300)

    private var watch: Task<Void, Never>?
    private var lastTail: (tail: WineChronicleTail, startedAt: ContinuousClock.Instant)?
    /// The chronicle's end at the moment a program was pressed, for the watch
    /// its launch arms once the helper has answered: the process can appear
    /// before the reply is handled, and its lines would otherwise be behind
    /// the tail.
    private var pressedTail: (tail: WineChronicleTail, startedAt: ContinuousClock.Instant)?

    /// A program was pressed; the helper has not answered yet.
    func noteLaunchPressed() {
        pressedTail = (WineChronicleTail(), .now)
    }
    private let activation = Activation()

    /// A window of the launch's own game is up — the host clears the
    /// launch-status line on it.
    var onGameWindowUp: ((_ owner: String) -> Void)?

    /// A bottle process the launch started reached winemac.drv, named by the
    /// shim's chronicle with the macOS pid it runs under. Fires whether or
    /// not that process ever draws.
    var onGameProcessArmed: ((_ exe: String, _ pid: pid_t) -> Void)?

    /// The window a launch may claim, and how its program was named.
    nonisolated struct Sighting: Sendable {
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
        let previous = watch
        previous?.cancel()
        EventLog.shared.log(.window, "game launch requested — watching for its window")
        // From here on: what the shim wrote before this launch is another
        // launch's story.
        let now = ContinuousClock.now
        let chronicle: WineChronicleTail
        if let pressedTail, now - pressedTail.startedAt < Self.pressedTailLife {
            chronicle = pressedTail.tail
            self.pressedTail = nil
            lastTail = (chronicle, now)
        } else if let lastTail, now - lastTail.startedAt < Self.tailReuseWindow {
            chronicle = lastTail.tail
        } else {
            chronicle = WineChronicleTail()
            lastTail = (chronicle, now)
        }
        watch = Task(name: "Game window watch") { [weak self] in
            // The previous watch may be mid-scan on the same tail.
            await previous?.value
            let scan = Scan(chronicle: chronicle, appID: appID)
            let deadline = ContinuousClock.now + Self.armedFor
            while !Task.isCancelled, ContinuousClock.now < deadline {
                let tick = await Self.tick(scan)
                guard !Task.isCancelled else { return }
                for line in tick.passedOver {
                    EventLog.shared.log(.window, line)
                }
                self?.noteArmedProcesses(tick.entries)
                if let sighting = tick.sighting {
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

    /// One watch's working state. Only that watch's loop holds it, and it
    /// hands it to one tick at a time.
    private final nonisolated class Scan: @unchecked Sendable {
        let chronicle: WineChronicleTail
        let appID: Int?
        var programs = ProgramCache()
        var reported: Set<String> = []

        init(chronicle: WineChronicleTail, appID: Int?) {
            self.chronicle = chronicle
            self.appID = appID
        }
    }

    /// What one tick found: the chronicle's new lines, the windows passed
    /// over for the first time and why, and the window the launch may claim.
    private nonisolated struct Tick: Sendable {
        let entries: [WineChronicle.Entry]
        let passedOver: [String]
        let sighting: Sighting?
    }

    /// Reads the chronicle and the window list, and resolves each window's
    /// program. Off the main actor: every tick copies the window list,
    /// offscreen windows included, and a new pid costs a process-arguments
    /// read.
    @concurrent
    private nonisolated static func tick(_ scan: Scan) async -> Tick {
        let entries = scan.chronicle.newEntries()
        var passedOver: [String] = []
        let sighting = firstGameWindow(launching: scan.appID, programs: &scan.programs) { line in
            if scan.reported.insert(line).inserted { passedOver.append(line) }
        }
        return Tick(entries: entries, passedOver: passedOver, sighting: sighting)
    }

    /// The chronicle's `armed` lines name a launch's processes before any of
    /// them draws, which is the only record of a game that dies without a
    /// window.
    private func noteArmedProcesses(_ entries: [WineChronicle.Entry]) {
        for entry in entries where entry.verb == .armed {
            guard let exe = Self.launchProcess(named: entry.executable) else { continue }
            onGameProcessArmed?(exe, entry.pid)
        }
    }

    /// The lowercased name of a bottle process that can be the launch's own,
    /// or `nil` for one that never is: Steam's client and its probes, Wine's
    /// services, and a game's crash handler or installer all load the driver
    /// too, and a run record or a per-program env file named after one of
    /// those is written against the wrong process.
    nonisolated static func launchProcess(named executable: String) -> String? {
        let exe = executable.lowercased()
        guard WineWindowWatch.isGameProgram(exe), GameExecutables.isGameLike(exe), !isHelper(exe) else { return nil }
        return exe
    }

    /// A program the app itself runs beside a game: the frame-rate unlocker,
    /// the engine's own or the one the user picked (``FPSUnlocker``). Its
    /// process and window are never the game's.
    nonisolated static func isHelper(_ exe: String) -> Bool {
        let name = exe.lowercased()
        if name == FPSUnlocker.ownName { return true }
        guard let unlocker = FPSUnlocker.executable?.lastPathComponent.lowercased() else { return false }
        return name == unlocker
    }

    /// Spends the activation right the launch took on the window that just
    /// arrived, then hands the policy back: an app whose last window is a
    /// game's belongs in the menu bar, not the Dock.
    ///
    /// The launch's own story ends the moment the window is up, so the
    /// callback fires before the activation, which can take five seconds.
    private func activate(_ game: Sighting) async {
        GameDisplayHold.gameDidAppear(for: "\(game.owner) (pid \(game.pid))")
        onGameWindowUp?(game.owner)
        let bundled = game.viaBundle ? ", via its own bundle" : ""
        EventLog.shared.log(.window, "game window up (\(game.owner))\(bundled)")
        // The device the game's sound is about to open, named while the
        // launch is still the subject, so a log that says the sound never
        // started also says which device it was going to.
        EventLog.shared.log(
            .app,
            "audio out: \(HostSnapshot.defaultAudioOutput()?.summary ?? "no output device")",
        )
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
    nonisolated struct ProgramCache {
        private var programs: [pid_t: WineWindowWatch.Program?] = [:]

        mutating func program(owner: String, pid: pid_t) -> WineWindowWatch.Program? {
            if let known = programs[pid] { return known }
            let resolved = GameLaunchWatch.isHelper(owner) ? nil : WineWindowWatch.resolve(owner: owner, pid: pid)
            programs[pid] = resolved
            return resolved
        }
    }

    /// Whether a game's window is on screen — the updater's gate reads it
    /// that way.
    nonisolated static func firstGameWindow() -> (owner: String, pid: pid_t)? {
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
    nonisolated static func firstGameWindow(
        launching appID: Int?,
        programs: inout ProgramCache,
        report: (String) -> Void = { _ in },
    ) -> Sighting? {
        // Read once per pass, at the first window that needs it: which game
        // claims an exe is a directory of config files.
        var games: [Int: ConfigValues]?
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
            if let appID {
                let known = games ?? GameConfig.games()
                games = known
                let exe = program.name.lowercased()
                if let claimant = known.first(where: { $0.value.exes?.contains(exe) == true })?.key,
                   claimant != appID {
                    report("game window (\(program.name)) belongs to app \(claimant) — still waiting")
                    continue
                }
            }
            return Sighting(
                owner: program.name, pid: pid, viaBundle: program.source == .bundle,
            )
        }
        return nil
    }
}
