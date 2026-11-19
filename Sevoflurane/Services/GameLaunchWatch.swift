import AppKit
import CoreGraphics

/// Brings a freshly launched game's window to the front, and names the
/// processes the launch started.
///
/// Wine's processes are background apps to macOS, so a game window opens behind
/// whatever is frontmost. `SteamClient.Apps.RunGame` on the bridge and the
/// client's launch-start report arm this watch; the first on-screen window of a
/// bottle process that is neither client infrastructure nor another game's is
/// activated once. It also reads the dock shim's chronicle (``WineChronicle``),
/// which names each bottle process as winemac.drv loads it, since the launches
/// worth diagnosing never draw.
@MainActor
final class GameLaunchWatch {
    /// How long a launch stays armed: a first real window can take this long
    /// (shader precompilation, updates).
    private static let armedFor: Duration = .seconds(180)
    private static let pollEvery: Duration = .seconds(1)

    /// Windows programs that are the client's own plumbing (`steam.exe`,
    /// `steamwebhelper.exe`), never the game.
    private nonisolated static let infrastructureOwners = WineWindowWatch.gameInfrastructureOwners

    /// How recent an arm's chronicle tail must be for the next arm to read on
    /// from it. `RunGame` and the launch-start report arm one launch a moment
    /// apart, and a fresh tail would skip what the shim wrote between them.
    private static let tailReuseWindow: Duration = .seconds(10)
    /// How long a press's tail waits for the helper's reply; a first companion
    /// launch takes about a quarter of a minute.
    private static let pressedTailLife: Duration = .seconds(300)

    private var watch: Task<Void, Never>?
    private var lastTail: (tail: WineChronicleTail, startedAt: ContinuousClock.Instant)?
    /// The chronicle's end when a program was pressed, for the watch its launch
    /// arms after the helper answers: the process can appear before the reply
    /// arrives.
    private var pressedTail: (tail: WineChronicleTail, startedAt: ContinuousClock.Instant)?

    /// A program was pressed; the helper has not answered yet.
    func noteLaunchPressed() {
        pressedTail = (WineChronicleTail(), .now)
    }
    private let activation = Activation()

    /// A window of the launch's own game is up.
    var onGameWindowUp: ((_ owner: String) -> Void)?

    /// A launch's bottle process reached winemac.drv, named by the chronicle
    /// with its macOS pid, whether or not it ever draws.
    var onGameProcessArmed: ((_ exe: String, _ pid: pid_t) -> Void)?

    /// The window a launch may claim, and how its program was named.
    nonisolated struct Sighting: Sendable {
        let owner: String
        let pid: pid_t
        /// Whether the game runs through its own launcher bundle, which puts
        /// its name and icon in the Dock.
        let viaBundle: Bool
    }

