import Foundation
import ServiceManagement

/// Registering, reaching, and talking to `SevofluraneDaemon`, a `KeepAlive`
/// LaunchAgent embedded in this bundle and registered with `SMAppService` on
/// first launch. It owns the bottle, and there is no in-process supervisor to
/// fall back to, by design.
@MainActor
enum DaemonService {
    private static var service: SMAppService {
        SMAppService.agent(plistName: SupervisorLink.launchAgentPlistName)
    }

    /// What the app knows about supervision, and what to tell the user.
    struct Outcome: Equatable {
        let isReachable: Bool
        /// A sentence for the menu bar. Empty when everything is running.
        let message: String
        /// Whether Login Items is where the user finishes the job.
        let needsApproval: Bool
    }

    /// The result of rebuilding the daemon's registration, for the CLI,
    /// Settings or the launch self-heal to report.
    enum RepairResult: Equatable {
        /// Rebuilt, and the daemon answered.
        case reachable
        /// The daemon was already answering, so nothing was rebuilt: a `repair`
        /// run must not tear a healthy helper down.
        case alreadyHealthy
        /// The daemon answered but had given up on the client; the client was restarted.
        case restartedClient
        /// Rebuilt, and macOS is waiting on the user to approve it again.
        case needsApproval(String)
        /// The rebuild itself failed, or the daemon did not come back.
        case failed(String)
    }

    /// One automatic rebuild per launch, so a rebuild that does not take
    /// surfaces instead of looping. A user-driven ``repair()`` ignores this.
    private static var healAttempted = false
    /// One automatic restart of a stale helper per launch, so a restart that
    /// does not take cannot spin.
    private static var staleRestartAttempted = false

    /// Registers the daemon if needed, then waits for it to answer; also the
    /// terminal state's Retry. A registered helper that stays silent is rebuilt
    /// once (the poisoned Background Task Management record), and one older
    /// than this app is restarted once.
    static func ensureRunning() async -> Outcome {
        // Never register from a test host: it carries the shipping bundle
        // identifier and `AssociatedBundleIdentifiers`, so launchd would boot
        // the live daemon out with a SIGTERM, which brings the bottle down.
        if TestHost.isHosting { return reachable }
        // launchd brings the agent up only once registered: an unregistered
        // machine registers now, an unapproved one goes to Login Items.
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
            daemonBuild: current?["build"] as? String,
            bundledDaemonBuild: MachOIdentity.ofFile(bundledDaemon),
        ))
        switch action {
        case .none:
            return reachable
        case .rebuild:
            // Already found silent, so rebuild without re-probing through
            // `repair()`.
            return await outcome(of: rebuild())
        case .restartStale:
            // A restart the helper does not come back from is the rebuild's to fix: the new
            // build can be refused at launch by the old registration's code requirement.
            return await restartStaleDaemonOnce() ? reachable : await outcome(of: rebuild())
        case .surfaceFailure:
            return stuck
        }
    }

    /// The user-driven escape hatch, from `sevo daemon repair` and Settings.
    /// Only a silent daemon is rebuilt, since rebuilding a live one detaches
    /// the app; `force` rebuilds regardless.
    static func repair(force: Bool = false) async -> RepairResult {
        if TestHost.isHosting { return .alreadyHealthy }
        let current = await status()
        switch DaemonHeal.repairAction(
            isAnswering: current != nil,
            supervisionGaveUp: current?["health"] as? String == "gaveUp",
            force: force,
        ) {
        case .alreadyHealthy:
            return .alreadyHealthy
        case .restartClient:
            return await post("/client/restart") != nil
                ? .restartedClient
                : .failed("the background helper did not take the client restart")
        case .rebuild:
            return await rebuild()
        }
    }

    /// Rebuilds the registration: `unregister()` then `register()`.
    /// Re-registering over an enabled record keeps a stale Development code
    /// requirement that stops the daemon launching, so the record is torn down
    /// first.
    ///
    /// Two attempts, each with a pause after the unregister: registering again
    /// at once can leave launchd refusing the new job (`EX_CONFIG`, `needs LWCR
    /// update`) where a second rebuild takes.
    private static func rebuild() async -> RepairResult {
        healAttempted = true
        var result = await rebuildOnce()
        for attempt in 2 ... Timing.rebuildAttempts {
            guard case let .failed(reason) = result else { return result }
            EventLog.enqueue(.app, "background helper rebuild \(attempt - 1) failed (\(reason)) — rebuilding again")
            result = await rebuildOnce()
        }
        return result
    }

    private static func rebuildOnce() async -> RepairResult {
        await unregister()
        try? await Task.sleep(for: Timing.settleAfterUnregister)
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

    /// Removes the registration, for the uninstall and for a test run.
    static func unregister() async {
        try? await service.unregister()
    }

    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Healing

    private static func restartStaleDaemonOnce() async -> Bool {
        guard !staleRestartAttempted else { return await isAnswering() }
        staleRestartAttempted = true
        EventLog.enqueue(
            .supervisor,
            "the background helper is another build than this app's — restarting it",
        )
        let target = "gui/\(getuid())/\(SupervisorLink.label)"
        _ = await Subprocess.run(
            "/bin/launchctl", ["kickstart", "-k", target], timeout: .seconds(15),
        )
        return await waitForAnswer()
    }

    private static func outcome(of result: RepairResult) -> Outcome {
        switch result {
        case .reachable, .alreadyHealthy, .restartedClient:
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

    /// The daemon this app ships.
    private static var bundledDaemon: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/SevofluraneDaemon")
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func waitForAnswer() async -> Bool {
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
    /// Its `version` is what the self-heal compares.
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

    /// A POST answered with its HTTP status (`/client/stop` answers 409 while a
    /// restart runs), or `nil` when nothing answered.
    static func postStatus(_ path: String, timeout: TimeInterval = 15) async -> Int? {
        await exchange(path, method: "POST", body: nil, timeout: timeout)?.status
    }

    /// A POST's status and body, for a refusal worth showing, or `nil` when
    /// nothing answered.
    static func postReply(
        _ path: String, timeout: TimeInterval = 15,
    ) async -> (data: Data, status: Int)? {
        await exchange(path, method: "POST", body: nil, timeout: timeout)
    }

    private static func request(
        _ path: String, method: String, body: Data?, timeout: TimeInterval,
    ) async -> Data? {
        guard let answer = await exchange(path, method: method, body: body, timeout: timeout),
              (200 ..< 300).contains(answer.status)
        else { return nil }
        return answer.data
    }

    private static func exchange(
        _ path: String, method: String, body: Data?, timeout: TimeInterval,
    ) async -> (data: Data, status: Int)? {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.control)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        ControlToken.authorize(&request)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return (data, http.statusCode)
    }

    private enum Timing {
        /// How long launchd gets to bring a freshly registered agent up.
        static let startupPolls = 15
        static let rebuildAttempts = 2
        /// Between tearing the record down and registering it again.
        static let settleAfterUnregister = Duration.seconds(2)
    }
}
