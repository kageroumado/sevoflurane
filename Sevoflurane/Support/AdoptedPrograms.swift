import Foundation

/// A Windows program the user handed to Sevoflurane, recorded in the settings
/// hierarchy beside the Steam games.
///
/// Everything downstream of a launch is keyed on one integer — the env file,
/// the launcher bundle, the renderer pin, the Games pane — so an adopted
/// program is given an id of its own out of a range Steam never reaches, and
/// then travels every path a game travels.
nonisolated struct AdoptedProgram: Codable, Equatable, Sendable {
    /// The executable, as a macOS path. It may live outside the bottle:
    /// `start /unix` reaches anything the prefix's `Z:` drive maps, which is
    /// the whole filesystem.
    var path: String
    /// Arguments handed to the program, one token each. A path with spaces
    /// is one token and is never quoted into another.
    var arguments: [String] = []
    /// The bottle it was adopted in.
    var bottle: String
    /// ``ProgramKind`` by raw value. Stored as text so a file written by a
    /// later version, naming a kind this one does not know, still reads.
    var kind: String
    var addedAt: Date
    /// A directory inside `drive_c` that an installer created, so Storage can
    /// account for it and take it away again.
    var installedRoot: String?

    var url: URL {
        URL(fileURLWithPath: path)
    }
    /// Whether the executable is still where it was adopted from.
    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// What kind of Windows program was adopted, which decides what the adoption
/// panel offers and how the menu bar lists it.
nonisolated enum ProgramKind {
    /// A game: it is played, and it belongs in Quick Launch.
    static let game = "game"
    /// An installer: it is run once, and what it leaves behind is the point.
    static let installer = "installer"
    /// Anything else that is worth keeping and starting again.
    static let program = "program"
    static let all = [game, installer, program]

    /// The word the interface uses for one.
    static func label(_ kind: String) -> String {
        switch kind {
        case game: "Game"
        case installer: "Installer"
        default: "Program"
        }
    }
}

/// The adopted programs: their id range, their records, and the two writes
/// that add and remove one.
///
/// Ids start at two billion. Steam's app ids are assigned sequentially and
/// are four orders of magnitude below that, so an adopted program can share
/// every store, every route and every scan with a game and never collide
/// with one.
nonisolated enum AdoptedPrograms {
    /// The first id an adopted program can take.
    static let firstID = 2_000_000_000

    /// Whether an id names an adopted program rather than a Steam app.
    static func isAdopted(_ id: Int) -> Bool {
        id >= firstID
    }

    /// One adopted program as the interface reads it.
    struct Entry: Identifiable, Sendable, Equatable {
        let id: Int
        let name: String
        let program: AdoptedProgram

        var kind: String {
            program.kind
        }
    }

    /// Every adopted program, by name.
    static func all() -> [Entry] {
        GameConfig.games()
            .compactMap { id, values in
                guard isAdopted(id), let program = values.program else { return nil }
                return Entry(
                    id: id,
                    name: values.name ?? program.url.lastPathComponent,
                    program: program,
                )
            }
            .sorted { first, second in
                let order = first.name.localizedStandardCompare(second.name)
                return order == .orderedSame ? first.id < second.id : order == .orderedAscending
            }
    }

    /// The record behind one id.
    static func program(_ id: Int) -> AdoptedProgram? {
        GameConfig.game(id).program
    }

    /// The entry behind one id.
    static func entry(_ id: Int) -> Entry? {
        let values = GameConfig.game(id)
        guard let program = values.program else { return nil }
        return Entry(
            id: id, name: values.name ?? program.url.lastPathComponent, program: program,
        )
    }

    /// The next free id: one past the highest in use, so an id is never
    /// reused after a removal and a stale launcher bundle can never be
    /// mistaken for a new program's.
    static func nextID() -> Int {
        nextID(after: GameConfig.games().keys)
    }

    /// The same rule against a given set of ids. Steam's own app ids are in
    /// the store too and are ignored: they are four orders of magnitude below
    /// ``firstID``.
    static func nextID(after used: some Sequence<Int>) -> Int {
        (used.filter(isAdopted).max().map { $0 + 1 }) ?? firstID
    }

    /// Records a program and answers the id it was given.
    ///
    /// The record fills `name` and `exes` as well, which is what makes
    /// ``ConfigMaterializer`` build the launcher bundle and write the env
    /// file: from that moment every per-game setting reaches it unchanged.
    @discardableResult
    static func adopt(
        exe url: URL,
        name: String? = nil,
        kind: String,
        arguments: [String] = [],
        bottle: String,
        installedRoot: String? = nil,
    ) -> Int {
        let id = nextID()
        var values = ConfigValues.empty
        values.name = name ?? suggestedName(for: url)
        values.exes = [url.lastPathComponent.lowercased()]
        values.program = AdoptedProgram(
            path: url.standardizedFileURL.path, arguments: arguments, bottle: bottle,
            kind: kind, addedAt: .now, installedRoot: installedRoot,
        )
        GameConfig.setGame(id, values)
        return id
    }

    /// Forgets a program: its record and the launcher bundle built from it.
    /// The files it was adopted from are the user's and stay where they are.
    static func remove(_ id: Int) {
        guard isAdopted(id) else { return }
        GameConfig.setGame(id, .empty)
        try? FileManager.default.removeItem(at: GameLaunchers.directory(appID: id))
    }

    /// The name to put on a program the user has not named: what its version
    /// resource calls it, else the file's own name without the extension.
    static func suggestedName(for url: URL) -> String {
        let info = PEResources.read(url)
        for candidate in [info?.productName, info?.fileDescription] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// The argument list that starts a program in the bottle.
    ///
    /// `start /unix` takes a macOS path and sets the working directory to the
    /// program's own folder, which is what a game that loads its data by
    /// relative path needs. Each argument stays its own token: a path with
    /// spaces quoted into one would reach the program as one word.
    static func invocation(_ program: AdoptedProgram) -> [String] {
        ["start", "/unix", program.path] + program.arguments
    }
}
