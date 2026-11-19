import Foundation

/// A Windows program the user handed to Sevoflurane, recorded in the settings
/// hierarchy beside the Steam games.
///
/// Given an id from a range Steam never reaches, it travels every path a game
/// does.
nonisolated struct AdoptedProgram: Codable, Equatable, Sendable {
    /// The executable's macOS path, anywhere `Z:` reaches.
    var path: String
    /// One token each, never quoted together.
    var arguments: [String] = []
    var bottle: String
    /// ``ProgramKind``, stored as text so a later version's kind still reads.
    var kind: String
    var addedAt: Date
    /// A `drive_c` directory an installer created, for Storage.
    var installedRoot: String?
    /// Whether it is listed in Steam's library as a non-Steam game
    /// (``SteamShortcuts``).
    var inSteamLibrary: Bool?
    /// The app id of the program's Steam shortcut.
    var steamShortcutID: Int?

    var url: URL {
        URL(fileURLWithPath: path)
    }
    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// What kind of Windows program was adopted.
nonisolated enum ProgramKind {
    /// Listed in Quick Launch.
    static let game = "game"
    /// Run once for what it leaves behind.
    static let installer = "installer"
    static let program = "program"
}

/// The adopted programs. Ids start at two billion, four orders of magnitude
/// above Steam's sequential app ids, so they share every store with games.
nonisolated enum AdoptedPrograms {
    /// The first id an adopted program can take.
    static let firstID = 2_000_000_000

    /// Whether an id names an adopted program rather than a Steam app.
    static func isAdopted(_ id: Int) -> Bool {
        id >= firstID
    }

    struct Entry: Identifiable, Sendable, Equatable {
        let id: Int
        let name: String
        let program: AdoptedProgram

        var kind: String {
            program.kind
        }
    }

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

    /// Changes one program's record in place.
    static func update(_ id: Int, _ change: (inout AdoptedProgram) -> Void) {
        var values = GameConfig.game(id)
        guard var program = values.program else { return }
        change(&program)
        guard program != values.program else { return }
        values.program = program
        GameConfig.setGame(id, values)
    }

    /// The entry behind one id.
    static func entry(_ id: Int) -> Entry? {
        let values = GameConfig.game(id)
        guard let program = values.program else { return nil }
        return Entry(
            id: id, name: values.name ?? program.url.lastPathComponent, program: program,
        )
    }

    /// One past the highest id in use, so a removed id and its stale launcher
    /// bundle are never reused.
    static func nextID() -> Int {
        nextID(after: GameConfig.games().keys)
    }

    /// The same rule against a given set of ids.
    static func nextID(after used: some Sequence<Int>) -> Int {
        (used.filter(isAdopted).max().map { $0 + 1 }) ?? firstID
    }

    /// Records a program and answers its id. `name` and `exes` make
    /// ``ConfigMaterializer`` build its bundle and env file; anything but an
    /// installer is listed in Steam's library.
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
            inSteamLibrary: kind != ProgramKind.installer,
        )
        GameConfig.setGame(id, values)
        return id
    }

    /// Forgets a program's record and launcher bundle; its files stay.
    static func remove(_ id: Int) {
        guard isAdopted(id) else { return }
        GameConfig.setGame(id, .empty)
        try? FileManager.default.removeItem(at: GameLaunchers.directory(appID: id))
    }

    /// The version resource's product name or description, else the file name.
    static func suggestedName(for url: URL) -> String {
        let info = PEResources.read(url)
        for candidate in [info?.productName, info?.fileDescription] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `start /unix` with the macOS path, which sets the working directory to
    /// the program's folder for relative data paths.
    static func invocation(_ program: AdoptedProgram) -> [String] {
        ["start", "/unix", program.path] + program.arguments
    }
}
