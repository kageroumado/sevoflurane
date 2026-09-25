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
    /// Which required components the bottle is missing, said once for the
    /// whole section; `nil` when it is complete.
    private(set) var incompleteSummary: String?
    private let environment: any CompatibilityEnvironment

    init(environment: (any CompatibilityEnvironment)? = nil) {
        rows = BottleDependencies.catalog.map {
            DependencyRow(dependency: $0, installed: false)
        }
        self.environment = environment ?? LiveCompatibilityEnvironment()
    }

    /// Re-reads the disk truth: what's installed, what failed to install, and
    /// the current overrides.
    ///
    /// A failure is read back from the record rather than held here, so
    /// leaving the pane and coming back still shows why the row is empty.
    func refresh() {
        for index in rows.indices where !rows[index].busy {
            rows[index].installed = environment.isInstalled(rows[index].dependency)
            if !environment.isSimulation {
                rows[index].error = BottleReadiness.dependencyFailure(rows[index].id)
            }
        }
        incompleteSummary = BottleReadiness.incompleteSummary(
            missing: rows.filter { $0.dependency.required && !$0.installed }
                .map(\.dependency.name),
        )
        overrides = environment.overrides()
    }

    func install(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              !rows[index].busy else { return }
        rows[index].busy = true
        rows[index].error = nil
        rows[index].phase = InterfaceCopy.localized("starting")
        let name = rows[index].dependency.name
        Task(name: "Install \(name)") { [weak self] in
            guard let self else { return }
            let failure = await environment.install(id) { phase in
                DispatchQueue.main.async { self.setPhase(phase, forRow: id) }
            }
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[index].busy = false
            rows[index].phase = nil
            rows[index].error = failure
            rows[index].installed = environment.isInstalled(rows[index].dependency)
            if !environment.isSimulation {
                BottleReadiness.record(dependency: id, failure: failure)
            }
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
        let trimmed = dll.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ".dll", with: "")
        guard !trimmed.isEmpty else { return }
        overrideError = nil
        Task(name: "Set override \(trimmed)") { [weak self] in
            guard let self else { return }
            let failure = await environment.setOverride(dll: trimmed, mode: mode)
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
        overrideError = nil
        Task(name: "Remove override \(override.dll)") { [weak self] in
            guard let self else { return }
            let failure = await environment.removeOverride(dll: override.dll)
            overrideError = failure
            guard failure == nil else { return }
            overrides.removeAll { $0.dll == override.dll }
        }
    }

    // MARK: - Wine tools

    func openWineConfiguration() {
        environment.openWineConfiguration()
    }
}
