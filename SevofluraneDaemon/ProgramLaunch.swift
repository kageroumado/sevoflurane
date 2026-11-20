import Foundation

/// Why `/program/launch` started nothing, which decides its HTTP status.
enum ProgramLaunchRefusal: Error, Equatable {
    /// No such program, or its file is gone: 404.
    case missing(String)
    /// It is starting or running already, so this request is the extra
    /// click: 409, which the app treats as done rather than failed.
    case busy(String)
    /// It could not be started: 500.
    case failed(String)

    var reason: String {
        switch self {
        case let .missing(reason), let .busy(reason), let .failed(reason): reason
        }
    }

    var status: Int {
        switch self {
        case .missing: 404
        case .busy: 409
        case .failed: 500
        }
    }
}

/// Starting a Windows program Steam knows nothing about: the daemon is its
/// parent, as for every bottle process.
extension BottleSupervisor {
    /// How long a spawned program has to appear in `pgrep` before a new request
    /// for it is taken as a new launch rather than the extra click.
    static let spawnSettles: Duration = .seconds(60)

    /// Starts an adopted Windows program, its env files written first.
    /// Answers a refusal, or `nil` when it started.
    func launchProgram(id: Int, renderer explicit: Renderer? = nil) async -> ProgramLaunchRefusal? {
        guard let program = AdoptedPrograms.program(id) else {
            return .missing("no adopted program with id \(id)")
        }
        guard program.exists else {
            return .missing("\(program.url.lastPathComponent) is no longer at \(program.path)")
        }
        let name = program.url.lastPathComponent
        // Checked and marked before the first await: the main actor runs
        // another request between awaits, and five clicks during a first
        // companion launch would make five prefixes and five games.
        guard programsStarting.insert(id).inserted else {
            note("\(name) is already starting; this request starts nothing")
            return .busy("\(name) is already starting")
        }
        defer { programsStarting.remove(id) }
        if let spawnedAt = programsSpawnedAt[id] {
            if ContinuousClock.now - spawnedAt < Self.spawnSettles, await !Self.isRunning(name) {
                note("\(name) was started \(Int((ContinuousClock.now - spawnedAt).components.seconds)) s ago and has not appeared yet; this request starts nothing")
                return .busy("\(name) is still starting")
            }
            programsSpawnedAt[id] = nil
        }
        if SteamParent.wants(program), await Self.isRunning(name) {
            // A second copy beside a running one sees another steam.exe
            // child and takes the kernel-driver path: it would only die.
            note("\(name) is already running; this request starts nothing")
            return .busy("\(name) is already running")
        }
        await prepareLaunch(appID: id)
        stageGraphics(for: name, renderer: explicit, appID: id)
        programsSpawnedAt[id] = .now
        let logOffset = KernelDriverFailure.size()
        if SteamParent.wants(program) {
            if let refusal = await launchUnderSteamParent(program, id: id) {
                programsSpawnedAt[id] = nil
                return .failed(refusal)
            }
            watchForKernelDriverFailure(name, id: id, from: logOffset)
            return nil
        }
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        await ClientLifecycle.launchInBottle(AdoptedPrograms.invocation(program))
        note("started \(program.url.lastPathComponent) in \(SteamBottle.name)")
        watchForKernelDriverFailure(name, id: id, from: logOffset)
        return nil
    }

    /// Reads Wine's log for a minute after a program starts. A kernel driver
    /// that failed to load while nothing of the program drew is noted, and
    /// the app explains it.
    private func watchForKernelDriverFailure(_ exe: String, id: Int, from offset: UInt64) {
        Task(name: "Watch \(exe) for a kernel driver failure") {
            guard let driver = await KernelDriverFailure.watch(from: offset, program: exe) else { return }
            note("\(exe) showed no window; it tried to load the kernel driver \(driver), which Wine cannot load")
            await app.announceKernelDriverFailure(programID: id, driver: driver)
        }
    }

