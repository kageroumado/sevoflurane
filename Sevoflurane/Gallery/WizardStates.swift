#if DEBUG
    import SwiftUI

    /// One state of the first-run assistant past a step's first look: the
    /// machine it happens on and the walk that brings a store there.
    ///
    /// A state a run produces is reached by running one: the walk presses the
    /// assistant's own buttons against a simulated machine that stops in, or
    /// fails, the action named, so the page shows what the provisioner leaves
    /// and follows it when that changes. Only a state a simulated machine
    /// cannot reach (Steam being stopped, Apple's page) is staged by hand.
    @MainActor
    final class WizardState: Identifiable {
        /// `<step>-<state>`; the export writes `setup-<id>.png`.
        let id: String
        let store: SetupStore
        /// What the finish page is told Steam's windows are doing.
        let steamWindow: SetupSteamWindow
        private let walk: (@MainActor (SetupStore) async -> Void)?
        private var hasWalked = false

        init(
            id: String, store: SetupStore, steamWindow: SetupSteamWindow = .library,
            walk: (@MainActor (SetupStore) async -> Void)? = nil,
        ) {
            self.id = id
            self.store = store
            self.steamWindow = steamWindow
            self.walk = walk
        }

        /// Walks the store to its state, once however many views show it.
        func arrange() async {
            guard !hasWalked else { return }
            hasWalked = true
            await walk?(store)
        }

        /// The assistant in this state, with the finish page's optional
        /// buttons wired so they draw.
        var view: SetupView {
            SetupView(
                store: store, onFinished: {}, steamWindow: { [steamWindow] in steamWindow },
                onRepairHelper: {}, onSkipSignIn: {},
            )
        }

        /// The window's height in this state: the tall one while the step
        /// hosts Apple's page.
        var height: CGFloat {
            store.step == .graphics && SetupGraphicsStep.hostsSignIn(store.gptk, isSimulated: !store.gptk.isStaged)
                ? SetupMetrics.tallWindowHeight : SetupMetrics.windowSize.height
        }
    }

    extension WizardState {
        static let all: [WizardState] = engineStates + bottleStates + installStates + graphicsStates + finishStates

        // MARK: - Machines

        /// The Mac most people set up: Rosetta in place, no CrossOver, nothing
        /// of Sevoflurane's.
        private static let plainMac = SetupDetection(
            rosetta: true, crossover: nil, bottles: [], managedEngineVersions: [],
        )

        private static func make(
            _ id: String, on scenario: SetupScenario, machine detection: SetupDetection? = nil,
            at step: SetupStep = .welcome, activity: Provisioner.Activity = .idle,
            toolkit: DemoGraphicsEnvironment.Scenario = .builtInNoToolkit,
            steamWindow: SetupSteamWindow = .library,
            environment configure: (DryRunSetupEnvironment) -> Void = { _ in },
            walk: (@MainActor (SetupStore) async -> Void)? = nil,
        ) -> WizardState {
            let environment = DryRunSetupEnvironment(scenario: scenario, stepDelay: .zero, detection: detection)
            // Every view of a state checks the machine again; it must stay the
            // machine the state is about.
            environment.crossOverAppearsOnRecheck = false
            configure(environment)
            let provisioner = Provisioner(
                previewActivity: activity, detection: detection ?? scenario.fixture, environment: environment,
            )
            provisioner.installsEveryDependency = true
            let graphics = GraphicsStore(environment: DemoGraphicsEnvironment(scenario: toolkit, stepDelay: .zero))
            let store = SetupStore(provisioner: provisioner, startingAt: step, makeGraphics: { graphics })
            // A store opens on this Mac's stored engine choice; a state names its own.
            store.engineChoice = .builtIn
            return WizardState(id: id, store: store, steamWindow: steamWindow, walk: walk)
        }

        /// Presses the assistant's buttons from the welcome to the install
        /// page, where the run starts; a machine with several Steams stops on
        /// the bottle page.
        private static func pressToInstall(_ store: SetupStore) async {
            await store.detect()
            store.advanceFromWelcome()
            if store.step == .engine { store.advanceFromEngine() }
        }

        // MARK: - Engine

        private static let engineStates: [WizardState] = [
            make("engine-crossover-chosen", on: .freshMachine, at: .engine, walk: { $0.engineChoice = .crossover }),
            make("engine-trial-ended", on: .trialExpired, at: .engine),
            // Reached by installing CrossOver while the page is up, then Check Again.
            make("engine-crossover-found", on: .licensedNoBottle, at: .engine, walk: { $0.engineChoice = .crossover }),
            make("engine-file", on: .freshMachine, at: .engine, walk: {
                $0.useEngineFile(URL(fileURLWithPath: "/Users/you/Downloads/dormison-r14.tar.xz"))
            }),
            make("engine-bundled", on: .freshMachine, at: .engine, walk: {
                $0.stage(bundledEngine: URL(
                    fileURLWithPath: "/Applications/Sevoflurane.app/Contents/Resources/Engine/dormison-r14.tar.xz",
                ))
            }),
        ]

        // MARK: - Bottle

        private static let bottleStates: [WizardState] = [
            make("bottle-adopt", on: .multipleBottles, at: .bottle, walk: { $0.bottleChoice = "Steam" }),
            make("bottle-new", on: .multipleBottles, at: .bottle, walk: {
                $0.bottleChoice = nil
                $0.newBottleName = "Second Steam"
            }),
        ]

        // MARK: - Install

        /// A download failing with the Mac offline, as `URLSession` reports
        /// it and as the provisioner quotes it.
        private static func offline(_ address: String) -> NSError {
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
                NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
                NSURLErrorFailingURLStringErrorKey: address,
                NSURLErrorFailingURLErrorKey: URL(string: address) as Any,
                "_kCFStreamErrorDomainKey": 1,
                "_kCFStreamErrorCodeKey": 50,
                "_NSURLErrorFailingURLSessionTaskErrorKey": "LocalDownloadTask <77B6F5A6-DB29-4239-B696-7BCCC9B89FFB>.<1>",
            ])
        }

        private static func install(
            _ id: String, on scenario: SetupScenario = .freshMachine, machine: SetupDetection? = plainMac,
            environment configure: @escaping (DryRunSetupEnvironment) -> Void = { _ in },
        ) -> WizardState {
            make(id, on: scenario, machine: machine, environment: configure, walk: pressToInstall)
        }

        private static let installStates: [WizardState] = [
            install("steam-rosetta", machine: nil) { $0.hold = .rosetta },
            install("steam-rosetta-failed", machine: nil) {
                $0.rosettaFailure = "The operation couldn’t be completed."
            },
            install("steam-engine-downloading") { $0.hold = .engineDownload(fraction: 0.42) },
            install("steam-engine-failed") {
                $0.engineFailure = "\(offline("https://github.com/kageroumado/dormison/releases/download/r14/dormison-r14.tar.xz"))"
            },
            install("steam-early") { $0.hold = .bottleCreation },
            install("steam-installer") { $0.hold = .steamInstaller },
            install("steam-installer-offline") {
                $0.installerDownloadFailure = offline("https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")
            },
            install("steam-failed") { $0.installerFailures = .max },
            install("steam-late") { $0.hold = .clientUpdate },
            install("steam-fonts") { $0.hold = .dependency },
            install("steam-done"),
            make("steam-adopting", on: .multipleBottles, environment: { $0.hold = .dependency }, walk: { store in
                await pressToInstall(store)
                store.bottleChoice = "Games"
                store.advanceFromBottle()
            }),
            // A simulated machine has no client to stop, so the two states of
            // the stop before a bottle switch are staged as the provisioner
            // leaves them: narrating or failed, on no stage.
            make(
                "steam-stopping", on: .multipleBottles, at: .steam,
                activity: .working(InterfaceCopy.localized("Stopping Steam…")),
            ),
            make(
                "steam-stop-refused", on: .multipleBottles, at: .steam,
                activity: .failed(String(
                    localized: "Steam could not be stopped, so setup kept the bottle it had. Try again, or quit Steam from the menu bar first.",
                )),
            ),
        ]

        // MARK: - DirectX 12

        private static func graphics(
            _ id: String, toolkit: DemoGraphicsEnvironment.Scenario = .builtInNoToolkit,
            route: GPTkDownload.Route = .here, phase: GPTkDownload.AutoPhase = .idle,
            items: [GPTkDownload.Item.Phase] = [], manualCandidate: String? = nil, stoppedEnrollment: Bool = false,
        ) -> WizardState {
            let state = make(id, on: .provisioned, at: .graphics, toolkit: toolkit)
            let files = [
                "Evaluation_environment_for_Windows_games_4.0.dmg",
                "Evaluation_environment_for_Windows_games_4.0_beta_2.dmg",
            ]
            state.store.gptk.stage(
                route: route, autoPhase: phase,
                items: zip(files, items).enumerated().map { index, pair in
                    GPTkDownload.Item(
                        id: index, filename: pair.0, fraction: index == 0 ? 0.64 : 0.21, phase: pair.1,
                    )
                },
                pickedVersions: phase == .downloading ? ["4.0", "4.0 beta 2"] : [],
                manualCandidate: manualCandidate, stoppedEnrollment: stoppedEnrollment,
            )
            return state
        }

        private static let graphicsStates: [WizardState] = [
            graphics("graphics-sign-in"),
            graphics("graphics-enrollment-stopped", stoppedEnrollment: true),
            graphics("graphics-searching", phase: .searching),
            graphics("graphics-downloading", phase: .downloading, items: [.downloading, .downloading]),
            graphics(
                "graphics-download-failed", toolkit: .builtInWithToolkit, phase: .downloading,
                items: [.installed(version: "4.0"), .failed("The network connection was lost.")],
            ),
            graphics(
                "graphics-installed", toolkit: .builtInWithToolkit, phase: .downloading,
                items: [.installed(version: "4.0"), .installed(version: "4.0 beta 2")],
            ),
            graphics(
                "graphics-manual", phase: .manual,
                manualCandidate: "Evaluation environment for Windows games 4.0 beta 2",
            ),
            graphics(
                "graphics-file-rejected",
                items: [.failed("\(D3DMetalInstaller.InstallError.notAToolkit("/Users/you/Downloads/Xcode_26.dmg"))")],
            ),
            graphics("graphics-toolkit-present", toolkit: .builtInWithToolkit),
            graphics("graphics-browser", route: .browser),
            graphics("graphics-browser-found", route: .browser, items: [.installing]),
        ]

        // MARK: - Finish

        /// The background helper's two refusals, as ``DaemonService`` words
        /// them and the supervisor's status passes them on.
        private static let finishStates: [WizardState] = [
            make("done-sign-in", on: .provisioned, at: .done, steamWindow: .signIn),
            make("done-starting", on: .provisioned, at: .done, steamWindow: .starting),
            make(
                "done-helper-approval", on: .provisioned, at: .done,
                steamWindow: .helperDown("Approve Sevoflurane's background helper in Login Items."),
            ),
            make(
                "done-helper-stuck", on: .provisioned, at: .done,
                steamWindow: .helperDown(
                    "The background helper is registered and won't start. Repair it in Settings, or run: sevo daemon repair.",
                ),
            ),
        ]
    }
#endif
