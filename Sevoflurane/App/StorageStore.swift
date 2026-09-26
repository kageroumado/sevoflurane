import Foundation

/// What the Storage pane shows, and the only thing that removes any of it.
///
/// Every reach for the disk goes through ``StorageEnvironment``: the gallery
/// draws this pane too, and a preview that could empty a games library — or
/// trash the app bundle, which the live uninstall ends by doing — would be a
/// poor kind of preview.
@MainActor
@Observable
final class StorageStore {
    private(set) var entries: [StorageInventory.Entry]
    /// The disk all of it sits on, for the bar above the list.
    private(set) var volume: StorageInventory.Volume?
    /// What is installed, largest first — the detail behind the Games row.
    private(set) var games: [StorageInventory.Game] = []
    /// The Windows programs added by hand — the detail behind the Added
    /// programs row.
    private(set) var programs: [StorageInventory.Program] = []
    /// Steam's game libraries and the drives they are on.
    private(set) var libraries: [StorageInventory.Library] = []
    /// The last thing this pane could not do, for the line under the list.
    private(set) var problem: String?
    private(set) var isMeasuring = false
    /// Whether the client has to stop before an uninstall can take the bottle.
    private(set) var isUninstalling = false
    private let environment: any StorageEnvironment

    init(environment: (any StorageEnvironment)? = nil) {
        let environment = environment ?? LiveStorageEnvironment()
        self.environment = environment
        entries = environment.entries()
        volume = environment.volume()
    }

    /// The volume divided between what is measured so far and everything
    /// else, or `nil` when the volume could not be read.
    var breakdown: StorageBreakdown? {
        volume.map {
            StorageBreakdown.make(entries: entries, volumeUsed: $0.used, volumeTotal: $0.capacity)
        }
    }

    var total: Int64 {
        entries.map { max(0, $0.bytes) }.reduce(0, +)
    }

    /// Sizes arrive one at a time: `du` over a games library takes seconds,
    /// and a row that fills in is better than a pane that waits.
    func measure() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        volume = environment.volume()
        refreshSharing()
        for index in programs.indices {
            let bytes = await environment.size(of: programs[index])
            guard index < programs.count else { return }
            programs[index].bytes = bytes
        }
        for index in entries.indices {
            let bytes = await environment.size(of: entries[index])
            guard index < entries.count else { return }
            entries[index].bytes = bytes
        }
    }

    /// Forgets a program and takes what its installer wrote to the Trash.
    func removeProgram(_ program: StorageInventory.Program) {
        do {
            try environment.remove(program: program)
            EventLog.shared.log(.setup, "removed \(program.name) from the added programs")
        } catch {
            problem = "couldn't remove \(program.name): \(error.localizedDescription)"
        }
        refreshSharing()
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

    func link(_ candidate: SharedGames.Candidate) {
        guard !pendingLinks.contains(candidate) else { return }
        do {
            try environment.linkGameFiles(candidate)
            problem = nil
            pendingLinks.append(candidate)
            needsClientRestart = true
            EventLog.shared.log(
                .setup,
                "linked \(candidate.name) files from \(candidate.sourceEngine)'s "
                    + "\u{201C}\(candidate.sourceBottle)\u{201D} — manifest lands at restart",
            )
        } catch {
            problem = "couldn't link \(candidate.name): \(error.localizedDescription)"
        }
        refreshSharing()
    }

    /// Backs a pending link out before it ever reached Steam.
    func cancelPendingLink(_ candidate: SharedGames.Candidate) {
        try? environment.removePendingLink(candidate)
        pendingLinks.removeAll { $0 == candidate }
        if pendingLinks.isEmpty { needsClientRestart = false }
        refreshSharing()
    }

    /// Writes the pending manifests — called right before the restart that
    /// makes Steam read them, so the mid-session watcher window is seconds.
    func applyPendingLinks() {
        for candidate in pendingLinks {
            do {
                try environment.writeManifest(candidate)
                EventLog.shared.log(.setup, "manifest written for \(candidate.name)")
            } catch {
                problem = "couldn't finish linking \(candidate.name): "
                    + error.localizedDescription
            }
        }
        pendingLinks.removeAll()
        refreshSharing()
    }

    func unlink(_ game: StorageInventory.Game) {
        do {
            try environment.unlink(appID: game.id)
            problem = nil
            needsClientRestart = true
            EventLog.shared.log(.setup, "removed the link for \(game.name)")
        } catch {
            problem = "couldn't remove the link: \(error.localizedDescription)"
        }
        refreshSharing()
    }

    func acknowledgeRestart() {
        needsClientRestart = false
    }

    private func refreshSharing() {
        games = environment.installedGames()
        libraries = environment.libraries()
        programs = environment.addedPrograms()
        linkedGames = Set(games.map(\.id).filter(environment.isLinked(appID:)))
        let pending = Set(pendingLinks.map(\.appID))
        linkable = environment.linkable().filter { !pending.contains($0.appID) }
    }

    /// Moves an entry to the Trash, unless the running bottle is using it
    /// (``StorageInventory/isRefused(_:bottleRunning:)``).
    func reclaim(_ entry: StorageInventory.Entry) {
        do {
            let running = !environment.isSimulation && StorageInventory.isBottleRunning
            if StorageInventory.isRefused(entry, bottleRunning: running) {
                throw StorageInventory.InUse(entry: entry.name)
            }
            try environment.trash(entry)
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
        guard !isUninstalling else { return }
        isUninstalling = true
        defer { isUninstalling = false }
        await environment.stopEverything(supervisor: supervisor)
        let ours = ["engines", "renderers", "shaders", "toolkits", "shadow", "logs"]
        let bottleOnly = ["bottle", "client", "games", "caches", "companions"]
        for entry in entries where ours.contains(entry.id)
            || (includingBottle && bottleOnly.contains(entry.id)) {
            try? environment.trash(entry)
        }
        if includingBottle {
            try? environment.trashBottle()
        }
        environment.trashAppCaches()
        await environment.removeAgentIntegration()
        provisioner.setOpenAtLogin(false)
        environment.forgetSettings()
        entries = environment.entries()
        // Last, so everything the app would need to run again is already
        // gone: the bundle itself. The running process keeps its image; the
        // caller's terminate ends it.
        environment.trashAppBundle()
    }
}
