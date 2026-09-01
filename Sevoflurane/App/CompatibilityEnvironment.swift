import Foundation

/// The bottle-touching half of the Engine pane's dependency and override
/// sections, split from ``CompatibilityStore`` so a simulated environment can
/// pose any mix of installed pieces, run an install that narrates its stages,
/// and fail one — without pouring 200 MB of fonts into a real bottle.
@MainActor
protocol CompatibilityEnvironment: AnyObject {
    /// Whether the effects are simulated.
    var isSimulation: Bool { get }

    func isInstalled(_ dependency: BottleDependencies.Dependency) -> Bool
    /// Answers the failure, so the row can show it.
    func install(
        _ id: String, phase: @escaping @Sendable (String) -> Void,
    ) async -> String?

    func overrides() -> [BottleDependencies.Override]
    /// Answers the failure, so the section can show it.
    func setOverride(dll: String, mode: String) async -> String?
    func removeOverride(dll: String) async -> String?

    func openWineConfiguration()
}

extension CompatibilityEnvironment {
    var isSimulation: Bool {
        false
    }
}

/// The real one: the bottle's own DLLs, fonts, registry and winecfg.
@MainActor
final class LiveCompatibilityEnvironment: CompatibilityEnvironment {
    func isInstalled(_ dependency: BottleDependencies.Dependency) -> Bool {
        BottleDependencies.isInstalled(dependency)
    }

    func install(
        _ id: String, phase: @escaping @Sendable (String) -> Void,
    ) async -> String? {
        await BottleDependencies.install(id, phase: phase)
    }

    func overrides() -> [BottleDependencies.Override] {
        BottleDependencies.overrides()
    }

    func setOverride(dll: String, mode: String) async -> String? {
        await BottleDependencies.setOverride(dll: dll, mode: mode)
    }

    func removeOverride(dll: String) async -> String? {
        await BottleDependencies.removeOverride(dll: dll)
    }

    func openWineConfiguration() {
        Task(name: "Open winecfg") { await ClientLifecycle.launchInBottle(["winecfg"]) }
    }
}
