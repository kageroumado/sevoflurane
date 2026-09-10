import Foundation

/// Starting a Windows program that Steam knows nothing about.
///
/// The supervisor owns every bottle process, adopted programs included, so
/// these are its verbs rather than the app's or the CLI's: the app posts to
/// `/program/launch` and the daemon is the parent that appears in the process
/// tree, which is what lets the owner check and the restart ladder account for
/// it.
extension BottleSupervisor {
    /// Starts an adopted Windows program in the bottle.
    ///
    /// The env files are rewritten first, so the program's own window
    /// treatment, upscaler and launcher bundle are on disk before the process
    /// reads them, and the spawn goes through the same engine invocation as
    /// everything else. Answers a refusal, or `nil` when the program started.
    func launchProgram(id: Int, renderer explicit: Renderer? = nil) async -> String? {
        guard let program = AdoptedPrograms.program(id) else {
            return "no adopted program with id \(id)"
        }
        guard program.exists else {
            return "\(program.url.lastPathComponent) is no longer at \(program.path)"
        }
        stageGraphics(for: program.url.lastPathComponent, renderer: explicit, appID: id)
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        await ClientLifecycle.launchInBottle(AdoptedPrograms.invocation(program))
        note("started \(program.url.lastPathComponent) in \(SteamBottle.name)")
        return nil
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
        let desired = explicit ?? BottleGraphics.overrides()[appID]?.renderer
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
