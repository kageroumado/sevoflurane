#if DEBUG
    import Foundation

    /// The onboarding test harness: fixture machines for the wizard to run
    /// against without touching this one.
    ///
    /// Boot straight into one with `SEVO_DEMO=<raw value>` (see ``DemoMode``),
    /// or open one at any time from Debug ▸ Onboarding Dry Run in a debug
    /// build. Every simulated action writes what the live environment would
    /// have run to `~/Library/Logs/Sevoflurane.log` under the `setup`
    /// category, prefixed `dry-run:` — the wizard's whole story is greppable
    /// afterward.
    enum SetupScenario: String, CaseIterable {
        /// Nothing installed: no Rosetta, no CrossOver, no bottles.
        case freshMachine = "fresh-machine"
        /// CrossOver installed but its 14-day trial ran out, unlicensed.
        case trialExpired = "trial-expired"
        /// Licensed CrossOver without Rosetta — exercises the Rosetta stage.
        case noRosetta = "no-rosetta"
        /// Licensed CrossOver, Rosetta present, no bottle yet — the happy path.
        case licensedNoBottle = "licensed-no-bottle"
        /// The bottle exists but Steam was never installed into it.
        case bottleWithoutSteam = "bottle-without-steam"
        /// Several bottles already carry a Steam install — the one case where
        /// the wizard has to ask which one is ours.
        case multipleBottles = "multiple-bottles"
        /// The NSIS installer fails — exercises the wizard's failure surface.
        case installerFails = "installer-fails"
        /// Everything present: the wizard should never gate on this machine.
        case provisioned

        var title: String {
            switch self {
            case .freshMachine: "Fresh Machine"
            case .trialExpired: "CrossOver Trial Expired"
            case .noRosetta: "No Rosetta"
            case .licensedNoBottle: "Licensed, No Bottle"
            case .bottleWithoutSteam: "Bottle Without Steam"
            case .multipleBottles: "Multiple Steam Bottles"
            case .installerFails: "Installer Fails"
            case .provisioned: "Fully Provisioned"
            }
        }

        static let licensedCrossOver = SetupDetection.CrossOver(
            version: "26.3", licensed: true, expires: "2030/01/01", trialExpired: false,
        )
        private static let expiredCrossOver = SetupDetection.CrossOver(
            version: "26.3", licensed: false, expires: nil, trialExpired: true,
        )

        /// Fixture bottles sit under the *active engine's* root — the
        /// provisioner scopes bottle matching to it, and a dry run never
        /// changes `Engine.active`, so this is the one root its checks
        /// accept whatever engine the host machine happens to run.
        private static func bottle(
            named name: String = SteamBottle.defaultName, hasSteam: Bool,
        ) -> SetupDetection.Bottle {
            SetupDetection.Bottle(
                name: name,
                url: Engine.active.bottlesRoot.appendingPathComponent(name),
                hasSteam: hasSteam,
            )
        }

        var fixture: SetupDetection {
            switch self {
            case .freshMachine:
                SetupDetection(
                    rosetta: false, crossover: nil, bottles: [], managedEngineVersions: [],
                )
            case .trialExpired:
                SetupDetection(
                    rosetta: true, crossover: Self.expiredCrossOver, bottles: [],
                    managedEngineVersions: [],
                )
            case .noRosetta:
                SetupDetection(
                    rosetta: false, crossover: Self.licensedCrossOver, bottles: [],
                    managedEngineVersions: [],
                )
            case .licensedNoBottle, .installerFails:
                SetupDetection(
                    rosetta: true, crossover: Self.licensedCrossOver, bottles: [],
                    managedEngineVersions: [],
                )
            case .bottleWithoutSteam:
                SetupDetection(
                    rosetta: true, crossover: Self.licensedCrossOver,
                    bottles: [Self.bottle(hasSteam: false)], managedEngineVersions: [],
                )
            case .multipleBottles:
                SetupDetection(
                    rosetta: true, crossover: Self.licensedCrossOver,
                    bottles: [
                        Self.bottle(named: "Steam", hasSteam: true),
                        Self.bottle(named: "Steam Beta", hasSteam: true),
                        Self.bottle(named: "Games", hasSteam: true),
                        Self.bottle(named: "Office", hasSteam: false),
                    ],
                    managedEngineVersions: [],
                )
            case .provisioned:
                SetupDetection(
                    rosetta: true, crossover: Self.licensedCrossOver,
                    bottles: [Self.bottle(hasSteam: true)], managedEngineVersions: [],
                )
            }
        }
    }

    /// A `SetupEnvironment` that never touches the machine: every action logs the
    /// command the live environment would have run, waits long enough for the
    /// wizard's progress states to be visible, and mutates the scenario fixture
    /// the way the real action would mutate the machine.
    @MainActor
    final class DryRunSetupEnvironment: SetupEnvironment {
        let isSimulation = true

        private(set) var state: SetupDetection
        private let scenario: SetupScenario
        /// Per-stage think time; tests pass `.zero`.
        private let stepDelay: Duration
        private var loginItem = true
        private var detectCount = 0
        var installedDependencies: Set<String> = []
        var dependencyFailure: String?
        private(set) var dependencyInstalls: [String] = []

        init(
            scenario: SetupScenario,
            stepDelay: Duration = .seconds(2),
            detection: SetupDetection? = nil,
        ) {
            self.scenario = scenario
            self.stepDelay = stepDelay
            // A caller that has its own machine in mind passes it: the Engine
            // pane builds its list from detection and its bottles from
            // ``DemoEngineEnvironment``, and a re-detect that reverted to the
            // scenario's fixture would make those two disagree.
            state = detection ?? scenario.fixture
            log("scenario '\(scenario.rawValue)' — nothing on this machine will be touched")
        }

        func detect() async -> SetupDetection {
            detectCount += 1
            // "Check again" on the engine step deserves a way forward: a few
            // re-checks in, the simulated user has bought or installed CrossOver.
            if state.usableCrossOver == nil, detectCount >= 4 {
                state = SetupDetection(
                    rosetta: state.rosetta,
                    crossover: SetupScenario.licensedCrossOver,
                    bottles: state.bottles,
                    managedEngineVersions: state.managedEngineVersions,
                )
                log("simulating a licensed CrossOver appearing on re-check #\(detectCount)")
            }
            log("detect #\(detectCount): rosetta=\(state.rosetta) "
                + "crossover=\(state.crossover.map { "\($0.version) licensed=\($0.licensed)" } ?? "none") "
                + "bottles=\(state.bottles.count) withSteam=\(state.steamBottles.count)")
            return state
        }

        /// Renames the fixture's Steam-bearing bottle, so a test can pose the
        /// "their Steam lives somewhere else" machine.
        func renameSteamBottle(to name: String) {
            state = SetupDetection(
                rosetta: state.rosetta,
                crossover: state.crossover,
                bottles: state.bottles.map {
                    SetupDetection.Bottle(name: name, url: $0.url, hasSteam: $0.hasSteam)
                },
                managedEngineVersions: state.managedEngineVersions,
            )
        }

        func installRosetta() async -> SetupCommandOutcome {
            log("would run: softwareupdate --install-rosetta --agree-to-license")
            await pause()
            state = SetupDetection(
                rosetta: true, crossover: state.crossover, bottles: state.bottles,
                managedEngineVersions: state.managedEngineVersions,
            )
            return .success()
        }

        func installEngine(
            from tarball: URL?,
            progress: @escaping @Sendable (String, Double?) -> Void,
        ) async -> SetupCommandOutcome {
            let version: String
            if let tarball {
                log("would install the managed engine from \(tarball.path)")
                version = EngineInstaller.versionName(of: tarball)
                progress("Installing…", nil)
                await pause()
            } else {
                log("would download the managed engine from the stable manifest channel")
                version = "dry-run-engine"
                for step in 1...4 {
                    progress("Downloading the engine…", Double(step) / 4)
                    await pause()
                }
            }
            state = SetupDetection(
                rosetta: state.rosetta,
                crossover: state.crossover,
                bottles: state.bottles,
                managedEngineVersions: state.managedEngineVersions + [version],
            )
            return .success(version)
        }

        func createBottle(named name: String) async -> SetupCommandOutcome {
            log("would run: cxbottle --bottle \(name) --create --template win10_64")
            await pause()
            state = SetupDetection(
                rosetta: state.rosetta,
                crossover: state.crossover,
                bottles: state.bottles + [SetupDetection.Bottle(
                    name: name,
                    url: Engine.active.bottlesRoot.appendingPathComponent(name),
                    hasSteam: false,
                )],
                managedEngineVersions: state.managedEngineVersions,
            )
            return .success()
        }

        func downloadSteamInstaller(intoBottle name: String) async throws {
            log("would download SteamSetup.exe from the Steam CDN "
                + "into Bottles/\(name)/drive_c/")
            await pause()
        }

        func runSteamInstaller(inBottle name: String) async -> SetupCommandOutcome {
            guard scenario != .installerFails else {
                log("simulating installer failure: wine --bottle \(name) "
                    + #"C:\SteamSetup.exe /S → exit 1"#)
                return .failure("simulated NSIS failure (scenario installer-fails)")
            }
            log(#"would run: wine --bottle \#(name) C:\SteamSetup.exe /S"#)
            await pause()
            return .success()
        }

        func updateSteamClient(inBottle name: String) async {
            log("would run: wine --bottle \(name) steam.exe -forcesteamupdate "
                + "-forcepackagedownload -exitsteam (the long download)")
            await pause()
            state = SetupDetection(
                rosetta: state.rosetta,
                crossover: state.crossover,
                bottles: state.bottles.map {
                    $0.name == name
                        ? SetupDetection.Bottle(name: $0.name, url: $0.url, hasSteam: true)
                        : $0
                },
                managedEngineVersions: state.managedEngineVersions,
            )
        }

        func configureBottle(named name: String) async {
            log(#"would run: wine --bottle \#(name) reg add HKCU\Software\Wine\Explorer "#
                + "/v ShowSystray /t REG_SZ /d N /f")
            if Engine.active.keepsSDLBus {
                log(#"would run: wine --bottle \#(name) reg delete "#
                    + #"HKLM\System\CurrentControlSet\Services\winebus /v "Enable SDL" /f"#)
            } else {
                log(#"would run: wine --bottle \#(name) reg add "#
                    + #"HKLM\System\CurrentControlSet\Services\winebus "#
                    + #"/v "Enable SDL" /t REG_DWORD /d 0 /f"#)
            }
        }

        func isDependencyInstalled(_ dependency: BottleDependencies.Dependency) -> Bool {
            installedDependencies.contains(dependency.id)
        }

        func installDependency(_ dependency: BottleDependencies.Dependency) async -> SetupCommandOutcome {
            dependencyInstalls.append(dependency.id)
            log("would install \(dependency.name) in \(SteamBottle.name)")
            await pause()
            if let dependencyFailure { return .failure(dependencyFailure) }
            installedDependencies.insert(dependency.id)
            return .success()
        }

        func setOpenAtLogin(_ enabled: Bool) throws {
            log("would \(enabled ? "register" : "unregister") the login item")
            loginItem = enabled
        }

        var openAtLogin: Bool {
            loginItem
        }

        private func log(_ message: String) {
            EventLog.shared.log(.setup, "dry-run: \(message)")
        }

        private func pause() async {
            try? await Task.sleep(for: stepDelay)
        }
    }
#endif
