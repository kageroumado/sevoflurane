import Foundation

/// The disk-touching half of the Storage pane, split from ``StorageStore`` so
/// a simulated environment can pose any library, any set of sizes, and any
/// set of linkable games — and can be walked all the way through the
/// uninstall, which on the live path ends by trashing the app itself.
@MainActor
protocol StorageEnvironment: AnyObject {
    /// Whether the effects are simulated.
    var isSimulation: Bool { get }

    func entries() -> [StorageInventory.Entry]
    func installedGames() -> [StorageInventory.Game]
    func size(of entry: StorageInventory.Entry) async -> Int64
    func trash(_ entry: StorageInventory.Entry) throws

    // MARK: - Added Windows programs

    func addedPrograms() -> [StorageInventory.Program]
    func size(of program: StorageInventory.Program) async -> Int64
    func remove(program: StorageInventory.Program) throws

    // MARK: - Shared game files

    /// Games in other bottles the active one could link.
    func linkable() -> [SharedGames.Candidate]
    func isLinked(appID: Int) -> Bool
    func linkGameFiles(_ candidate: SharedGames.Candidate) throws
    func writeManifest(_ candidate: SharedGames.Candidate) throws
    func removePendingLink(_ candidate: SharedGames.Candidate) throws
    func unlink(appID: Int) throws

    // MARK: - Uninstall

    /// Stands supervision down and stops every process in the bottle.
    func stopEverything(supervisor: ClientSupervisor?) async
    func trashBottle() throws
    /// The web session and caches that live outside the inventory's roots.
    func trashAppCaches()
    func removeAgentIntegration() async
    func forgetSettings()
    /// The app bundle itself, last — after this there is nothing left to run.
    func trashAppBundle()
}

extension StorageEnvironment {
    var isSimulation: Bool {
        false
    }
}

/// The real one: `du`, Steam's own manifests, `SharedGames`, and the Trash.
@MainActor
final class LiveStorageEnvironment: StorageEnvironment {
    func entries() -> [StorageInventory.Entry] {
        StorageInventory.entries()
    }

    func installedGames() -> [StorageInventory.Game] {
        StorageInventory.installedGames()
    }

    func size(of entry: StorageInventory.Entry) async -> Int64 {
        await StorageInventory.size(of: entry)
    }

    func trash(_ entry: StorageInventory.Entry) throws {
        try StorageInventory.trash(entry)
    }

    func addedPrograms() -> [StorageInventory.Program] {
        StorageInventory.addedPrograms()
    }

    func size(of program: StorageInventory.Program) async -> Int64 {
        await StorageInventory.size(of: program)
    }

    func remove(program: StorageInventory.Program) throws {
        try StorageInventory.remove(program: program)
    }

    func linkable() -> [SharedGames.Candidate] {
        SharedGames.linkable()
    }

    func isLinked(appID: Int) -> Bool {
        SharedGames.isLinked(appID: appID)
    }

    func linkGameFiles(_ candidate: SharedGames.Candidate) throws {
        try SharedGames.linkGameFiles(candidate)
    }

    func writeManifest(_ candidate: SharedGames.Candidate) throws {
        try SharedGames.writeManifest(candidate)
    }

    func removePendingLink(_ candidate: SharedGames.Candidate) throws {
        try SharedGames.removePendingLink(candidate)
    }

    func unlink(appID: Int) throws {
        try SharedGames.unlink(appID: appID)
    }

    /// Supervision stands down before anything stops: the restart ladder
    /// reads a stopped client as a crash and relaunches Steam into the bottle
    /// being trashed. The quit path already does the whole sequence — loop
    /// down, then every bottle process.
    func stopEverything(supervisor: ClientSupervisor?) async {
        if let supervisor {
            await supervisor.shutdownForQuit()
        } else {
            await ClientLifecycle.stopAll(gracePolls: 10)
        }
    }

    func trashBottle() throws {
        try FileManager.default.trashItem(at: SteamBottle.root, resultingItemURL: nil)
    }

    func trashAppCaches() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
        for path in ["WebKit/\(bundleID)", "Caches/\(bundleID)", "HTTPStorages/\(bundleID)"] {
            try? FileManager.default.trashItem(
                at: library.appendingPathComponent(path), resultingItemURL: nil,
            )
        }
    }

    func removeAgentIntegration() async {
        await AgentIntegration.remove(allowAdminPrompt: false)
    }

    func forgetSettings() {
        Preferences.reset()
    }

    func trashAppBundle() {
        try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
    }
}
