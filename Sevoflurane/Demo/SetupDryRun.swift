#if DEBUG
    import Foundation

    /// The onboarding test harness: fixture machines for the wizard to run
    /// against without touching this one.
    ///
    /// Boot into one with `SEVO_DEMO=<raw value>` (see ``DemoMode``), or open
    /// one from Debug ▸ Onboarding Dry Run. Every simulated action logs what
    /// the live environment would have run to `~/Library/Logs/Sevoflurane.log`
    /// under `setup`, prefixed `dry-run:`.
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
        /// Several bottles carry a Steam install, so the wizard asks which.
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

        /// Where the fixture machine keeps its bottles: a directory that is
        /// never read or written. Bottle matching is scoped to this root, so a
        /// dry run ignores this machine's engine store.
        static let bottlesRoot = URL(fileURLWithPath: "/private/var/empty/Sevoflurane/Bottles")

        /// The bottle the fixture machine drives, until the wizard's bottle
        /// step names another.
        static let bottleName = SteamBottle.defaultName

        private static func bottle(
            named name: String = SetupScenario.bottleName, hasSteam: Bool,
        ) -> SetupDetection.Bottle {
            SetupDetection.Bottle(
                name: name,
                url: bottlesRoot.appendingPathComponent(name),
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
                        // Another engine's bottle of the same name, which a
                        // real Mac with CrossOver and Dormison both has.
                        SetupDetection.Bottle(
                            name: "Steam",
                            url: URL(fileURLWithPath: "/private/var/empty/CrossOver/Bottles/Steam"),
                            hasSteam: true,
                        ),
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

    /// A `SetupEnvironment` that never touches the machine: every action logs
    /// the live command, pauses so progress states show, and mutates the
    /// fixture as the real action would the machine.
    @MainActor
    final class DryRunSetupEnvironment: SetupEnvironment {
        let isSimulation = true
        private(set) var bottleName = SetupScenario.bottleName
        let bottlesRoot = SetupScenario.bottlesRoot
        /// The engine choice stored on the fixture machine; `nil` until the
        /// assistant stores one. A simulated machine never follows the engine
        /// this Mac's owner chose.
        var storedEngineIsManaged: Bool?
        /// The fixture's own CrossOver decides the engine stage until a
        /// choice is stored.
        var wantsManagedEngine: Bool {
            storedEngineIsManaged ?? false
        }

        /// The fixture's answer to the sharing question.
        var sharesRunStats: Bool?
        var assistantInProgress = false
        /// Whether the fixture is an Apple silicon Mac.
        var runsD3DMetal = true
        /// What each of the fixture's Steams holds, by bottle name.
        var factsByBottle: [String: SteamLibraryFacts] = [:]

        private(set) var state: SetupDetection
        /// Per-stage think time; tests pass `.zero`.
        private let stepDelay: Duration
        private var loginItem = true
        private var detectCount = 0
        var installedDependencies: Set<String> = []
        var dependencyFailure: String?
        /// Catalog ids whose install refuses.
        var failingDependencies: Set<String> = []
        private(set) var dependencyInstalls: [String] = []
        /// How many Steam installer runs fail before one succeeds: every run
        /// in the installer-fails scenario.
        var installerFailures: Int
        private var installerFailedIn: Set<String> = []
        private(set) var setAsideBottles: [String] = []
        /// Bottles whose boot left no 32-bit system DLLs; the next one
        /// created is complete.
        var incompleteBottles: Set<String> = []
        /// Whether a licensed CrossOver turns up on the fourth check of a
        /// machine without a usable one. Off, the machine stays as it began.
        var crossOverAppearsOnRecheck = true
        /// The action a run stops in and stays, so the gallery can draw the
        /// assistant at that moment.
        var hold: Hold?
        /// What Rosetta's installer prints as it fails; `nil` installs it.
        var rosettaFailure: String?
        /// What the engine install fails with; `nil` installs it.
        var engineFailure: String?
        /// What fetching Steam's installer throws; `nil` fetches it.
        var installerDownloadFailure: (any Error)?

        /// An action of the live environment a simulated run can stop in.
        enum Hold: Equatable {
            case rosetta
            /// The engine's download, this far through.
            case engineDownload(fraction: Double)
            case bottleCreation
            case steamInstaller
            case clientUpdate
            case dependency
        }

        /// The size the manifest declares for a Dormison release, in megabytes.
        private static let engineMegabytes = 230

        init(
            scenario: SetupScenario,
            stepDelay: Duration = .seconds(2),
            detection: SetupDetection? = nil,
        ) {
            self.stepDelay = stepDelay
            installerFailures = scenario == .installerFails ? .max : 0
            // The Engine pane passes its own detection so a re-detect agrees
            // with the bottles ``DemoEngineEnvironment`` shows.
            state = detection ?? scenario.fixture
            log("scenario '\(scenario.rawValue)' — nothing on this machine will be touched")
        }

        func chooseBottle(named name: String) {
            log("would name \(name) the bottle this installation drives")
            bottleName = name
        }

        func storeEngineChoice(managed: Bool) {
            log("would store the engine choice: \(managed ? "built-in" : "CrossOver")")
            storedEngineIsManaged = managed
        }

        /// The built-in engine on a fixture with no usable CrossOver, as the
        /// engine stage decides it.
        var usesManagedEngine: Bool {
            storedEngineIsManaged ?? (state.usableCrossOver == nil)
        }

        /// Every bottle under the fixture's root lives with the fixture's
        /// engine; a bottle anywhere else is another engine's.
        func engineIsManaged(ofBottleAt url: URL) -> Bool? {
            url.deletingLastPathComponent().standardizedFileURL.path == bottlesRoot.standardizedFileURL.path
                ? usesManagedEngine : nil
        }

        func libraryFacts(ofBottleAt url: URL) async -> SteamLibraryFacts {
            factsByBottle[url.lastPathComponent] ?? SteamLibraryFacts()
        }

        func answerSharing(_ shares: Bool) {
            log("would store the sharing answer: \(shares)")
            sharesRunStats = shares
        }

        func detect() async -> SetupDetection {
            detectCount += 1
            // From the fourth check on, a licensed CrossOver appears.
            if crossOverAppearsOnRecheck, state.usableCrossOver == nil, detectCount >= 4 {
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

        /// Renames the fixture's bottles, posing a Steam that lives elsewhere.
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
            await stay(in: .rosetta)
            await pause()
            if let rosettaFailure { return .failure(rosettaFailure) }
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
            // The live download's own phase, so the page reads as it does there.
            let downloading = String(localized: "Downloading the engine (~\(Self.engineMegabytes) MB)…")
            if let tarball {
                log("would install the managed engine from \(tarball.path)")
                version = EngineInstaller.versionName(of: tarball)
                progress("Installing…", nil)
                await pause()
            } else if case let .engineDownload(fraction) = hold {
                log("would download the managed engine the manifest names, and stays \(fraction) of the way through")
                progress(downloading, fraction)
                await stayForever()
                return .failure("the held download was cancelled")
            } else {
                log("would download the managed engine the manifest names")
                version = "dry-run-engine"
                for step in 1 ... 4 {
                    progress(downloading, Double(step) / 4)
                    await pause()
                }
            }
            if let engineFailure { return .failure(engineFailure) }
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
            await stay(in: .bottleCreation)
            await pause()
            state = SetupDetection(
                rosetta: state.rosetta,
                crossover: state.crossover,
                bottles: state.bottles + [SetupDetection.Bottle(
                    name: name,
                    url: bottlesRoot.appendingPathComponent(name),
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
            if let installerDownloadFailure { throw installerDownloadFailure }
        }

        func runSteamInstaller(inBottle name: String) async -> SetupCommandOutcome {
            await stay(in: .steamInstaller)
            guard installerFailures == 0 else {
                if installerFailures != .max { installerFailures -= 1 }
                log("simulating installer failure: wine --bottle \(name) "
                    + #"C:\SteamSetup.exe /S → exit 1"#)
                return .failure("simulated NSIS failure (scenario installer-fails)")
            }
            log(#"would run: wine --bottle \#(name) C:\SteamSetup.exe /S"#)
            await pause()
            return .success()
        }

        func markSteamInstallerFailed(inBottle name: String) {
            installerFailedIn.insert(name)
        }

        func steamInstallerFailed(inBottle name: String) -> Bool {
            installerFailedIn.contains(name)
        }

        func bottleIsComplete(named name: String) -> Bool {
            !incompleteBottles.contains(name)
        }

        func setAsideBottle(named name: String) async throws -> String {
            let aside = "\(name).broken-dry-run"
            log("would run: wineserver -k in \(name), then rename it \(aside)")
            installerFailedIn.remove(name)
            incompleteBottles.remove(name)
            setAsideBottles.append(aside)
            state = SetupDetection(
                rosetta: state.rosetta,
                crossover: state.crossover,
                bottles: state.bottles.filter { $0.name != name },
                managedEngineVersions: state.managedEngineVersions,
            )
            return aside
        }

        func updateSteamClient(inBottle name: String) async {
            log("would run: wine --bottle \(name) steam.exe -forcesteamupdate "
                + "-forcepackagedownload -exitsteam (the long download)")
            await stay(in: .clientUpdate)
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
            log(#"would run: wine --bottle \#(name) reg add "HKCU\Software\Wine\Mac Driver" "#
                + "/v StatusItems /t REG_SZ /d N /f")
            if Engine.active.keepsSDLBus {
                log(#"would run: wine --bottle \#(name) reg delete "#
                    + #"HKLM\System\CurrentControlSet\Services\winebus /v "Enable SDL" /f"#)
            } else {
                log(#"would run: wine --bottle \#(name) reg add "#
                    + #"HKLM\System\CurrentControlSet\Services\winebus "#
                    + #"/v "Enable SDL" /t REG_DWORD /d 0 /f"#)
            }
        }

        func endWineProcesses(inBottle name: String) async {
            log("would run: wineserver -k in \(name)")
        }

        func isDependencyInstalled(_ dependency: BottleDependencies.Dependency) -> Bool {
            installedDependencies.contains(dependency.id)
        }

        func installDependency(_ dependency: BottleDependencies.Dependency) async -> SetupCommandOutcome {
            dependencyInstalls.append(dependency.id)
            log("would install \(dependency.name) in \(bottleName)")
            await stay(in: .dependency)
            await pause()
            if failingDependencies.contains(dependency.id) {
                return .failure("\(dependency.name) refused to install")
            }
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

        /// Stops the run in `action` when that is the one it holds.
        private func stay(in action: Hold) async {
            guard hold == action else { return }
            log("staying in \(action) for the gallery")
            await stayForever()
        }

        /// Sleeps until the run's task is cancelled or the process ends.
        private func stayForever() async {
            try? await Task.sleep(for: .seconds(Self.foreverSeconds))
        }

        /// A year: longer than any gallery stays open.
        private static let foreverSeconds = 365 * 86_400
    }
#endif
