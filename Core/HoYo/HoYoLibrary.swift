import Foundation

/// The HoYoverse game folders Sevoflurane keeps current: every folder it
/// installed or updated a game in, and every added program that is one of
/// these games.
///
/// The folders live in the shared settings suite, so a game installed from
/// `sevo` shows in the app and the other way round.
nonisolated enum HoYoLibrary {
    static let foldersKey = "hoyoFolders"

    /// Every known installation, one per folder, in the order they were
    /// added. A folder whose game is gone is left out.
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

    /// Adds an installed game to Quick Launch unless it is there already or
    /// is one Sevoflurane cannot start. Answers the program's id.
    @discardableResult
    static func addToQuickLaunch(_ installation: HoYoInstallation, bottle: String) -> Int? {
        guard installation.game.launches else { return nil }
        let exe = installation.folder.appending(path: installation.game.executable).standardizedFileURL
        if let existing = AdoptedPrograms.all().first(where: { $0.program.url.standardizedFileURL == exe }) {
            return existing.id
        }
        return AdoptedPrograms.adopt(
            exe: exe, name: installation.game.displayName, kind: ProgramKind.game, bottle: bottle,
        )
    }
}
