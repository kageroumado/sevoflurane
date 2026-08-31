import Foundation

/// What the Storage pane shows, and the only thing that removes any of it.
///
/// Live or preview, the same shape — the gallery draws this pane too, and a
/// preview that could empty a games library would be a poor kind of preview.
@MainActor
@Observable
final class StorageStore {
    private(set) var entries: [StorageInventory.Entry]
    /// What is installed, largest first — the detail behind the Games row.
    private(set) var games: [StorageInventory.Game] = []
    private(set) var isMeasuring = false
    /// Whether the client has to stop before an uninstall can take the bottle.
    private(set) var isUninstalling = false
    private let isLive: Bool

    static func live() -> StorageStore {
        StorageStore(entries: StorageInventory.entries(), isLive: true)
    }

    #if DEBUG
        static func preview() -> StorageStore {
            var entries = StorageInventory.entries()
            let sizes: [String: Int64] = [
                "games": 214_863_953_920, "client": 1_932_735_283, "caches": 3_221_225_472,
                "bottle": 692_060_160, "engines": 1_395_864_371, "toolkits": 205_520_896,
                "shadow": 4096, "logs": 2_411_724,
            ]
            for index in entries.indices {
                entries[index].bytes = sizes[entries[index].id] ?? 0
            }
            let store = StorageStore(entries: entries, isLive: false)
            store.games = [
                .init(id: 1_245_620, name: "ELDEN RING", bytes: 62_277_025_792),
                .init(id: 2_050_650, name: "Resident Evil 4", bytes: 71_940_702_208),
                .init(id: 1_868_140, name: "DAVE THE DIVER", bytes: 4_509_715_660),
                .init(id: 892_970, name: "Valheim", bytes: 1_395_864_371),
            ].sorted { $0.bytes > $1.bytes }
            return store
        }
    #endif

    private init(entries: [StorageInventory.Entry], isLive: Bool) {
        self.entries = entries
        self.isLive = isLive
    }

    var total: Int64 {
        entries.map { max(0, $0.bytes) }.reduce(0, +)
    }

    /// Sizes arrive one at a time: `du` over a games library takes seconds,
    /// and a row that fills in is better than a pane that waits.
    func measure() async {
        guard isLive, !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        games = StorageInventory.installedGames()
        for index in entries.indices {
            let bytes = await StorageInventory.size(of: entries[index])
            guard index < entries.count else { return }
            entries[index].bytes = bytes
        }
    }

    func reclaim(_ entry: StorageInventory.Entry) {
        guard isLive else { return }
        do {
            try StorageInventory.trash(entry)
            EventLog.shared.log(.setup, "moved \(entry.name.lowercased()) to the Trash")
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].bytes = 0
            }
        } catch {
            EventLog.shared.log(.setup, "could not remove \(entry.name): \(error)")
        }
    }

    /// Everything this app made, and optionally the bottle it made it in.
    /// The caller quits the app when this returns — the bundle is already in
    /// the Trash by then.
    func uninstall(
        includingBottle: Bool, provisioner: Provisioner, supervisor: ClientSupervisor?,
    ) async {
        guard isLive, !isUninstalling else { return }
        isUninstalling = true
        defer { isUninstalling = false }
        // Supervision stands down before anything stops: the restart ladder
        // reads a stopped client as a crash and relaunches Steam into the
        // bottle being trashed. The quit path already does the whole
        // sequence — loop down, then every bottle process.
        if let supervisor {
            await supervisor.shutdownForQuit()
        } else {
            await ClientLifecycle.stopAll(gracePolls: 15)
        }
        let ours = ["engines", "toolkits", "shadow", "logs"]
        let bottleOnly = ["bottle", "client", "games", "caches"]
        for entry in entries where ours.contains(entry.id)
            || (includingBottle && bottleOnly.contains(entry.id)) {
            try? StorageInventory.trash(entry)
        }
        if includingBottle {
            try? FileManager.default.trashItem(at: SteamBottle.root, resultingItemURL: nil)
        }
        // The web session (the GPTk page's Apple sign-in) and the app's own
        // caches live outside the inventory's roots.
        if let bundleID = Bundle.main.bundleIdentifier {
            let library = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
            for path in ["WebKit/\(bundleID)", "Caches/\(bundleID)", "HTTPStorages/\(bundleID)"] {
                try? FileManager.default.trashItem(
                    at: library.appendingPathComponent(path), resultingItemURL: nil,
                )
            }
        }
        try? provisioner.setOpenAtLogin(false)
        Preferences.reset()
        entries = StorageInventory.entries()
        // Last, so everything the app would need to run again is already
        // gone: the bundle itself. The running process keeps its image; the
        // caller's terminate ends it.
        try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
    }
}
