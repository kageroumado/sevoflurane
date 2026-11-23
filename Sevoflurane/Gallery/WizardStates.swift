#if DEBUG
    import SwiftUI

    /// One screen of the first-run assistant in one state: the machine it
    /// happens on and the walk that brings a store there.
    ///
    /// A state a run produces is reached by running one: the walk presses the
    /// assistant's own buttons against a simulated machine that stops in, or
    /// fails, the action named, so the screen shows what the provisioner
    /// leaves and follows it when that changes. Only a state a simulated
    /// machine cannot reach (Steam being closed, Apple's page, what Steam's
    /// windows are doing) is staged by hand.
    @MainActor
    final class WizardState: Identifiable {
        /// `<screen number>-<screen>-<state>`; the export writes `setup-<id>.png`.
        let id: String
        let store: SetupStore
        private let walk: (@MainActor (SetupStore) async -> Void)?
        private var hasWalked = false

        init(id: String, store: SetupStore, walk: (@MainActor (SetupStore) async -> Void)? = nil) {
            self.id = id
            self.store = store
            self.walk = walk
        }

        /// Walks the store to its state, once however many views show it.
        func arrange() async {
            guard !hasWalked else { return }
            hasWalked = true
            await walk?(store)
        }

        /// The window's height in this state: the tall one while the screen
        /// hosts Apple's page.
        var height: CGFloat {
            store.wantsTallWindow ? SetupMetrics.tallWindowHeight : SetupMetrics.windowSize.height
        }
    }

    extension WizardState {
        static let all: [WizardState] = questionStates + progressStates + toolkitStates + doneStates

        // MARK: - Machines

        /// The Mac most people set up: Rosetta in place, no CrossOver, nothing
        /// of Sevoflurane's.
        private static let plainMac = SetupDetection(
            rosetta: true, crossover: nil, bottles: [], managedEngineVersions: [],
        )

        private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date? {
            Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
        }

        /// What the three Steams of the several-Steams machine hold.
        private static let libraries: [String: SteamLibraryFacts] = [
            "Steam": SteamLibraryFacts(games: 14, lastPlayed: day(2026, 11, 20), bytes: 86_000_000_000),
            "Steam Beta": SteamLibraryFacts(games: 1, lastPlayed: day(2026, 9, 3), bytes: 9_400_000_000),
            "Games": SteamLibraryFacts(games: 31, lastPlayed: day(2026, 10, 12), bytes: 212_000_000_000),
        ]

        /// A store on a simulated machine. `asks` are the questions the
        /// progress screen still has open: a state about something else
        /// answers them beforehand.
        private static func make(
            _ id: String, on scenario: SetupScenario = .freshMachine, machine detection: SetupDetection? = plainMac,
            asks: Set<SetupCard> = [],
            activity: Provisioner.Activity = .idle, stage: SetupStage? = nil, failure: SetupFailure? = nil,
            steamWindow: SetupSteamWindow = .library,
            environment configure: (DryRunSetupEnvironment) -> Void = { _ in },
            walk: (@MainActor (SetupStore) async -> Void)? = nil,
        ) -> WizardState {
            let environment = DryRunSetupEnvironment(scenario: scenario, stepDelay: .zero, detection: detection)
            // Every view of a state checks the machine again; it must stay the
            // machine the state is about.
            environment.crossOverAppearsOnRecheck = false
            environment.factsByBottle = libraries
            environment.sharesRunStats = asks.contains(.sharing) ? nil : false
            configure(environment)
            let provisioner = Provisioner(
                previewActivity: activity, detection: detection ?? scenario.fixture, environment: environment,
                stage: stage, failure: failure,
            )
            provisioner.installsEveryDependency = true
            let graphics = GraphicsStore(environment: DemoGraphicsEnvironment(
                scenario: asks.contains(.toolkit) ? .builtInNoToolkit : .builtInWithToolkit, stepDelay: .zero,
            ))
            var actions = SetupStore.Actions()
            actions.steamWindow = { steamWindow }
            let store = SetupStore(provisioner: provisioner, graphics: graphics, actions: actions)
            return WizardState(id: id, store: store, walk: walk)
        }

        /// Looks at the machine and presses the welcome's button: the first
        /// question, or the work where there is none.
        private static func begin(_ store: SetupStore) async {
            await store.prepare()
            store.begin()
        }

        // MARK: - The welcome and the questions

        private static let questionStates: [WizardState] = [
            make("1-welcome"),
            make("2-which-steam", on: .multipleBottles, machine: nil, walk: begin),
            make("2-which-steam-new", on: .multipleBottles, machine: nil, walk: { store in
                await begin(store)
                store.steamChoice = nil
            }),
            make("3-engine", on: .licensedNoBottle, machine: nil, walk: begin),
            make("3-engine-crossover", on: .licensedNoBottle, machine: nil, walk: { store in
                await begin(store)
                store.engineChoice = .crossover
            }),
        ]

        // MARK: - The work

        /// A download failing with the Mac offline, as `URLSession` reports it.
        private static let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
            NSURLErrorFailingURLStringErrorKey: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe",
            "_kCFStreamErrorDomainKey": 1,
            "_kCFStreamErrorCodeKey": 50,
        ])

        private static func progress(
            _ id: String, asks: Set<SetupCard> = [], details: Bool = false,
            environment configure: @escaping (DryRunSetupEnvironment) -> Void = { _ in },
        ) -> WizardState {
            make(id, asks: asks, environment: configure, walk: { store in
                store.showsDetails = details
                await begin(store)
            })
        }

        private static let progressStates: [WizardState] = [
            progress("4-progress-early") { $0.hold = .engineDownload(fraction: 0.42) },
            progress("4-progress-details", details: true) { $0.hold = .clientUpdate },
            progress("4-progress-late") { $0.hold = .dependency },
            progress("4-progress-sharing", asks: [.sharing, .toolkit]) { $0.hold = .engineDownload(fraction: 0.42) },
            make("4-progress-rosetta", machine: nil, environment: { $0.hold = .rosetta }, walk: { store in
                store.showsDetails = true
                await begin(store)
            }),
            progress("4-progress-failed-download") {
                $0.engineFailure = SetupFailureText.sentence(offline)
                $0.engineFailureAdvice = SetupFailureText.advice(offline)
            },
            progress("4-progress-failed-steam-download", details: true) { $0.installerDownloadFailure = offline },
            progress("4-progress-failed-installer") { $0.installerFailures = .max },
            progress("4-progress-done-sharing", asks: [.sharing]),
            make("4-progress-adopting", on: .multipleBottles, machine: nil, environment: { $0.hold = .dependency }, walk: { store in
                await begin(store)
                store.answerQuestion()
            }),
            // A simulated machine has no Steam to close, so the two states of
            // the stop before a move to another Steam are staged as the
            // provisioner leaves them.
            make(
                "4-progress-closing-steam", on: .multipleBottles, machine: nil,
                activity: .working(InterfaceCopy.localized("Stopping Steam…")), stage: .steamStop,
                walk: { $0.stage(screen: .progress, showsDetails: true) },
            ),
            make(
                "4-progress-closing-steam-failed", on: .multipleBottles, machine: nil,
                activity: .failed(String(localized: "It did not answer. Try again.")), stage: .steamStop,
                failure: SetupFailure(stage: .steamStop, cause: String(localized: "It did not answer. Try again."), advice: nil),
                walk: { $0.stage(screen: .progress) },
            ),
        ]

        // MARK: - The DirectX 12 offer

        private static func toolkit(
            _ id: String, route: GPTkDownload.Route? = .here, phase: GPTkDownload.AutoPhase = .idle,
            items: [GPTkDownload.Item.Phase] = [], manualCandidate: String? = nil,
        ) -> WizardState {
            let state = make(id, asks: [.toolkit], environment: { $0.hold = .clientUpdate }, walk: { store in
                await begin(store)
                guard let route else { return }
                if route == .here { store.openToolkitPage() } else { store.useBrowserForToolkit() }
            })
            let files = [
                "Evaluation_environment_for_Windows_games_4.0.dmg",
                "Evaluation_environment_for_Windows_games_4.0_beta_2.dmg",
            ]
            state.store.toolkit.stage(
                route: route ?? .here, autoPhase: phase,
                items: zip(files, items).enumerated().map { index, pair in
                    GPTkDownload.Item(id: index, filename: pair.0, fraction: index == 0 ? 0.64 : 0.21, phase: pair.1)
                },
                pickedVersions: phase == .downloading ? ["4.0", "4.0 beta 2"] : [],
                manualCandidate: manualCandidate,
            )
            return state
        }

        private static let toolkitStates: [WizardState] = [
            toolkit("4-progress-toolkit", route: nil),
            toolkit("4-progress-toolkit-sign-in"),
            toolkit("4-progress-toolkit-downloading", phase: .downloading, items: [.downloading, .downloading]),
            toolkit(
                "4-progress-toolkit-failed", phase: .downloading,
                items: [.installed(version: "4.0"), .failed("The network connection was lost.")],
            ),
            toolkit(
                "4-progress-toolkit-manual", phase: .manual,
                manualCandidate: "Evaluation environment for Windows games 4.0 beta 2",
            ),
            toolkit("4-progress-toolkit-browser", route: .browser, items: [.installing]),
        ]

        // MARK: - The last screen

        /// A finished run with nothing left to ask, which lands on the last
        /// screen; what Steam's windows are doing there is staged.
        private static func done(
            _ id: String, _ steamWindow: SetupSteamWindow, repair: DaemonService.RepairResult? = nil,
        ) -> WizardState {
            make(id, steamWindow: steamWindow, walk: { store in
                await begin(store)
                // The pass ends a few turns after its button; the screen follows it.
                for _ in 0 ..< 400 where store.screen != .done {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                if let repair { store.stage(screen: .done, helperRepair: repair) }
            })
        }

        private static let doneStates: [WizardState] = [
            done("5-done-sign-in", .signIn),
            done("5-done-library", .library),
            done("5-done-starting", .starting),
            done("5-done-helper-down", .helperDown),
            done(
                "5-done-helper-needs-approval", .helperDown,
                repair: .needsApproval("Approve Sevoflurane's background helper in Login Items."),
            ),
            done("5-done-steam-gave-up", .gaveUp("the client keeps crashing on start")),
        ]

        // MARK: - The popover that leads back

        /// The menu-bar popover while an assistant is open or set aside, by
        /// what its work is doing; the export writes `setup-popover-<name>.png`.
        static let popovers: [(name: String, state: WizardState?)] = [
            ("unfinished", nil),
            ("working", progress("popover-working") { $0.hold = .engineDownload(fraction: 0.42) }),
            ("failed", progress("popover-failed") { $0.installerDownloadFailure = offline }),
            ("installed", progress("popover-installed", asks: [.sharing])),
        ]
    }
#endif
