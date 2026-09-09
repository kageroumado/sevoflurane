import Foundation

/// Bringing `SevofluraneDaemon` up from a terminal.
///
/// The daemon is a `KeepAlive` LaunchAgent registered by Sevoflurane.app, so
/// in ordinary use it is already running and this does nothing. It exists for
/// the two moments it is not: a machine that has just been booted into a
/// session where launchd has not started it yet, and a daemon someone stopped
/// by hand while debugging.
///
/// Registering it is the app's job — `SMAppService` registers the agent from
/// inside the bundle that ships it, and a CLI symlinked onto `PATH` is not
/// that bundle. So a machine where nothing is registered is told to open
/// Sevoflurane once, rather than being given a client with nothing watching it.
nonisolated enum SupervisionDaemon {
    enum Outcome: Equatable {
        case started
        /// launchd has no such job: the app has never registered it here.
        case notInstalled
        case refused(String)
    }

    static let label = "glass.kagerou.sevoflurane.daemon"

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
