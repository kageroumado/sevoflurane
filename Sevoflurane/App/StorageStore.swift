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
        refreshSharing()
        for index in entries.indices {
            let bytes = await StorageInventory.size(of: entries[index])
            guard index < entries.count else { return }
            entries[index].bytes = bytes
        }
    }

    // MARK: - Shared game files

    /// Games in other bottles the active one could link.
    private(set) var linkable: [SharedGames.Candidate] = []
    /// Links whose files are in place but whose manifest waits for the
    /// restart — Steam's library watcher wobbles visibly at a manifest
    /// landing mid-session, so it lands on the way down instead.
    private(set) var pendingLinks: [SharedGames.Candidate] = []
    /// The installed games that are links into another bottle.
    private(set) var linkedGames: Set<Int> = []
    /// A link or unlink landed; Steam reads manifests at startup, so the
    /// change is invisible until the client restarts.
    private(set) var needsClientRestart = false
    private(set) var linkError: String?

    func link(_ candidate: SharedGames.Candidate) {
        guard isLive, !pendingLinks.contains(candidate) else { return }
        do {
            try SharedGames.linkGameFiles(candidate)
            linkError = nil
            pendingLinks.append(candidate)
            needsClientRestart = true
            EventLog.shared.log(
                .setup,
                "linked \(candidate.name) files from \(candidate.sourceEngine)'s "
                    + "\u{201C}\(candidate.sourceBottle)\u{201D} — manifest lands at restart",
            )
        } catch {
            linkError = "couldn't link \(candidate.name): \(error.localizedDescription)"
        }
        refreshSharing()
    }

    /// Backs a pending link out before it ever reached Steam.
    func cancelPendingLink(_ candidate: SharedGames.Candidate) {
        guard isLive else { return }
        try? SharedGames.removePendingLink(candidate)
        pendingLinks.removeAll { $0 == candidate }
        if pendingLinks.isEmpty { needsClientRestart = false }
        refreshSharing()
    }

    /// Writes the pending manifests — called right before the restart that
    /// makes Steam read them, so the mid-session watcher window is seconds.
    func applyPendingLinks() {
        guard isLive else { return }
        for candidate in pendingLinks {
            do {
                try SharedGames.writeManifest(candidate)
                EventLog.shared.log(.setup, "manifest written for \(candidate.name)")
            } catch {
                linkError = "couldn't finish linking \(candidate.name): "
                    + error.localizedDescription
            }
        }
        pendingLinks.removeAll()
        refreshSharing()
    }

    func unlink(_ game: StorageInventory.Game) {
        guard isLive else { return }
        do {
            try SharedGames.unlink(appID: game.id)
            linkError = nil
            needsClientRestart = true
            EventLog.shared.log(.setup, "removed the link for \(game.name)")
        } catch {
            linkError = "couldn't remove the link: \(error.localizedDescription)"
        }
        refreshSharing()
    }

    func acknowledgeRestart() {
        needsClientRestart = false
    }

    private func refreshSharing() {
        games = StorageInventory.installedGames()
        linkedGames = Set(games.map(\.id).filter { SharedGames.isLinked(appID: $0) })
        let pending = Set(pendingLinks.map(\.appID))
        linkable = SharedGames.linkable().filter { !pending.contains($0.appID) }
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
            await ClientLifecycle.stopAll(gracePolls: 10)
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
        await AgentIntegration.remove(allowAdminPrompt: false)
        try? provisioner.setOpenAtLogin(false)
        Preferences.reset()
        entries = StorageInventory.entries()
        // Last, so everything the app would need to run again is already
        // gone: the bundle itself. The running process keeps its image; the
        // caller's terminate ends it.
        try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
    }
}
