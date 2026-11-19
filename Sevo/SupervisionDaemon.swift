import Foundation

/// Starts the `KeepAlive` LaunchAgent from a terminal when launchd has not
/// started it yet or someone stopped it. Only the app can register it
/// (`SMAppService` acts for the bundle that ships it).
nonisolated enum SupervisionDaemon {
    enum Outcome: Equatable {
        case started
        /// launchd has no such job: the app has never registered it here.
        case notInstalled
        case refused(String)
    }

    static let label = SupervisorLink.label

    /// Kicks the agent and waits for its control port. Idempotent.
    static func start(timeout: Int = 15) async -> Outcome {
        let target = "gui/\(getuid())/\(label)"
        let kickstart = await Subprocess.run(
            "/bin/launchctl", ["kickstart", target], timeout: .seconds(10),
        )
        guard kickstart.status == 0 else {
            // 113 is launchctl's "no such process": nothing is registered.
            return kickstart.output.contains("113") || kickstart.status == 113
                ? .notInstalled
                : .refused(kickstart.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for _ in 0 ..< timeout {
            if await AppControl.status() != nil { return .started }
            try? await Task.sleep(for: .seconds(1))
        }
        return .refused("it did not answer :\(BridgePorts.control) within \(timeout)s")
    }
}
