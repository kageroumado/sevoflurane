import AppKit
import Foundation
import Observation

/// The Epic Games and GOG accounts Settings shows: whether each client is
/// downloaded and signed in, the account's Windows library and what of it is
/// installed, and the one install, update, check or removal running per store.
///
/// Shared by the app, so a download keeps going while Settings shows another
/// pane or is closed. Quitting the app stops it; installing again carries on
/// from the files already downloaded.
@MainActor
@Observable
final class StoresStore {
    static let shared = StoresStore()

    /// One store's side of the pane.
    struct Account {
        enum Client: Equatable {
            case missing
            case downloading
            case ready
        }

        var client: Client = .missing
        /// The account's name, nil while signed out.
        var name: String?
        var library: [StoreTitle] = []
        var installs: [StoreInstall] = []
        /// The current build of each installed title, where it differs from
        /// the installed one.
        var updates: [String: String] = [:]
        var loading = false
        /// Why the account or its library could not be read.
        var failure: String?
        /// Whether this run of the app has read the account yet.
        var loaded = false
    }

    /// Something running for one title.
    struct Job {
        enum Kind { case install, update, repair, uninstall }

        let kind: Kind
        let title: String
        var progress: StoreProgress?
        /// The bytes the download needs, from legendary's announcement.
        var downloadSize: Int64?
        var task: Task<Void, Never>?
    }

    private(set) var accounts: [GameStore: Account] = [.epic: Account(), .gog: Account()]
    /// The running job of each store, keyed by store: a client installs one
    /// title at a time.
    private(set) var jobs: [GameStore: (id: String, job: Job)] = [:]
    /// The last word on each title (`store:id`): a finished install, a failure.
    private(set) var notes: [String: String] = [:]
    /// Bytes on disk each title (`store:id`) needs, as they become known.
    private(set) var sizes: [String: Int64] = [:]
    /// The store whose sign-in sheet is up.
    var signingIn: GameStore?

    private var sizeQueue: [StoreTitle] = []
    private var sizesInFlight = 0
    private var sizesAsked: Set<String> = []

    /// Fixed accounts for the gallery, which neither runs a client nor asks
    /// a store.
    private let isFixture: Bool

    private init() {
        isFixture = false
        for store in GameStore.allCases where store.tool.isInstalled {
            accounts[store]?.client = .ready
        }
    }

    #if DEBUG
        init(fixture accounts: [GameStore: Account], jobs: [GameStore: (id: String, job: Job)], sizes: [String: Int64]) {
            isFixture = true
            self.accounts = accounts
            self.jobs = jobs
            self.sizes = sizes
        }
    #endif

    static func key(_ store: GameStore, _ id: String) -> String {
        "\(store.rawValue):\(id)"
    }

    func account(_ store: GameStore) -> Account {
        accounts[store] ?? Account()
    }

    // MARK: - Account

    /// Reads the account and its library once per run of the app, or again
    /// when `force` asks.
    func reload(_ store: GameStore, force: Bool = false) {
        guard !isFixture, store.tool.isInstalled else { return }
        guard force || !account(store).loaded, !account(store).loading else { return }
        change(store) { $0.loading = true; $0.failure = nil; $0.client = .ready }
        Task {
            do {
                try await load(store)
            } catch {
                change(store) { $0.failure = "\(error)" }
                EventLog.shared.log(.update, "stores: could not read the \(store.displayName) library — \(error)")
            }
            change(store) { $0.loading = false; $0.loaded = true }
        }
    }

    private func load(_ store: GameStore) async throws {
        switch store {
        case .epic:
            let name = try await Legendary.account(inStatus: Legendary.status())
            change(store) { $0.name = name }
            guard name != nil else { return clearLibrary(store) }
            let library = try await Legendary.library()
            let installs = try await Legendary.installed()
            let latest = Dictionary(library.map { ($0.id, $0.version ?? "") }, uniquingKeysWith: { first, _ in first })
            change(store) { account in
                account.library = library
                account.installs = installs
                account.updates = installs.reduce(into: [:]) { updates, install in
                    if let current = latest[install.id], !current.isEmpty, current != install.version {
                        updates[install.id] = current
                    }
                }
            }
            await adoptMissing(store, installs)
        case .gog:
            guard let credentials = try await GOG.credentials() else {
                change(store) { $0.name = nil }
                return clearLibrary(store)
            }
            let name = try? await GOG.account(credentials)
            let library = try await GOG.library(credentials)
            let installs = GOG.installed()
            change(store) { account in
                account.name = name ?? String(localized: "GOG user \(credentials.userID)")
                account.library = library
                account.installs = installs
                account.updates = [:]
            }
            await adoptMissing(store, installs)
            for install in installs {
                guard let build = try? await GOG.build(install.id), build.id != install.version else { continue }
                change(store) { $0.updates[install.id] = build.name ?? build.id }
            }
        }
    }

