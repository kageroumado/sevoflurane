import Foundation

/// Store titles as adopted programs: an installed Epic or GOG game gets a
/// program record (``AdoptedProgram/store``) so that Quick Launch, its Dock
/// tile, its per-game settings and its run records treat it like any other
/// game, and every launch asks the store for that launch's arguments.
nonisolated enum StoreLibrary {
    /// The adopted program of a store title, if it has one.
    static func program(for store: GameStore, id: String) -> AdoptedPrograms.Entry? {
        AdoptedPrograms.all().first { $0.program.store == StoreLink(store: store, id: id) }
    }

    /// Records an installed title as a game, or points its existing record
    /// at what `plan` says starts it now. Answers the program's id.
    @discardableResult
    static func adopt(_ install: StoreInstall, plan: StoreLaunchPlan, bottle: String) -> Int {
        let link = StoreLink(store: install.store, id: install.id)
        let exe = URL(fileURLWithPath: plan.executable)
        if let existing = program(for: install.store, id: install.id) {
            var values = GameConfig.game(existing.id)
            values.program?.path = exe.standardizedFileURL.path
            values.program?.arguments = plan.arguments
            values.program?.workingDirectory = workingDirectory(plan)
            values.exes = [exe.lastPathComponent.lowercased()]
            GameConfig.setGame(existing.id, values)
            return existing.id
        }
        let id = AdoptedPrograms.adopt(
            exe: exe, name: install.title, kind: ProgramKind.game, arguments: plan.arguments, bottle: bottle,
        )
        var values = GameConfig.game(id)
        values.program?.workingDirectory = workingDirectory(plan)
        values.program?.store = link
        GameConfig.setGame(id, values)
        return id
    }

    /// Removes the program record of a title that is no longer installed.
    static func release(_ store: GameStore, id: String) {
        guard let entry = program(for: store, id: id) else { return }
        AdoptedPrograms.remove(entry.id)
    }

    /// The program as this launch should start it.
    ///
    /// An Epic game is asked of legendary each time, because its sign-in
    /// code is good for one launch only; a GOG game's play task is read
    /// again from its folder, where an update may have changed it. When the
    /// store cannot answer, the record starts as it was last written.
    static func refreshed(_ program: AdoptedProgram) async -> (program: AdoptedProgram, note: String?) {
        guard let link = program.store else { return (program, nil) }
        let plan: StoreLaunchPlan?
        var note: String?
        switch link.store {
        case .epic:
            do {
                plan = try await Legendary.launchPlan(link.id)
            } catch {
                plan = nil
                note = "legendary gave no launch arguments for \(link.id), so it starts without Epic's sign-in: \(error)"
            }
        case .gog:
            plan = GOG.launchPlan(link.id, folder: URL(fileURLWithPath: installFolder(of: program, gog: link.id)))
        }
        guard let plan else { return (program, note) }
        var refreshed = program
        refreshed.path = URL(fileURLWithPath: plan.executable).standardizedFileURL.path
        refreshed.arguments = plan.arguments
        refreshed.workingDirectory = workingDirectory(plan)
        return (refreshed, note)
    }

    /// The recorded folder of a GOG install, else the executable's own.
    private static func installFolder(of program: AdoptedProgram, gog id: String) -> String {
        GOG.installed().first { $0.id == id }?.path ?? program.url.deletingLastPathComponent().path
    }

    /// The plan's working folder, kept only where it differs from the
    /// executable's, which is where `start /unix` starts a program anyway.
    private static func workingDirectory(_ plan: StoreLaunchPlan) -> String? {
        let own = URL(fileURLWithPath: plan.executable).deletingLastPathComponent().standardizedFileURL.path
        let wanted = URL(fileURLWithPath: plan.workingDirectory).standardizedFileURL.path
        return wanted == own ? nil : wanted
    }
}
