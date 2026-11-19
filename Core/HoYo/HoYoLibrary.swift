import Foundation

/// The HoYoverse game folders Sevoflurane keeps current, recorded in the
/// shared suite, plus adopted programs that are one of these games.
nonisolated enum HoYoLibrary {
    static let foldersKey = "hoyoFolders"

    /// Every installation still present, one per folder, in order added.
    static func installations(in defaults: UserDefaults = Preferences.shared) -> [HoYoInstallation] {
        let recorded = (defaults.stringArray(forKey: foldersKey) ?? []).map { URL(fileURLWithPath: $0) }
        let adopted = AdoptedPrograms.all().map { $0.program.url.deletingLastPathComponent() }
        var seen = Set<String>()
        return (recorded + adopted).compactMap { folder in
            let folder = folder.standardizedFileURL
            guard seen.insert(folder.path).inserted else { return nil }
            return HoYoInstallation(folder: folder)
        }
    }

    /// Records a folder so the app lists it.
    static func remember(_ folder: URL, in defaults: UserDefaults = Preferences.shared) {
        let path = folder.standardizedFileURL.path
        let folders = defaults.stringArray(forKey: foldersKey) ?? []
        guard !folders.contains(path) else { return }
        defaults.set(folders + [path], forKey: foldersKey)
    }

    /// Stops listing a folder. Its files stay where they are.
    static func forget(_ folder: URL, in defaults: UserDefaults = Preferences.shared) {
        let path = folder.standardizedFileURL.path
        defaults.set((defaults.stringArray(forKey: foldersKey) ?? []).filter { $0 != path }, forKey: foldersKey)
    }

    /// Adds a startable game to Quick Launch once; answers the program's id.
    @discardableResult
    static func addToQuickLaunch(_ installation: HoYoInstallation, bottle: String) -> Int? {
        guard installation.game.launches else { return nil }
        let exe = installation.folder.appending(path: installation.game.executable).standardizedFileURL
        if let existing = AdoptedPrograms.all().first(where: { $0.program.url.standardizedFileURL == exe }) {
            // A hand-adopted program is named after the exe's stem.
            if existing.name == exe.deletingPathExtension().lastPathComponent {
                var values = GameConfig.game(existing.id)
                values.name = installation.game.displayName
                GameConfig.setGame(existing.id, values)
            }
            return existing.id
        }
        return AdoptedPrograms.adopt(
            exe: exe, name: installation.game.displayName, kind: ProgramKind.game, bottle: bottle,
        )
    }
}