    private func clearLibrary(_ store: GameStore) {
        change(store) { $0.library = []; $0.installs = []; $0.updates = [:] }
    }

    /// Opens the store's sign-in, downloading its client first if it is not
    /// here yet.
    func beginSignIn(_ store: GameStore) {
        guard account(store).client != .downloading else { return }
        if store.tool.isInstalled {
            signingIn = store
            return
        }
        change(store) { $0.client = .downloading; $0.failure = nil }
        Task {
            do {
                try await store.tool.install()
                EventLog.shared.log(.update, "stores: downloaded \(store.tool.rawValue) \(store.tool.version)")
                change(store) { $0.client = .ready }
                signingIn = store
            } catch {
                change(store) { $0.client = .missing; $0.failure = "\(error)" }
                EventLog.shared.log(.update, "stores: could not download \(store.tool.rawValue) — \(error)")
            }
        }
    }

    /// Hands the code the store's login page gave to its client.
    func completeSignIn(_ store: GameStore, code: String) {
        signingIn = nil
        change(store) { $0.loading = true; $0.failure = nil }
        Task {
            do {
                switch store {
                case .epic: try await Legendary.signIn(code: code)
                case .gog: try await GOG.signIn(code: code)
                }
                EventLog.shared.log(.update, "stores: signed in to \(store.displayName)")
                change(store) { $0.loading = false }
                reload(store, force: true)
            } catch {
                change(store) { $0.loading = false; $0.failure = String(localized: "Signing in did not work: \(String(describing: error))") }
                EventLog.shared.log(.update, "stores: signing in to \(store.displayName) failed — \(error)")
            }
        }
    }

    /// Signs out. Installed games stay, and keep starting.
    func signOut(_ store: GameStore) {
        Task {
            switch store {
            case .epic: try? await Legendary.signOut()
            case .gog: try? GOG.signOut()
            }
            EventLog.shared.log(.update, "stores: signed out of \(store.displayName)")
            change(store) { $0.name = nil; $0.library = [] }
        }
    }

    // MARK: - Sizes

    /// Asks the client what a title needs on disk, a couple of titles at a
    /// time, once per run of the app.
    func requestSize(_ title: StoreTitle) {
        let key = Self.key(title.store, title.id)
        guard !isFixture, sizes[key] == nil, sizesAsked.insert(key).inserted else { return }
        sizeQueue.append(title)
        pumpSizes()
    }

    private func pumpSizes() {
        while sizesInFlight < 2, !sizeQueue.isEmpty {
            let title = sizeQueue.removeFirst()
            sizesInFlight += 1
            Task {
                let size: Int64? = switch title.store {
                case .epic: try? await Legendary.installSize(title.id)
                case .gog: try? await GOG.build(title.id).size
                }
                if let size { sizes[Self.key(title.store, title.id)] = size }
                sizesInFlight -= 1
                pumpSizes()
            }
        }
    }

    // MARK: - Jobs

    func install(_ title: StoreTitle, into base: URL) {
        run(.install, title.store, title.id, title.title) { onLine in
            switch title.store {
            case .epic:
                try await Legendary.install(title.id, base: base, onLine: onLine)
                guard let install = try await Legendary.installed().first(where: { $0.id == title.id }) else {
                    throw StoreFailure("legendary does not list \(title.title) as installed")
                }
                try await Self.adopt(install)
            case .gog:
                let build = try await GOG.build(title.id)
                try await GOG.download(title.id, base: base, onLine: onLine)
                let folder = base.appending(path: build.folder ?? title.title)
                let install = StoreInstall(
                    store: .gog, id: title.id, title: title.title, path: folder.path,
                    version: build.id, versionName: build.name, size: build.size,
                )
                try GOG.record(install)
                try await Self.adopt(install)
            }
            return String(localized: "Installed. \(title.title) is in Quick Launch.")
        }
    }

