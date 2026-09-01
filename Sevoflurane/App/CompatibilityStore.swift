import Foundation

/// What the Compatibility pane shows: the dependency catalog with live
/// installed-state, the bottle's DLL overrides, and the Wine tool launchers.
///
/// Live or preview, the same shape — the gallery draws this pane too, and a
/// preview that could pour 200 MB of fonts into a bottle would be a poor
/// kind of preview.
@MainActor
@Observable
final class CompatibilityStore {
    struct DependencyRow: Identifiable {
        let dependency: BottleDependencies.Dependency
        var installed: Bool
        var busy = false
        /// What the install is doing right now — download counts, installer
        /// stages — while `busy`.
        var phase: String?
        var error: String?
        var id: String { dependency.id }
    }

    private(set) var rows: [DependencyRow]
    private(set) var overrides: [BottleDependencies.Override] = []
    private(set) var overrideError: String?
    private let isLive: Bool

    static func live() -> CompatibilityStore {
        CompatibilityStore(isLive: true)
    }

    #if DEBUG
        static func preview() -> CompatibilityStore {
            let store = CompatibilityStore(isLive: false)
            store.rows[0].installed = true
            store.rows[1].installed = true
            store.rows[3].busy = true
            store.rows[3].phase = "downloading DirectX redistributable"
            store.overrides = [
                .init(dll: "d3dcompiler_47", mode: "native"),
                .init(dll: "quartz", mode: "native, builtin"),
                .init(dll: "winemenubuilder.exe", mode: "disabled"),
            ]
            return store
        }
    #endif

    private init(isLive: Bool) {
        rows = BottleDependencies.catalog.map {
            DependencyRow(dependency: $0, installed: false)
        }
        self.isLive = isLive
    }

    /// Re-reads the disk truth: what's installed, and the current overrides.
    func refresh() {
        guard isLive else { return }
        for index in rows.indices where !rows[index].busy {
            rows[index].installed = BottleDependencies.isInstalled(rows[index].dependency)
        }
        overrides = BottleDependencies.overrides()
    }

    func install(_ id: String) {
        guard isLive, let index = rows.firstIndex(where: { $0.id == id }),
              !rows[index].busy else { return }
        rows[index].busy = true
        rows[index].error = nil
        rows[index].phase = "starting"
        let name = rows[index].dependency.name
        Task(name: "Install \(name)") { [weak self] in
            let failure = await BottleDependencies.install(id) { phase in
                DispatchQueue.main.async { self?.setPhase(phase, forRow: id) }
            }
            guard let self, let index = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[index].busy = false
            rows[index].phase = nil
            rows[index].error = failure
            rows[index].installed = BottleDependencies.isInstalled(rows[index].dependency)
            EventLog.enqueue(
                .app, failure.map { "\(name) install failed: \($0)" } ?? "\(name) installed",
            )
        }
    }

    private func setPhase(_ phase: String, forRow id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].phase = phase
    }

    // MARK: - Overrides

    func setOverride(dll: String, mode: String) {
        guard isLive else { return }
        let trimmed = dll.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ".dll", with: "")
        guard !trimmed.isEmpty else { return }
        overrideError = nil
        Task(name: "Set override \(trimmed)") { [weak self] in
            let failure = await BottleDependencies.setOverride(dll: trimmed, mode: mode)
            guard let self else { return }
            overrideError = failure
            guard failure == nil else { return }
            // user.reg lags wineserver's flush by a few seconds, so show
            // what was just written rather than re-reading a stale file.
            var updated = overrides.filter { $0.dll != trimmed }
            updated.append(.init(dll: trimmed, mode: mode))
            overrides = updated.sorted { $0.dll < $1.dll }
        }
    }

    func removeOverride(_ override: BottleDependencies.Override) {
        guard isLive else { return }
        overrideError = nil
        Task(name: "Remove override \(override.dll)") { [weak self] in
            let failure = await BottleDependencies.removeOverride(dll: override.dll)
            guard let self else { return }
            overrideError = failure
            guard failure == nil else { return }
            overrides.removeAll { $0.dll == override.dll }
        }
    }

    // MARK: - Wine tools

    func openWineConfiguration() {
        guard isLive else { return }
        Task(name: "Open winecfg") { await ClientLifecycle.launchInBottle(["winecfg"]) }
    }
}
