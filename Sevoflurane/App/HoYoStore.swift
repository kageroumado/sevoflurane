import AppKit
import Foundation
import Observation

/// The HoYoverse installations Settings lists, what each needs, and the one
/// install, update, check or repair running for each.
///
/// Shared by the app, so a download keeps going while Settings shows another
/// pane or is closed. Quitting the app stops it; the next run of the same
/// action keeps every file already in place.
@MainActor
@Observable
final class HoYoStore {
    static let shared = HoYoStore()

    struct Row: Identifiable {
        let installation: HoYoInstallation
        /// The build `config.ini` named when the list was last read.
        var version: String?
        var plan: SophonDownloader.Plan?
        var checkFailure: String?

        var id: String { installation.folder.path }
    }

    /// Something running for one folder.
    struct Job {
        enum Kind { case install, update, verify, repair }

        let kind: Kind
        var progress: SophonProgress?
        var task: Task<Void, Never>?
    }

    private(set) var rows: [Row] = []
    private(set) var jobs: [String: Job] = [:]
    /// The last word on each folder: a finished update, the files a check
    /// found, a failure.
    private(set) var notes: [String: String] = [:]
    /// Files a check found missing or damaged, which Repair downloads.
    private(set) var problems: [String: [HoYoInstallation.Problem]] = [:]
    /// The install in progress, whose folder has no game in it yet.
    private(set) var installing: (game: HoYoGame, folder: URL)?

    /// Fixed rows for the gallery, which neither reads the library nor asks
    /// the servers.
    private let isFixture: Bool

    private init() { isFixture = false }

    #if DEBUG
        init(fixtureRows: [Row], jobs: [String: Job] = [:], notes: [String: String] = [:]) {
            isFixture = true
            rows = fixtureRows
            self.jobs = jobs
            self.notes = notes
        }
    #endif

    /// Lists the known installations again and asks what each needs.
    func reload() {
        guard !isFixture else { return }
        rows = HoYoLibrary.installations().map { installation in
            var row = rows.first { $0.id == installation.folder.path } ?? Row(installation: installation)
            row.version = installation.version
            return row
        }
        for row in rows where jobs[row.id] == nil { check(row.id) }
    }

    /// Asks HoYoPlay's servers what bringing one folder current takes.
    func check(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        Task {
            do {
                let plan = try await SophonDownloader().plan(game: row.installation.game, folder: row.installation.folder)
                update(id) { $0.plan = plan; $0.checkFailure = nil }
            } catch {
                update(id) { $0.checkFailure = "\(error)" }
            }
        }
    }

    // MARK: - Actions

    func startUpdate(_ id: String) {
        guard let installation = rows.first(where: { $0.id == id })?.installation else { return }
        run(.update, for: id, label: "update \(installation.game.displayName)") { progress in
            let outcome = try await SophonDownloader().update(installation, progress: progress)
            return switch outcome {
            case let .upToDate(tag): String(localized: "\(tag) is up to date.")
            case let .patched(from, to, files, _, whole) where whole > 0:
                String(localized: "Updated \(from) to \(to): \(files) files patched, \(whole) downloaded whole.")
            case let .patched(from, to, files, _, _):
                String(localized: "Updated \(from) to \(to): \(files) files patched.")
            case let .downloaded(to): String(localized: "Updated to \(to).")
            }
        }
    }

    func startVerify(_ id: String) {
        guard let installation = rows.first(where: { $0.id == id })?.installation else { return }
        problems[id] = nil
        run(.verify, for: id, label: "check \(installation.game.displayName)'s files") { progress in
            let found = await Task.detached {
                installation.verify { done, total in
                    progress(SophonProgress(phase: .checking, bytesDone: done, bytesTotal: total))
                }
            }.value
            await MainActor.run { HoYoStore.shared.problems[id] = found.isEmpty ? nil : found }
            return found.isEmpty
                ? String(localized: "Every file checks out.")
                : String(localized: "\(found.count) files are missing or damaged.")
        }
    }

    func startRepair(_ id: String) {
        guard let installation = rows.first(where: { $0.id == id })?.installation,
              let paths = problems[id]?.map(\.path) else { return }
        run(.repair, for: id, label: "repair \(installation.game.displayName)") { progress in
            try await SophonDownloader().repair(installation, paths: Set(paths), progress: progress)
            await MainActor.run { HoYoStore.shared.problems[id] = nil }
            return String(localized: "Repaired \(paths.count) files.")
        }
    }

    /// Downloads a game into a new folder, then lists it and adds it to
    /// Quick Launch when Sevoflurane can start it.
    func startInstall(_ game: HoYoGame, into folder: URL, voices: [String]) {
        let id = folder.standardizedFileURL.path
        installing = (game, folder)
        HoYoLibrary.remember(folder)
        run(.install, for: id, label: "install \(game.displayName) in \(folder.path)") { progress in
            let tag = try await SophonDownloader().install(game: game, into: folder, voices: voices, progress: progress)
            await MainActor.run {
                if HoYoLibrary.addToQuickLaunch(HoYoInstallation(game: game, folder: folder), bottle: SteamBottle.name) != nil {
                    ConfigMaterializer.materializeInBackground(bottle: SteamBottle.name, prefix: SteamBottle.root)
                }
            }
            return String(localized: "Installed \(game.displayName) \(tag).")
        }
    }

    func cancel(_ id: String) {
        jobs[id]?.task?.cancel()
    }

    /// Lists a folder a game is already installed in.
    func addExisting(_ folder: URL) -> Bool {
        guard HoYoInstallation(folder: folder) != nil else { return false }
        HoYoLibrary.remember(folder)
        reload()
        return true
    }

    /// Stops listing a folder; its files stay.
    func forget(_ id: String) {
        HoYoLibrary.forget(URL(fileURLWithPath: id))
        notes[id] = nil
        problems[id] = nil
        reload()
    }

    // MARK: - Plumbing

    /// Runs one job for a folder, logging its start and end, and leaves its
    /// last word in `notes`.
    private func run(
        _ kind: Job.Kind, for id: String, label: String,
        _ body: @escaping @Sendable (@escaping SophonDownloader.ProgressHandler) async throws -> String,
    ) {
        guard jobs[id] == nil else { return }
        notes[id] = nil
        EventLog.shared.log(.update, "hoyo: \(label) started")
        let task = Task {
            let progress: SophonDownloader.ProgressHandler = { value in
                Task { @MainActor in HoYoStore.shared.jobs[id]?.progress = value }
            }
            do {
                let note = try await body(progress)
                notes[id] = note
                EventLog.shared.log(.update, "hoyo: \(label) finished — \(note)")
            } catch is CancellationError {
                notes[id] = String(localized: "Stopped. Running it again keeps what was downloaded.")
                EventLog.shared.log(.update, "hoyo: \(label) stopped")
            } catch {
                notes[id] = "\(error)"
                EventLog.shared.log(.update, "hoyo: \(label) failed — \(error)")
            }
            jobs[id] = nil
            if kind == .install { installing = nil }
            reload()
        }
        jobs[id] = Job(kind: kind, task: task)
    }

    private func update(_ id: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }
}