    func update(_ install: StoreInstall) {
        run(.update, install.store, install.id, install.title) { onLine in
            switch install.store {
            case .epic:
                try await Legendary.update(install.id, onLine: onLine)
                if let updated = try await Legendary.installed().first(where: { $0.id == install.id }) {
                    try await Self.adopt(updated)
                }
            case .gog:
                let build = try await GOG.build(install.id)
                let base = URL(fileURLWithPath: install.path).deletingLastPathComponent()
                try await GOG.download(install.id, verb: "update", base: base, onLine: onLine)
                var updated = install
                updated.version = build.id
                updated.versionName = build.name
                updated.size = build.size
                try GOG.record(updated)
                try await Self.adopt(updated)
            }
            return String(localized: "Updated.")
        }
    }

    /// Checks every file and downloads the missing and damaged ones.
    func repair(_ install: StoreInstall) {
        run(.repair, install.store, install.id, install.title) { onLine in
            switch install.store {
            case .epic:
                try await Legendary.repair(install.id, onLine: onLine)
            case .gog:
                let base = URL(fileURLWithPath: install.path).deletingLastPathComponent()
                try await GOG.download(install.id, verb: "repair", base: base, onLine: onLine)
            }
            return String(localized: "Every file checks out.")
        }
    }

    /// Takes a title away: the client forgets it, its folder goes to the
    /// Trash and its Quick Launch entry is removed.
    func uninstall(_ install: StoreInstall) {
        run(.uninstall, install.store, install.id, install.title) { _ in
            switch install.store {
            case .epic: try await Legendary.forget(install.id)
            case .gog: try GOG.forget(install.id)
            }
            let folder = URL(fileURLWithPath: install.path)
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            }
            StoreLibrary.release(install.store, id: install.id)
            return String(localized: "Moved \(install.title) to the Trash.")
        }
    }

    func cancel(_ store: GameStore) {
        jobs[store]?.job.task?.cancel()
    }

    /// Records an installed title as a Quick Launch game, with what starts it.
    private nonisolated static func adopt(_ install: StoreInstall) async throws {
        let plan: StoreLaunchPlan? = switch install.store {
        case .epic: try await Legendary.launchPlan(install.id, offline: true)
        case .gog: GOG.launchPlan(install.id, folder: URL(fileURLWithPath: install.path))
        }
        guard let plan else { throw StoreFailure("\(install.title) names no program to start") }
        await MainActor.run {
            StoreLibrary.adopt(install, plan: plan, bottle: SteamBottle.name)
            ConfigMaterializer.materializeInBackground(bottle: SteamBottle.name, prefix: SteamBottle.root)
        }
    }

    /// Gives every installed title without a Quick Launch entry one: those
    /// installed before this version, or by the client on its own.
    private func adoptMissing(_ store: GameStore, _ installs: [StoreInstall]) async {
        for install in installs where StoreLibrary.program(for: store, id: install.id) == nil {
            do {
                try await Self.adopt(install)
            } catch {
                EventLog.shared.log(.update, "stores: could not add \(install.title) to Quick Launch — \(error)")
            }
        }
    }

    /// Runs one job for a store, logging its start and end, and leaves its
    /// last word in `notes`.
    private func run(
        _ kind: Job.Kind, _ store: GameStore, _ id: String, _ title: String,
        _ body: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> String,
    ) {
        guard jobs[store] == nil else { return }
        let key = Self.key(store, id)
        notes[key] = nil
        let label = "\(kind) \(title) from \(store.displayName)"
        EventLog.shared.log(.update, "stores: \(label) started")
        let onLine: @Sendable (String) -> Void = { line in
            let progress = StoreOutput.progress(line)
            let size = StoreOutput.legendaryDownloadSize(line)
            guard progress != nil || size != nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let shared = StoresStore.shared
                    guard shared.jobs[store]?.id == id else { return }
                    if let progress { shared.jobs[store]?.job.progress = progress }
                    if let size { shared.jobs[store]?.job.downloadSize = size }
                }
            }
        }
        let task = Task {
            do {
                let note = try await body(onLine)
                notes[key] = note
                EventLog.shared.log(.update, "stores: \(label) finished")
            } catch is CancellationError {
                notes[key] = String(localized: "Stopped. Installing again carries on from what was downloaded.")
                EventLog.shared.log(.update, "stores: \(label) stopped")
            } catch {
                notes[key] = "\(error)"
                EventLog.shared.log(.update, "stores: \(label) failed — \(error)")
            }
            jobs[store] = nil
            reload(store, force: true)
        }
        jobs[store] = (id, Job(kind: kind, title: title, task: task))
    }

    private func change(_ store: GameStore, _ body: (inout Account) -> Void) {
        var account = accounts[store] ?? Account()
        body(&account)
        accounts[store] = account
    }
}
