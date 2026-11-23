#if DEBUG
    import SwiftUI

    /// One screen of the first-run assistant in one state: the machine it
    /// happens on and the walk that brings a store there.
    ///
    /// A state a run produces is reached by running one: the walk presses the
    /// assistant's own buttons against a simulated machine that stops in, or
    /// fails, the action named, so the screen shows what the provisioner
    /// leaves and follows it when that changes. Only a state a simulated
    /// machine cannot reach (Apple's page, what Steam's windows are doing) is
    /// staged by hand.
    @MainActor
    final class WizardState: Identifiable {
        /// `<screen number>-<screen>-<state>`; the export writes `setup-<id>.png`.
        let id: String
        let store: SetupStore
        /// How tall the window is in this state, once a view has measured it.
        let layout = SetupLayout()
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
    }

    extension WizardState {
        static let all: [WizardState] = questionStates + progressStates + toolkitStates + doneStates

        // MARK: - Machines

        /// The Mac most people set up: Rosetta in place, no CrossOver, nothing
        /// of Sevoflurane's.
        private static let plainMac = SetupDetection(
            rosetta: true, crossover: nil, bottles: [], managedEngineVersions: [],
        )

        /// The room between the menu bar and the Dock on a 13-inch MacBook
        /// at its default scaling, less the window's margin.
        private static let smallDisplayLimit: CGFloat = 800

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
        /// answers them beforehand. `stop` is how closing a running Steam
        /// goes on a machine that has one.
        private static func make(
            _ id: String, on scenario: SetupScenario = .freshMachine, machine detection: SetupDetection? = plainMac,
            asks: Set<SetupCard> = [], steamWindow: SetupSteamWindow = .library,
            stop: (@MainActor (_ narrate: (String) -> Void) async -> String?)? = nil,
            environment configure: (DryRunSetupEnvironment) -> Void = { _ in },
            walk: (@MainActor (SetupStore) async -> Void)? = nil,
        ) -> WizardState {
            let environment = DryRunSetupEnvironment(scenario: scenario, stepDelay: .zero, detection: detection)
            // Every view of a state checks the machine again; it must stay the
            // machine the state is about.
            environment.crossOverAppearsOnRecheck = false
            environment.factsByBottle = libraries
            environment.sharesRunStats = asks.contains(.sharing) ? nil : false
            environment.simulatesRunningSteam = stop != nil
            configure(environment)
            let provisioner = Provisioner(
                previewActivity: .idle, detection: detection ?? scenario.fixture, environment: environment,
            )
            provisioner.installsEveryDependency = true
            let graphics = GraphicsStore(environment: DemoGraphicsEnvironment(
                scenario: asks.contains(.toolkit) ? .builtInNoToolkit : .builtInWithToolkit, stepDelay: .zero,
            ))
            var actions = SetupStore.Actions()
            actions.steamWindow = { steamWindow }
            if let stop {
                actions.steamIsRunning = { true }
                actions.stopClient = stop
            }
            let store = SetupStore(provisioner: provisioner, graphics: graphics, actions: actions)
            return WizardState(id: id, store: store, walk: walk)
        }

        /// Looks at the machine and presses the welcome's button: the first
        /// question, or the work where there is none.
        private static func begin(_ store: SetupStore) async {
            await store.prepare()
            store.begin()
        }

        /// Waits for `condition`, which a run reaches a few main-actor turns
        /// after the button that starts it.
        private static func wait(for condition: () -> Bool) async {
            for _ in 0 ..< 400 where !condition() {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        /// On the machine with several Steams, picks the one this
        /// installation does not drive yet, which a running Steam has to be
        /// closed for.
        private static func pickAnotherSteam(_ store: SetupStore) async {
            await begin(store)
            store.steamChoice = store.candidates.first { $0.bottle.name == "Games" }?.id
            store.answerQuestion()
        }

        /// A year: longer than any gallery stays open.
        private static let forever = Duration.seconds(365 * 86400)

        // How closing a running Steam goes on a simulated machine.

        private static func closesAtOnce(_: (String) -> Void) async -> String? {
            nil
        }

        private static func neverCloses(_: (String) -> Void) async -> String? {
            try? await Task.sleep(for: forever)
            return nil
        }

        private static func refusesToClose(_: (String) -> Void) async -> String? {
            String(localized: "Try again. If it keeps happening, restart your Mac.")
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
            make("3-close-steam", on: .multipleBottles, machine: nil, stop: closesAtOnce, walk: pickAnotherSteam),
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
            progress("4-progress-sharing", asks: [.sharing]) { $0.hold = .engineDownload(fraction: 0.42) },
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
            make("4-progress-failed-twice", environment: { $0.installerFailures = .max }, walk: { store in
                await begin(store)
                await wait { store.hasFailed }
                // The retry is taken once the failed pass has ended, a turn
                // after its failure shows.
                await wait {
                    if !store.offersDiagnostics { store.tryAgain() }
                    return store.offersDiagnostics
                }
            }),
            progress("4-progress-done-sharing", asks: [.sharing]),
            make("4-progress-adopting", on: .multipleBottles, machine: nil, environment: { $0.hold = .dependency }, walk: { store in
                await begin(store)
                store.answerQuestion()
            }),
            make(
                "4-progress-closing-steam", on: .multipleBottles, machine: nil,
                stop: neverCloses,
                walk: { store in
                    store.showsDetails = true
                    await pickAnotherSteam(store)
                    store.answerQuestion()
                },
            ),
            make(
                "4-progress-closing-steam-failed", on: .multipleBottles, machine: nil,
                stop: refusesToClose,
                walk: { store in
                    await pickAnotherSteam(store)
                    store.answerQuestion()
                },
            ),
        ]

        // MARK: - The DirectX 12 offer

        private static let toolkitFiles = [
            "Evaluation_environment_for_Windows_games_4.0.dmg",
            "Evaluation_environment_for_Windows_games_4.0_beta_2.dmg",
        ]

        /// The offer with Steam's own download held. `route` opens Apple's
        /// page or the browser's way; `items` are downloads already begun,
        /// which fold the offer into its status row.
        private static func toolkit(
            _ id: String, asks: Set<SetupCard> = [.toolkit], route: GPTkDownload.Route? = nil,
            phase: GPTkDownload.AutoPhase = .idle, items: [GPTkDownload.Item.Phase] = [],
            manualCandidate: String? = nil, heightLimit: CGFloat? = nil,
        ) -> WizardState {
            let state = make(id, asks: asks, environment: { $0.hold = .clientUpdate }, walk: { store in
                await begin(store)
                guard let route else { return }
                if route == .here { store.openToolkitPage() } else { store.useBrowserForToolkit() }
            })
            if let heightLimit { state.layout.heightLimit = heightLimit }
            state.store.toolkit.stage(
                route: route ?? .here, autoPhase: phase,
                items: zip(toolkitFiles, items).enumerated().map { index, pair in
                    GPTkDownload.Item(id: index, filename: pair.0, fraction: index == 0 ? 0.64 : 0.21, phase: pair.1)
                },
                pickedVersions: items.isEmpty ? [] : ["4.0", "4.0 beta 2"],
                manualCandidate: manualCandidate,
            )
            return state
        }

        private static let toolkitStates: [WizardState] = [
            toolkit("4-progress-toolkit"),
            toolkit("4-progress-toolkit-sign-in", route: .here),
            toolkit("4-progress-toolkit-sign-in-13-inch", route: .here, heightLimit: smallDisplayLimit),
            toolkit(
                "4-progress-toolkit-manual", route: .here, phase: .manual,
                manualCandidate: "Evaluation environment for Windows games 4.0 beta 2",
            ),
            toolkit("4-progress-toolkit-browser", route: .browser),
            toolkit("4-progress-toolkit-running", asks: [.toolkit, .sharing], items: [.downloading, .downloading]),
            toolkit(
                "4-progress-toolkit-failed",
                items: [.installed(version: "4.0"), .failed("The network connection was lost.")],
            ),
        ]

        // MARK: - The last screen

        /// A finished run with nothing left to ask, which lands on the last
        /// screen; what Steam's windows are doing there is staged.
        private static func done(
            _ id: String, _ steamWindow: SetupSteamWindow, repair: DaemonService.RepairResult? = nil,
        ) -> WizardState {
            make(id, steamWindow: steamWindow, walk: { store in
                await begin(store)
                await wait { store.screen == .done }
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
            done("5-done-steam-gave-up", .gaveUp),
        ]

        // MARK: - The popover that leads back

        /// The menu-bar popover while an assistant is open or set aside, by
        /// what its work is doing; the export writes `setup-popover-<name>.png`.
        static let popovers: [(name: String, state: WizardState?)] = [
            ("unfinished", nil),
            ("working", progress("popover-working") { $0.hold = .engineDownload(fraction: 0.42) }),
            ("failed", progress("popover-failed") { $0.installerDownloadFailure = offline }),
            ("installed", progress("popover-installed", asks: [.sharing])),
            ("ready", done("popover-ready", .signIn)),
        ]
    }
#endif
