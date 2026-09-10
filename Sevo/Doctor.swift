import Foundation

/// The support story: every environment detection plus client/bridge/daemon
/// health, one ✔/✖ line each. `--json` is what a user
/// pastes into an issue — no secrets (no account names, no tokens; bottle
/// paths are fine).
nonisolated enum Doctor {
    struct Check {
        let id: String
        let ok: Bool
        let label: String
        /// One-line fix hint, shown only when the check fails.
        let hint: String
        /// Whether a failure means the environment is unprovisioned (exit 3)
        /// rather than a runtime fault (exit 1).
        let provisioning: Bool

        var dictionary: [String: Any] {
            ["id": id, "ok": ok, "label": label, "hint": hint]
        }
    }

    struct Snapshot {
        let detection: SetupDetection
        let clientState: ClientLifecycle.ClientState
        let bottleProcesses: [pid_t]
        let bridgeUp: Bool
        let appStatus: [String: Any]?
        let servicesUp: Bool?
        let dumpCount: Int
        let pinned: Bool
        /// Every dependency catalog entry with its installed state and any
        /// failure on record — the answer to "is this bottle finished".
        let dependencies: [[String: Any]]
        let provision: BottleReadiness.ProvisionOutcome?
    }

    static func snapshot() async -> Snapshot {
        let detection = await SetupProbe.detect()
        let clientState = await ClientLifecycle.probeClient()
        let bottleProcesses = await ClientLifecycle.bottleProcessIDs()
        let appStatus = await AppControl.status()
        var bridgeUp = false
        var servicesUp: Bool?
        if let reply = try? await BridgeEval.eval(
            "String(!!(window.App&&App.GetServicesInitialized&&App.GetServicesInitialized()))",
        ) {
            bridgeUp = true
            if reply.ok { servicesUp = reply.value.contains("true") }
        } else if clientState == .up,
                  let value = try? await SteamJS.eval(
                      "String(!!(window.App&&App.GetServicesInitialized&&App.GetServicesInitialized()))",
                  ) {
            servicesUp = value.contains("true")
        }
        return Snapshot(
            detection: detection,
            clientState: clientState,
            bottleProcesses: bottleProcesses,
            bridgeUp: bridgeUp,
            appStatus: appStatus,
            servicesUp: servicesUp,
            dumpCount: ClientLifecycle.recentDumpCount(),
            pinned: ClientLifecycle.isPinned(),
            dependencies: BottleReadiness.dependencyReport(),
            provision: BottleReadiness.lastProvision,
        )
    }

    static func checks(from s: Snapshot) -> [Check] {
        var checks: [Check] = []
        let d = s.detection

        checks.append(Check(
            id: "rosetta", ok: d.rosetta, label: "Rosetta 2",
            hint: "softwareupdate --install-rosetta", provisioning: true,
        ))

        if let cx = d.crossover, d.usableCrossOver != nil || d.managedEngineVersions.isEmpty {
            let state = cx.licensed ? "licensed" : cx.trialExpired ? "TRIAL EXPIRED" : "trial"
            checks.append(Check(
                id: "engine", ok: d.usableCrossOver != nil,
                label: "CrossOver \(cx.version) (\(state))",
                hint: "an expired trial cannot launch bottles — license CrossOver "
                    + "or install Dormison: sevo engine install",
                provisioning: true,
            ))
        } else {
            checks.append(Check(
                id: "engine", ok: !d.managedEngineVersions.isEmpty,
                label: d.managedEngineVersions.isEmpty
                    ? "engine" : d.managedEngineVersions.map(Engine.managedDisplayName).joined(separator: ", "),
                hint: "no engine — install CrossOver, or run: sevo engine install",
                provisioning: true,
            ))
        }

        let bottleNames = d.bottles.map(\.name).joined(separator: ", ")
        checks.append(Check(
            id: "bottles", ok: !d.bottles.isEmpty,
            label: "bottles: \(bottleNames.isEmpty ? "none" : bottleNames)",
            hint: "run Sevoflurane's setup wizard to create one", provisioning: true,
        ))

        let steamBottle = d.bottles.first { $0.name == SteamBottle.name }
        checks.append(Check(
            id: "steam", ok: steamBottle?.hasSteam == true,
            label: "Steam client in bottle '\(SteamBottle.name)'",
            hint: "run Sevoflurane's setup wizard to install it", provisioning: true,
        ))

        checks.append(contentsOf: dependencyChecks(from: s))

        let clientLabel: String
        let clientOK: Bool
        switch s.clientState {
        case .up:
            clientLabel = "client: CDP :\(BridgePorts.cdp) up, SharedJSContext listed"
            clientOK = true
        case .portWithoutContext:
            clientLabel = "client: CDP up but no SharedJSContext (half-wedged)"
            clientOK = false
        case .busy:
            clientLabel = "client: running, CDP :\(BridgePorts.cdp) too busy to answer"
            clientOK = false
        case .down:
            // A stopped client is a state, not a fault; processes alive with
            // CDP dead is the fault.
            clientOK = s.bottleProcesses.isEmpty
            clientLabel = clientOK
                ? "client: stopped (ok when idle)"
                : "client: processes alive (pids \(s.bottleProcesses)) but CDP down"
        }
        checks.append(Check(
            id: "client", ok: clientOK, label: clientLabel,
            hint: "sevo recover", provisioning: false,
        ))

        let supervising = s.appStatus != nil
        let appHealth = s.appStatus?["health"] as? String ?? "?"
        checks.append(Check(
            id: "daemon",
            ok: supervising && !["degraded", "gaveUp"].contains(appHealth),
            label: supervising
                ? "supervision: running (\(appHealth) — \(s.appStatus?["detail"] as? String ?? ""))"
                : "supervision: not running — open Sevoflurane once to register its background helper",
            hint: "sevo client start", provisioning: false,
        ))

        let appRunning = (s.appStatus?["app"] as? String) == "running"
        checks.append(Check(
            id: "app",
            ok: true,
            label: appRunning
                ? "Sevoflurane app: running"
                : "Sevoflurane app: not running (the daemon keeps the client up without it)",
            hint: "sevo logs --tail 50", provisioning: false,
        ))

        if appRunning {
            checks.append(Check(
                id: "bridge", ok: s.bridgeUp,
                label: "bridge :\(BridgePorts.steamUI)",
                hint: "the app is up but its bridge is down — relaunch Sevoflurane", provisioning: false,
            ))
        }

        if s.clientState == .up {
            checks.append(Check(
                id: "services", ok: s.servicesUp == true,
                label: "Steam services initialized: \(s.servicesUp.map(String.init) ?? "unknown")",
                hint: "the client's UI session is dead — sevo recover", provisioning: false,
            ))
        }

        // Discord being closed is a state, not a fault: the check reports what
        // presence has to work with and never fails the run.
        checks.append(Check(
            id: "discord", ok: true,
            label: DiscordPresence.isDiscordRunning()
                ? "Discord socket: answering in $TMPDIR"
                : "Discord socket: none in $TMPDIR (presence is quiet while Discord is closed)",
            hint: "start Discord", provisioning: false,
        ))

        // Only when the symlink exists at all: a machine that never installed
        // the CLI is healthy, not broken.
        if let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: "/usr/local/bin/sevo") {
            checks.append(Check(
                id: "cli-link", ok: FileManager.default.fileExists(atPath: destination),
                label: "sevo symlink → \(destination)",
                hint: "the app moved since the CLI was installed — reinstall it "
                    + "from Sevoflurane's Settings › General",
                provisioning: false,
            ))
        }

        // A single boot legitimately drops 1–2 asserts, and a supervised
        // restart cycle can reach 3; five in ten minutes is the actual loop
        // signature.
        checks.append(Check(
            id: "dumps", ok: s.dumpCount < 5,
            label: "crash dumps last 10 min: \(s.dumpCount)",
            hint: "crash loop — sevo recover --deep", provisioning: false,
        ))

        if s.pinned {
            checks.append(Check(
                id: "pinned", ok: false,
                label: "client updates PINNED (steam.cfg)",
                hint: "a pinned client eventually loses connectivity — sevo client unpin",
                provisioning: false,
            ))
        }

        return checks
    }

    /// One line per required dependency, plus what the last setup pass ended
    /// as. Optional entries are reported in `--json` and stay out of the
    /// ✔/✖ list: fonts a bottle has never needed are not a fault.
    private static func dependencyChecks(from s: Snapshot) -> [Check] {
        var checks: [Check] = []
        for dependency in BottleDependencies.catalog where dependency.required {
            let installed = BottleDependencies.isInstalled(dependency)
            let failure = BottleReadiness.dependencyFailure(dependency.id)
            checks.append(Check(
                id: "dependency-\(dependency.id)", ok: installed,
                label: "\(dependency.name) in bottle '\(SteamBottle.name)'"
                    + (failure.map { " — last install failed: \($0)" } ?? ""),
                hint: "\(dependency.detail) Install it in Settings › Engine › Game dependencies.",
                provisioning: false,
            ))
        }
        if let provision = s.provision {
            let when = provision.date.formatted(date: .abbreviated, time: .shortened)
            checks.append(Check(
                id: "provisioning", ok: provision.succeeded,
                label: provision.succeeded
                    ? "last setup pass: finished \(when)"
                    : "last setup pass: failed \(when) — \(provision.reason)",
                hint: provision.blocksClientStart
                    ? "the client stays down until this is fixed — sevo setup, "
                        + "or Settings › Engine › Try Again"
                    : "sevo setup, or Settings › Engine › Repair",
                provisioning: true,
            ))
        }
        return checks
    }

    static func jsonReport(from s: Snapshot, checks: [Check]) -> [String: Any] {
        var report: [String: Any] = [
            "sevo": Sevo.version,
            "checks": checks.map(\.dictionary),
            "ok": checks.allSatisfy(\.ok),
            "dump_rate_10m": s.dumpCount,
            "client_pinned": s.pinned,
            "bottle_pids": s.bottleProcesses.map(Int.init),
            "dependencies": s.dependencies,
        ]
        report["provisioning"] = s.provision?.dictionary ?? NSNull()
        report["app"] = s.appStatus ?? ["app": "not running"]
        let d = s.detection
        report["detection"] = [
            "rosetta": d.rosetta,
            "crossover": d.crossover.map {
                [
                    "version": $0.version, "licensed": $0.licensed,
                    "expires": $0.expires ?? NSNull(), "trial_expired": $0.trialExpired,
                ] as [String: Any]
            } ?? NSNull(),
            "bottles": d.bottles.map {
                ["name": $0.name, "steam": $0.hasSteam] as [String: Any]
            },
            "managed_engines": d.managedEngineVersions,
        ] as [String: Any]
        return report
    }
}
