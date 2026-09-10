import Foundation
import ServiceManagement

/// Registering, reaching, and talking to `SevofluraneDaemon`.
///
/// The daemon is a `KeepAlive` LaunchAgent embedded in this bundle, registered
/// with `SMAppService` on first launch. It is not optional: it owns the bottle,
/// so an app that cannot reach it has no supervision at all and says so —
/// there is no in-process supervisor to fall back to, by design.
@MainActor
enum DaemonService {
    private static var service: SMAppService {
        SMAppService.agent(plistName: SupervisorLink.launchAgentPlistName)
    }

    /// What the app knows about supervision, and what it can tell the user to
    /// do about it.
    struct Outcome: Equatable {
        let isReachable: Bool
        /// A sentence for the menu bar. Empty when everything is running.
        let message: String
        /// Whether Login Items is where the user finishes the job.
        let needsApproval: Bool
    }

    /// Registers the daemon if it is not registered, then waits for it to
    /// answer. Idempotent: this is both first-run setup and the Retry the
    /// terminal state offers.
    static func ensureRunning() async -> Outcome {
        if await isAnswering() { return Outcome(isReachable: true, message: "", needsApproval: false) }
        switch service.status {
        case .enabled:
            break
        case .requiresApproval:
            return Outcome(
                isReachable: false,
                message: "Approve Sevoflurane's background helper in Login Items.",
                needsApproval: true,
            )
        case .notRegistered, .notFound:
            do {
                try service.register()
            } catch {
                return Outcome(
                    isReachable: false,
                    message: "Sevoflurane could not register its background helper: "
                        + error.localizedDescription,
                    needsApproval: true,
                )
            }
            if service.status == .requiresApproval {
                return Outcome(
                    isReachable: false,
                    message: "Approve Sevoflurane's background helper in Login Items.",
                    needsApproval: true,
                )
            }
        @unknown default:
            break
        }
        // launchd starts a freshly registered agent on its own schedule.
        for _ in 0 ..< Timing.startupPolls {
            try? await Task.sleep(for: .seconds(1))
            if await isAnswering() {
                return Outcome(isReachable: true, message: "", needsApproval: false)
            }
        }
        return Outcome(
            isReachable: false,
            message: "The background helper is registered and stopped.",
            needsApproval: true,
        )
    }

    /// Removes the registration. The uninstall path, and the way a test run
    /// leaves the machine as it found it.
    static func unregister() async {
        try? await service.unregister()
    }

    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Control port

    static func isAnswering() async -> Bool {
        await get("/status", timeout: 2) != nil
    }

    static func get(_ path: String, timeout: TimeInterval = 5) async -> Data? {
        await request(path, method: "GET", body: nil, timeout: timeout)
    }

    @discardableResult
    static func post(
        _ path: String, body: Data? = nil, timeout: TimeInterval = 15,
    ) async -> Data? {
        await request(path, method: "POST", body: body, timeout: timeout)
    }

    private static func request(
        _ path: String, method: String, body: Data?, timeout: TimeInterval,
    ) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.control)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    private enum Timing {
        /// How long launchd gets to bring a freshly registered agent up.
        static let startupPolls = 15
    }
}