    /// Starts a program that needs a `steam.exe` parent (``SteamParent``) in
    /// the bottle's companion prefix. The parent's exit code, the program's,
    /// goes to the run record through ``ProgramExit``: Steam's process log
    /// never names our programs.
    private func launchUnderSteamParent(_ program: AdoptedProgram, id: Int) async -> String? {
        let name = program.url.lastPathComponent
        let engine = Engine.active
        if let refusal = await SteamParent.prepare(bottle: SteamBottle.name, engine: engine) {
            note("could not start \(name) under a steam.exe parent: \(refusal)")
            return refusal
        }
        let companion = SteamParent.prefix(for: SteamBottle.name)
        let environment = SteamParent.environment(bottle: SteamBottle.name, engine: engine)
        if SteamParent.serverEngine(of: companion) != nil {
            await awaitLastSession(of: name, environment: environment, engine: engine)
        }
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: companion)
        // The parent names the program's exit with this id in its
        // `sevo:steam-parent exit` line, the full 32-bit code (ProgramExit).
        var parentEnvironment = environment
        parentEnvironment["SEVO_PROGRAM_APPID"] = String(id)
        await ClientLifecycle.launchInBottle(
            SteamParent.invocation(program),
            environment: parentEnvironment,
            directory: program.url.deletingLastPathComponent(),
            programExit: ProgramExit.Program(appID: id, exe: name),
        )
        note("started \(name) under a steam.exe parent in \(SteamBottle.name)'s companion prefix, where no Steam client runs")
        if let unlocker = FPSUnlocker.unlocker(for: program, engine: engine) {
            Task(name: "Start the frame-rate unlocker beside \(name)") {
                await startUnlocker(unlocker, beside: program, environment: environment)
            }
        }
        return nil
    }

    /// Waits for the companion's previous wineserver to exit: a HoYoverse game
    /// started into a lingering server takes the kernel-driver path and dies
    /// about twenty seconds in, in `MHYPBase.dll`. After
    /// ``SteamParent/lastSessionWait`` the launch goes ahead anyway.
    private func awaitLastSession(of name: String, environment: [String: String], engine: Engine) async {
        let started = ContinuousClock.now
        _ = await Subprocess.run(
            engine.wineserverURL.path, ["-w"], environment: environment, timeout: SteamParent.lastSessionWait,
        )
        if ContinuousClock.now - started >= SteamParent.lastSessionWait {
            note("the companion prefix still runs a program after \(SteamParent.lastSessionWait.components.seconds) s; starting \(name) beside it")
        } else {
            note("waited for the companion prefix's last session to end before starting \(name)")
        }
    }

    /// Starts the frame-rate unlocker (``FPSUnlocker``) once the game has been
    /// up for ``FPSUnlocker/delay``, and stops one that outlives the game.
    /// Never before: an unlocker present during the game's init makes it quit.
    private func startUnlocker(
        _ unlocker: FPSUnlocker.Unlocker, beside program: AdoptedProgram, environment: [String: String],
    ) async {
        let game = program.url.lastPathComponent
        let executable = unlocker.executable
        let own = executable.lastPathComponent
        let clock = ContinuousClock()
        let deadline = clock.now + FPSUnlocker.appearDeadline
        while await !Self.isRunning(game) {
            guard clock.now < deadline else {
                note("\(game) never appeared, so its frame-rate unlocker was not started")
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        try? await Task.sleep(for: FPSUnlocker.delay)
        guard await Self.isRunning(game) else { return }
        guard await !Self.isRunning(own) else {
            note("\(own) is already running beside \(game)")
            return
        }
        let target = FPSUnlocker.target
        // The engine's own takes the frame rate and how long to wait for the
        // game on its command line; the user's reads its fps_config.json.
        var arguments = [SteamParent.windowsPath(executable.path)]
        if unlocker.isSevoflurane {
            arguments += [String(target), String(Int(FPSUnlocker.appearDeadline.components.seconds))]
        } else if !FPSUnlocker.configure(executable, game: program, target: target) {
            note("\(own) has no fps_config.json yet; it starts with its own frame rate")
        }
        // Never on screen: its window takes the foreground, and the game then
        // minimizes itself at its next display-mode change. SEVO_QUIET=1 hides
        // it on engines whose dock shim (`sevo_dock_shim.c`) has the knob.
        var quiet = environment
        quiet["SEVO_QUIET"] = "1"
        await ClientLifecycle.launchInBottle(
            arguments,
            environment: quiet,
            directory: executable.deletingLastPathComponent(),
        )
        note("started \(own) beside \(game), aiming for \(target) fps")
        // One that outlives the game would hold the companion's wineserver up.
        while await Self.isRunning(game) {
            try? await Task.sleep(for: .seconds(10))
        }
        let left = await Self.pids(named: own)
        guard !left.isEmpty else { return }
        for pid in left { kill(pid, SIGTERM) }
        note("stopped \(own): \(game) is gone")
    }

    /// Whether a Windows program of that file name runs anywhere on this Mac.
    static func isRunning(_ name: String) async -> Bool {
        await !pids(named: name).isEmpty
    }

    static func pids(named name: String) async -> [pid_t] {
        let listing = await Subprocess.run("/usr/bin/pgrep", WineProcessList.pgrepArguments).output
        return WineProcessList.pids(named: name, inPgrepLong: listing)
    }

    /// Runs one Windows program to completion in the bottle and answers what
    /// it printed — the "run once" path, which records nothing.
    func runProgram(_ url: URL, arguments: [String], timeout: Duration) async
        -> (status: Int32?, output: String) {
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        return await ClientLifecycle.runInBottle(
            Self.onceInvocation(url, arguments: arguments), timeout: timeout,
        )
    }

    /// Starts one Windows program and returns as soon as it is spawned — a
    /// game played once, which has no useful exit to wait for.
    func startProgram(_ url: URL, arguments: [String]) async {
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        await ClientLifecycle.launchInBottle(Self.onceInvocation(url, arguments: arguments))
        note("started \(url.lastPathComponent) in \(SteamBottle.name)")
    }

    /// The argument list for a program that has no record of its own.
    private static func onceInvocation(_ url: URL, arguments: [String]) -> [String] {
        AdoptedPrograms.invocation(AdoptedProgram(
            path: url.standardizedFileURL.path, arguments: arguments,
            bottle: SteamBottle.name, kind: ProgramKind.program, addedAt: .now,
        ))
    }

    /// Readies a launch before its graphics are staged and its process
    /// spawned (``LaunchPreparation``). A first launch's fixes are said in
    /// the event log here and in a notification by the app.
    func prepareLaunch(appID: Int) async {
        let fixes = await LaunchPreparation.prepare(appID: appID) { EventLog.enqueue(.client, $0) }
        guard let fixes else { return }
        let name = GameConfig.game(appID).name ?? SharedGames.installed(appID: appID)?.name ?? "App \(appID)"
        note(fixes.logLine(appID: appID, name: name))
        Task(name: "Announce app \(appID)'s fixes") { await app.announceFixesApplied(appID: appID) }
    }

    /// Stages the renderer a launch asked for, which holds the bottle until
    /// the program's run ends; a program outside Steam has its own process
    /// tree, so no client restart is needed.
    private func stageGraphics(for name: String, renderer explicit: Renderer?, appID: Int) {
        let desired = BottleGraphics.rendererToStage(forApp: appID, explicit: explicit)
        guard let desired, desired != BottleGraphics.currentSelection().renderer else { return }
        do {
            try BottleGraphics.beginLaunchRenderer(desired, forApp: appID)
        } catch {
            note("could not set \(desired.label) for \(name): \(error)")
            return
        }
        if let staged = BottleGraphics.stagingNote(BottleGraphics.reconcileManagedTree()) {
            note(staged)
        }
    }

    private func note(_ message: String) {
        EventLog.shared.log(.client, message)
    }
}
