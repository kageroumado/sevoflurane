import Foundation

/// Everything that owns the bottle, in one process that outlives the app.
///
/// The daemon is a LaunchAgent with `KeepAlive`, so it is up whenever the user
/// is logged in and Sevoflurane's background item is enabled. It spawns and
/// reaps every bottle process, runs the restart ladder, and serves the control
/// port; Sevoflurane.app renders Steam and attaches to it, and quitting the app
/// asks the daemon to bring the bottle down.
///
/// The two truths this keeps at once: quitting takes the bottle down, and an
/// app crash does not take a running game down.
@MainActor
final class Daemon {
    let app = AppLink()
    private var supervisor: BottleSupervisor!
    private var control: ControlServer!

    /// Answers false when another supervisor already holds the control port,
    /// in which case this process has nothing to do and should end.
    func start() async -> Bool {
        // Ownership first: everything spawned from here carries this pid, and
        // the engine's dock shim brings the prefix down if it dies.
        BottleOwner.claim()
        ClientLifecycle.log = { EventLog.enqueue(.client, $0) }
        // Both questions are the client's, and the only live connection to it
        // belongs to the app's bridge — so both travel the link rather than
        // opening a second DevTools session per ask.
        ClientLifecycle.hidePopupsOverBridge = { [app] scope in
            await app.sweepClientPopups(scope)
        }
        ClientLifecycle.servicesReadyOverBridge = { [app] in await app.servicesReady() }
        EventLog.mirror = { [weak self] category, message, date in
            guard let self else { return }
            Task(name: "Mirror a log line to the app") {
                await self.app.push(
                    RemoteLogLine(category: category.rawValue, message: message, date: date),
                )
            }
        }
        let supervisor = BottleSupervisor(app: app)
        supervisor.onHealthChange = { [weak self] health in
            guard let self else { return }
            Task(name: "Push the supervisor's verdict") {
                await self.app.push(self.snapshot(health))
            }
        }
        self.supervisor = supervisor
        control = ControlServer(supervisor: supervisor, app: app) { [weak self] in
            await self?.bringTheBottleDown()
        }
        guard await control.start() else { return false }
        EventLog.shared.log(
            .supervisor,
            "daemon up (pid \(getpid())) — it owns the bottle from here",
        )
        supervisor.start()
        return true
    }

    private func snapshot(_ health: SupervisorHealth) -> SupervisorSnapshot {
        SupervisorSnapshot(
            health,
            isBusyRestarting: supervisor.isBusyRestarting,
            version: Daemon.bundledAppVersion,
        )
    }

    /// The version of the app this daemon was copied into.
    ///
    /// A command-line tool carries no Info.plist of its own, and `Bundle.main`
    /// for one is the directory holding the executable — here
    /// `Contents/Library/LaunchAgents`, three directories inside the bundle
    /// whose version this is. `CommandLine.arguments[0]` is not the path to
    /// walk: launchd starts the daemon by its `BundleProgram`, which is
    /// relative to the bundle.
    static let bundledAppVersion: String = {
        let appRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let plist = NSDictionary(
            contentsOf: appRoot.appending(path: "Contents/Info.plist"),
        ) else { return "0" }
        return plist["CFBundleShortVersionString"] as? String ?? "0"
    }()

    /// The quit contract, reached from the `/quit` verb and from `SIGTERM`
    /// (`launchctl bootout`, logout, shutdown). Supervision stops first so
    /// nothing relaunches the client behind the teardown.
    func bringTheBottleDown() async {
        await supervisor.shutdownForQuit()
    }
}
