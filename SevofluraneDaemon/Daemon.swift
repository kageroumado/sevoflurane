import Foundation

/// Everything that owns the bottle, in a LaunchAgent that outlives the app: it
/// spawns and reaps every bottle process, runs the restart ladder and serves
/// the control port. Quitting the app takes the bottle down; an app crash does not.
@MainActor
final class Daemon {
    let app = AppLink()
    /// Nil until ``start()`` has run: a `SIGTERM` can arrive before it.
    private var supervisor: BottleSupervisor?
    private var control: ControlServer?
    private var orphanWatch: Task<Void, Never>?

    /// Answers how the control port went. With another supervisor holding
    /// it, this process has nothing to do and should end.
    func start() async -> ControlServer.StartOutcome {
        // Ownership first: everything spawned from here carries this pid, and
        // the engine's dock shim brings the prefix down if it dies.
        BottleOwner.claim()
        // Toolkits an engine carries join the shared store before anything is staged.
        D3DMetalInstaller.adoptInstalledEnginesToolkits()
        ClientLifecycle.log = { EventLog.enqueue(.client, $0) }
        // Staging's notes go to the event log: nobody reads the daemon's stderr.
        SetupLog.log = { EventLog.enqueue(.setup, $0) }
        ConfigMaterializer.engine = { Engine.active }
        // Both travel the app's bridge, the one live connection to the client.
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
                await self.app.push(self.snapshot(health, of: supervisor))
            }
        }
        supervisor.onSessionChange = { [weak self] _ in
            guard let self else { return }
            Task(name: "Push the Steam session") {
                await self.app.push(self.snapshot(supervisor.health, of: supervisor))
            }
        }
        supervisor.onPressureChange = { [weak self] _ in
            guard let self else { return }
            Task(name: "Push the Mac's load") {
                await self.app.push(self.snapshot(supervisor.health, of: supervisor))
            }
        }
        self.supervisor = supervisor
        let control = ControlServer(supervisor: supervisor, app: app) { [weak self] in
            await self?.bringTheBottleDown()
        }
        self.control = control
        let outcome = await control.start()
        guard outcome == .serving else { return outcome }
        EventLog.shared.log(
            .supervisor,
            "daemon up (pid \(getpid())) — it owns the bottle from here",
        )
        supervisor.start()
        watchForOrphans()
        return .serving
    }

    /// How often the engines' processes are checked for a dead wineserver. Two sightings in a
    /// row end one, so an orphan lives at most twice this.
    private static let orphanInterval: Duration = .seconds(60)

    /// Ends Wine processes whose wineserver is gone, in any prefix the managed
    /// engines run, for engines without the dead-name watch.
    private func watchForOrphans() {
        orphanWatch = Task(name: "Reap Wine orphans") {
            var reaper = WineOrphanReaper()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.orphanInterval)
                let found = await Task.detached(priority: .utility) { WineOrphans.find() }.value
                let ended = WineOrphans.end(reaper.confirm(found))
                guard !ended.isEmpty else { continue }
                let prefixes = Set(ended.map(\.prefix)).sorted().joined(separator: ", ")
                EventLog.shared.log(
                    .supervisor,
                    "ended \(ended.count) Wine process\(ended.count == 1 ? "" : "es") whose wineserver is gone (\(prefixes))",
                )
            }
        }
    }

    private func snapshot(
        _ health: SupervisorHealth, of supervisor: BottleSupervisor,
    ) -> SupervisorSnapshot {
        SupervisorSnapshot(
            health,
            isBusyRestarting: supervisor.isBusyRestarting,
            version: Daemon.bundledAppVersion,
            build: Daemon.build,
            host: supervisor.pressure.isElevated ? supervisor.pressure : nil,
            signedInElsewhere: supervisor.sessionLoss,
        )
    }

    /// This process's own build, read from its image in memory.
    static let build = MachOIdentity.ofThisProcess

    /// The version of the app this daemon ships in. `Bundle.main` is
    /// `Contents/Library/LaunchAgents`, three levels inside the app;
    /// `CommandLine.arguments[0]` is relative to the bundle and cannot be walked.
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
        await supervisor?.shutdownForQuit()
    }
}
