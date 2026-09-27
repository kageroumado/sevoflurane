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

/// Starting a Windows program that Steam knows nothing about.
///
/// The supervisor owns every bottle process, adopted programs included, so
/// these are its verbs rather than the app's or the CLI's: the app posts to
/// `/program/launch` and the daemon is the parent that appears in the process
/// tree, which is what lets the owner check and the restart ladder account for
/// it.
extension BottleSupervisor {
    /// How long a spawned program has to appear in `pgrep` before a new request
    /// for it is taken as a new launch rather than the extra click.
    static let spawnSettles: Duration = .seconds(60)

    /// Starts an adopted Windows program in the bottle.
    ///
    /// The env files are rewritten first, so the program's own window
    /// treatment, upscaler and launcher bundle are on disk before the process
    /// reads them, and the spawn goes through the same engine invocation as
    /// everything else. Answers a refusal, or `nil` when the program started.
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
        // companion launch made five prefixes and five games, 2026-09-26.
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
        stageGraphics(for: name, renderer: explicit, appID: id)
        programsSpawnedAt[id] = .now
        if SteamParent.wants(program) {
            if let refusal = await launchUnderSteamParent(program, id: id) {
                programsSpawnedAt[id] = nil
                return .failed(refusal)
            }
            return nil
        }
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        await ClientLifecycle.launchInBottle(AdoptedPrograms.invocation(program))
        note("started \(program.url.lastPathComponent) in \(SteamBottle.name)")
        return nil
    }

    /// Starts a program that needs a `steam.exe` parent (``SteamParent``) in
    /// the bottle's companion prefix, where no Steam client runs.
    ///
    /// The env files are written into the companion too, so the program's
    /// own settings and launcher bundle reach it there exactly as they would
    /// in the bottle. The working directory is the program's own folder,
    /// which the parent passes on to it. The parent exits with the program's
    /// own code, which is written to the Wine log for the run record
    /// (``ProgramExit``): Steam's process log never names a program of ours.
    private func launchUnderSteamParent(_ program: AdoptedProgram, id: Int) async -> String? {
        let name = program.url.lastPathComponent
        let engine = Engine.active
        if let refusal = await SteamParent.prepare(bottle: SteamBottle.name, engine: engine) {
            note("could not start \(name) under a steam.exe parent: \(refusal)")
            return refusal
        }
        let companion = SteamParent.prefix(for: SteamBottle.name)
        let environment = SteamParent.environment(bottle: SteamBottle.name, engine: engine)
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
        if let unlocker = FPSUnlocker.unlocker(for: program) {
            Task(name: "Start the frame-rate unlocker beside \(name)") {
                await startUnlocker(unlocker, beside: program, environment: environment)
            }
        }
        return nil
    }

    /// Starts the frame-rate unlocker (``FPSUnlocker``) in the companion once
    /// the game has been up for ``FPSUnlocker/delay``, and stops it when the
    /// game is gone if it has not stopped by itself.
    ///
    /// Never before the game: an unlocker process that exists while the game
    /// starts up makes it quit during its init (found with the launcher it
    /// was measured with, 2026-08-05).
    private func startUnlocker(
        _ unlocker: URL, beside program: AdoptedProgram, environment: [String: String],
    ) async {
        let game = program.url.lastPathComponent
        let own = unlocker.lastPathComponent
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
        if !FPSUnlocker.configure(unlocker, game: program, target: target) {
            note("\(own) has no fps_config.json yet; it starts with its own frame rate")
        }
        // Its window must never reach the screen: shown the moment it
        // starts, it took the foreground from the game, which minimized
        // itself into the Dock at its next display-mode change, entering the
        // world (2026-09-26). The engine's dock shim keeps a process with
        // SEVO_QUIET=1 off the screen and out of the Dock (Dormison's
        // `sevo_dock_shim.c`); an engine without that knob shows the window.
        var quiet = environment
        quiet["SEVO_QUIET"] = "1"
        await ClientLifecycle.launchInBottle(
            [SteamParent.windowsPath(unlocker.path)],
            environment: quiet,
            directory: unlocker.deletingLastPathComponent(),
        )
        note("started \(own) beside \(game), aiming for \(target) fps")
        // The unlocker quits with the game by itself; this is for the one
        // that does not, which would hold the companion's wineserver up.
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

    /// Puts the renderer a launch asked for into the engine tree.
    ///
    /// A program launched outside Steam gets a process tree of its own, so the
    /// renderer only has to be staged, never bounced: the DLLs it loads are
    /// the ones on disk when it starts.
    private func stageGraphics(for name: String, renderer explicit: Renderer?, appID: Int) {
        let desired = BottleGraphics.rendererToStage(forApp: appID, explicit: explicit)
        guard let desired, desired != BottleGraphics.currentSelection().renderer else { return }
        do {
            let current = BottleGraphics.currentSelection()
            try BottleGraphics.applyToActiveEngine(
                BottleGraphics.Selection(
                    renderer: desired, msync: current.msync, gpu: current.gpu,
                ),
            )
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
