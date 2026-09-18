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

    /// The result of rebuilding the daemon's registration, for the caller —
    /// the CLI, a Settings button, or the launch self-heal — to report.
    enum RepairResult: Equatable {
        /// Rebuilt, and the daemon answered.
        case reachable
        /// The daemon was already answering, so nothing was rebuilt — the
        /// common case for a `repair` run out of curiosity, which must not
        /// tear a healthy helper down.
        case alreadyHealthy
        /// Rebuilt, and macOS is waiting on the user to approve it again.
        case needsApproval(String)
        /// The rebuild itself failed, or the daemon did not come back.
        case failed(String)
    }

    /// One automatic rebuild per launch: a rebuild that does not take surfaces
    /// to the user rather than re-registering forever. A user-driven
    /// ``repair()`` ignores this — it is the escape hatch, not the loop guard.
    private static var healAttempted = false
    /// One automatic restart of a stale helper per launch, for the same
    /// reason a rebuild is capped: a restart that does not take must not spin.
    private static var staleRestartAttempted = false

    /// Registers the daemon if it is not registered, then waits for it to
    /// answer. Idempotent: this is both first-run setup and the Retry the
    /// terminal state offers. A registered helper that stays silent is rebuilt
    /// once (the poisoned Background Task Management record), and a helper
    /// older than this app is restarted once (an app updated under it).
    static func ensureRunning() async -> Outcome {
        // A test host carries the shipping app's bundle identifier and the
        // same `AssociatedBundleIdentifiers`, so registering from one rewrites
        // the live install's helper record and launchd boots the running
        // daemon out. That bootout is a SIGTERM, and the daemon's SIGTERM
        // contract is to bring the bottle down — a unit test would close the
        // Steam client somebody is playing on.
        if TestHost.isHosting { return reachable }
        // A registration has to exist before launchd can bring the agent up:
        // the never-registered machine registers now, an unapproved one is
        // sent to Login Items, and an enabled-but-stopped one is given launchd
        // its window below.
        if await status() == nil {
            switch service.status {
            case .enabled:
                break
            case .requiresApproval:
                return approvalNeeded
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
                if service.status == .requiresApproval { return approvalNeeded }
            @unknown default:
                break
            }
            _ = await waitForAnswer()
        }

        let current = await status()
        let action = DaemonHeal.decide(DaemonHeal.Inputs(
            isRegistered: service.status == .enabled,
            isAnswering: current != nil,
            healAlreadyAttempted: healAttempted,
            daemonVersion: current?["version"] as? String,
            appVersion: appVersion,
        ))
        switch action {
        case .none:
            return reachable
        case .rebuild:
            // The decision above already found the daemon silent, so the
            // rebuild runs directly rather than re-probing through `repair()`.
            return await outcome(of: rebuild())
        case .restartStale:
            await restartStaleDaemonOnce()
            return reachable
        case .surfaceFailure:
            return stuck
        }
    }

    /// The user-driven escape hatch, from `sevo daemon repair` and Settings.
    /// A daemon that is already answering is left running — rebuilding it would
    /// only detach the live app and force a relaunch — and only a silent one is
    /// rebuilt. `force` rebuilds regardless, for a daemon that answers but is
    /// still wrong.
    static func repair(force: Bool = false) async -> RepairResult {
        if TestHost.isHosting { return .alreadyHealthy }
        switch await DaemonHeal.repairAction(isAnswering: isAnswering(), force: force) {
        case .alreadyHealthy:
            return .alreadyHealthy
        case .rebuild:
            return await rebuild()
        }
    }

    /// Rebuilds the registration from this bundle's identity: `unregister()`
    /// then `register()`. This is the fix for a daemon that will not launch
    /// because a stale record still carries a Development code requirement —
    /// re-registering over an enabled record leaves that requirement in place,
    /// so the record has to be torn down first. Reached from the launch
    /// self-heal and from ``repair(force:)``.
    private static func rebuild() async -> RepairResult {
        healAttempted = true
        await unregister()
        do {
            try service.register()
        } catch {
            return .failed(
                "could not re-register the background helper: " + error.localizedDescription,
            )
        }
        if service.status == .requiresApproval {
            return .needsApproval(approvalMessage)
        }
        return await waitForAnswer()
            ? .reachable
            : .failed("the background helper was rebuilt but has not started yet")
    }

    /// Removes the registration. The uninstall path, and the way a test run
    /// leaves the machine as it found it.
    static func unregister() async {
        try? await service.unregister()
    }

    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Healing

    private static func restartStaleDaemonOnce() async {
        guard !staleRestartAttempted else { return }
        staleRestartAttempted = true
        EventLog.enqueue(
            .supervisor,
            "the background helper is older than the app — restarting it",
        )
        let target = "gui/\(getuid())/\(SupervisorLink.label)"
        _ = await Subprocess.run(
            "/bin/launchctl", ["kickstart", "-k", target], timeout: .seconds(15),
        )
        _ = await waitForAnswer()
    }

    private static func outcome(of result: RepairResult) -> Outcome {
        switch result {
        case .reachable, .alreadyHealthy:
            reachable
        case let .needsApproval(message):
            Outcome(isReachable: false, message: message, needsApproval: true)
        case .failed:
            stuck
        }
    }

    private static let approvalMessage = "Approve Sevoflurane's background helper in Login Items."

    private static var approvalNeeded: Outcome {
        Outcome(isReachable: false, message: approvalMessage, needsApproval: true)
    }

    private static var reachable: Outcome {
        Outcome(isReachable: true, message: "", needsApproval: false)
    }

    private static var stuck: Outcome {
        Outcome(
            isReachable: false,
            message: "The background helper is registered and won't start. "
                + "Repair it in Settings, or run: sevo daemon repair.",
            needsApproval: false,
        )
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func waitForAnswer() async -> Bool {
        // launchd starts a freshly registered or restarted agent on its own
        // schedule.
        for _ in 0 ..< Timing.startupPolls {
            try? await Task.sleep(for: .seconds(1))
            if await isAnswering() { return true }
        }
        return false
    }

    // MARK: - Control port

    static func isAnswering() async -> Bool {
        await get("/status", timeout: 2) != nil
    }

    /// The daemon's `/status` as a dictionary, or nil when it is not answering.
    /// Carries `version`, which the launch self-heal compares against the app.
    static func status() async -> [String: Any]? {
        guard let data = await get("/status", timeout: 2),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
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