    /// Arms (or re-arms) the watch, from the bridge's `RunGame` and from the
    /// client's launch-start report, which knows the app.
    func noteLaunchRequested(appID: Int? = nil) {
        let previous = watch
        previous?.cancel()
        EventLog.shared.log(.window, "game launch requested — watching for its window")
        // What the shim wrote before this launch belongs to another launch.
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
            // The launch's activation right and its Dock tile belong to a
            // window that never arrived.
            ActivationPolicy.recedeIfLastWindow(closing: nil)
        }
    }

    /// One watch's working state, handed to one tick at a time.
    private final nonisolated class Scan: @unchecked Sendable {
        let chronicle: WineChronicleTail
        let appID: Int?
        var programs = ProgramCache()
        var attributions = ProcessAttributions()
        var reported: Set<String> = []

        init(chronicle: WineChronicleTail, appID: Int?) {
            self.chronicle = chronicle
            self.appID = appID
        }
    }

    private nonisolated struct Tick: Sendable {
        let entries: [WineChronicle.Entry]
        let passedOver: [String]
        let sighting: Sighting?
    }

    /// Off the main actor: every tick copies the window list, offscreen windows
    /// included, and a new pid costs a process-arguments read.
    @concurrent
    private nonisolated static func tick(_ scan: Scan) async -> Tick {
        let entries = scan.chronicle.newEntries()
        var passedOver: [String] = []
        let sighting = firstGameWindow(
            launching: scan.appID, programs: &scan.programs, attributions: &scan.attributions,
        ) { line in
            if scan.reported.insert(line).inserted { passedOver.append(line) }
        }
        return Tick(entries: entries, passedOver: passedOver, sighting: sighting)
    }

    /// The chronicle's `armed` lines are the only record of a game that dies
    /// without a window.
    private func noteArmedProcesses(_ entries: [WineChronicle.Entry]) {
        for entry in entries where entry.verb == .armed {
            guard let exe = Self.launchProcess(named: entry.executable) else { continue }
            onGameProcessArmed?(exe, entry.pid)
        }
    }

    /// The lowercased name of a bottle process that can be the launch's own, or
    /// `nil`: Steam's client and probes, Wine's services, and a game's crash
    /// handler or installer also load the driver, and must not get the run
    /// record or env file.
    nonisolated static func launchProcess(named executable: String) -> String? {
        let exe = executable.lowercased()
        guard WineWindowWatch.isGameProgram(exe), GameExecutables.isGameLike(exe), !isHelper(exe) else { return nil }
        return exe
    }

    /// A program the app runs beside a game, the frame-rate unlocker
    /// (``FPSUnlocker``); never the game.
    nonisolated static func isHelper(_ exe: String) -> Bool {
        let name = exe.lowercased()
        if name == FPSUnlocker.ownName { return true }
        guard let unlocker = FPSUnlocker.executable?.lastPathComponent.lowercased() else { return false }
        return name == unlocker
    }

    /// Spends the launch's activation right on the window that just arrived,
    /// then lets the app recede to the menu bar. The callback fires first,
    /// since the activation can take five seconds.
    private func activate(_ game: Sighting) async {
        GameDisplayHold.gameDidAppear(for: "\(game.owner) (pid \(game.pid))")
        onGameWindowUp?(game.owner)
        let bundled = game.viaBundle ? ", via its own bundle" : ""
        EventLog.shared.log(.window, "game window up (\(game.owner))\(bundled)")
        // Logged now, so a report that the sound never started names the
        // device.
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

    /// What a pid is running, cached for one watch: a command-line read costs a
    /// `KERN_ARGMAX` buffer. A pid reused within the watch keeps the dead
    /// process's name.
    ///
    /// A macOS build is matched against the sessions before the cache, since
    /// its window can be listed before its supervisor's file is written.
    nonisolated struct ProgramCache {
        private var programs: [pid_t: WineWindowWatch.Program?] = [:]

        mutating func program(
            owner: String, pid: pid_t, sessions: [NativeSessions.Session],
        ) -> WineWindowWatch.Program? {
            if let build = WineWindowWatch.macOSBuild(of: pid, sessions: sessions) { return build }
            if let known = programs[pid] { return known }
            let resolved = GameLaunchWatch.isHelper(owner)
                ? nil : WineWindowWatch.resolve(owner: owner, pid: pid, sessions: [])
            programs[pid] = resolved
            return resolved
        }
    }

    /// Which app the engine says each bottle process is, from the `sevo:run`
    /// line winemac.drv writes to the Wine log (``WineProvenance``). Cached per
    /// pid: the line precedes any window, and a process's app id cannot change.
    nonisolated struct ProcessAttributions {
        /// Lines of the log's end read for a pid's line, which is written as
        /// the driver loads.
        private static let linesRead = 10_000
        private var known: [pid_t: Int?] = [:]
        private let log: URL

        init(log: URL = WineLog.fileURL) {
            self.log = log
        }

        /// The app id the engine attributed `pid` to, or `nil` without one.
        mutating func appID(of pid: pid_t) -> Int? {
            if let answer = known[pid] { return answer }
            let lines = LogTail.lastLines(of: log, count: Self.linesRead) ?? []
            let answer = WineProvenance.appID(forProcess: Int(pid), in: lines.joined(separator: "\n"))
            known[pid] = .some(answer)
            return answer
        }
    }

    /// Whose a bottle process's window is, for a launch, and which test said
    /// so.
    nonisolated enum WindowOwnership: Equatable, Sendable {
        /// The launch's own.
        case launch
        /// Another game's: its app id, and the test that named it.
        case other(appID: Int, decidedBy: String)
    }

    /// Whose the window of `exe` (lowercased) running as `pid` is, for a launch
    /// of `appID`. The engine's attribution decides when there is one;
    /// otherwise the launching game's recorded exes, then any game in `games`
    /// that recorded it, else the launch.
    nonisolated static func ownership(
        ofWindowFrom exe: String, pid: pid_t, launching appID: Int, attributed: Int?, games: [Int: ConfigValues],
    ) -> WindowOwnership {
        if let attributed {
            return attributed == appID
                ? .launch
                : .other(appID: attributed, decidedBy: "the engine attributed pid \(pid) to app \(attributed)")
        }
        if games[appID]?.exes?.contains(exe) == true { return .launch }
        guard let recorded = GameConfig.app(claiming: exe, in: games) else { return .launch }
        return .other(
            appID: recorded,
            decidedBy: "app \(recorded) recorded \(exe), and the engine wrote no app id for pid \(pid)",
        )
    }

    /// Whether a game's window is on screen, for the updater's gate.
    nonisolated static func firstGameWindow() -> (owner: String, pid: pid_t)? {
        var programs = ProgramCache()
        var attributions = ProcessAttributions()
        return firstGameWindow(launching: nil, programs: &programs, attributions: &attributions)
            .map { ($0.owner, $0.pid) }
    }

    /// The first window on screen that this launch may claim.
    ///
    /// A window the engine attributed to another game, or whose program another
    /// game recorded, is that game's: a launch that never draws must not adopt
    /// a bystander's window. Every window passed over goes to `report` with the
    /// reason.
    nonisolated static func firstGameWindow(
        launching appID: Int?,
        programs: inout ProgramCache,
        attributions: inout ProcessAttributions,
        report: (String) -> Void = { _ in },
    ) -> Sighting? {
        // Read once per pass, at the first window that needs it.
        var games: [Int: ConfigValues]?
        let sessions = NativeSessions.live()
        // Hidden windows are listed too, so one never shown is reported rather
        // than passed over.
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for entry in list {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let program = programs.program(owner: owner, pid: pid, sessions: sessions) else { continue }
            // A Mac application's window.
            guard program.source != .owner || program.name.hasSuffix(".exe") else { continue }
            guard program.name.hasSuffix(".exe") || program.source == .macOSBuild else {
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
                let claim: WindowOwnership
                if program.source == .macOSBuild {
                    claim = program.appID.map { session -> WindowOwnership in
                        session == appID
                            ? .launch : .other(appID: session, decidedBy: "its native session is app \(session)'s")
                    } ?? .launch
                } else {
                    let known = games ?? GameConfig.claimingGames()
                    games = known
                    claim = ownership(
                        ofWindowFrom: program.name.lowercased(), pid: pid, launching: appID,
                        attributed: attributions.appID(of: pid), games: known,
                    )
                }
                if case let .other(claimant, decidedBy) = claim {
                    report("game window (\(program.name)) belongs to app \(claimant): \(decidedBy) — still waiting")
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
