#if DEBUG
    import Propofol
    import SwiftUI
    import UserNotifications

    /// Every surface in every state, side by side, with no client and no
    /// bottle behind any of it — the visual pass this app could otherwise
    /// only do by provisioning a machine into each state in turn.
    ///
    /// Opened with `-SEVO_GALLERY 1` (or `SEVO_GALLERY=1`), or from
    /// Debug ▸ UI Gallery. Every tile runs the same simulated environments
    /// ``DemoMode`` boots the app on, so what shows here is what a real
    /// machine in that state would show — and `SEVO_DEMO=1` is how to walk
    /// one of these states as the app rather than look at it.
    struct GalleryView: View {
        var body: some View {
            ScrollView {
                tiles
            }
            .frame(minWidth: 1200, minHeight: 900)
        }

        /// Every tile at its full height, outside any scroll view: what the
        /// window scrolls and what ``GalleryExport`` writes to disk.
        var tiles: some View {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    Text("Sevoflurane UI Gallery")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))

                    section("Menu bar popover") {
                        ForEach(Fixtures.popovers, id: \.label) { fixture in
                            tile(fixture.label) {
                                MenuBarView(
                                    host: fixture.host,
                                    supervisor: fixture.supervisor,
                                    notifications: fixture.notifications,
                                    quickLaunch: Fixtures.quickLaunch,
                                )
                                .frame(width: Theme.popoverWidth + Theme.Space.md * 2)
                                .background(.background, in: Theme.cardShape)
                            }
                        }
                    }

                    section("Settings — the whole window", minimum: 740) {
                        tile("Window") {
                            SettingsView(
                                provisioner: Fixtures.settings,
                                graphics: Fixtures.graphics,
                                storage: Fixtures.storage,
                                engine: Fixtures.engine,
                                shaders: Fixtures.shaders,
                                compatibility: Fixtures.compatibility,
                            )
                            .frame(width: 720, height: 460)
                        }
                    }

                    section("Settings — General") {
                        tile("Open at login, the CLI, uninstall") {
                            GeneralSettings(
                                provisioner: Fixtures.settings,
                                store: Fixtures.storage,
                                highlighted: nil,
                            )
                            .frame(width: 460, height: 620)
                        }
                    }

                    section("Settings — Graphics", minimum: 480) {
                        ForEach(Fixtures.graphicsPanes, id: \.scenario) { pane in
                            tile(pane.scenario.title) {
                                // Tall enough for the toolkit section below
                                // the fold: a tile that clips the state it
                                // exists to show is worse than no tile.
                                GraphicsSettings(store: pane.store, shaders: Fixtures.shaders, highlighted: nil)
                                    .frame(width: 460, height: 620)
                            }
                        }
                    }

                    section("Settings — Storage", minimum: 480) {
                        ForEach(Fixtures.storagePanes, id: \.scenario) { pane in
                            tile(pane.scenario.title) {
                                StorageSettings(store: pane.store, highlighted: nil)
                                    .frame(width: 460, height: 620)
                            }
                        }
                    }

                    // Each engine tile draws the whole pane, because the
                    // sections answer one question together — the switch at
                    // the top is what makes the ones below it apply to a
                    // different bottle.
                    section("Settings — Engine", minimum: 500) {
                        ForEach(Fixtures.enginePanes, id: \.scenario) { pane in
                            tile(pane.scenario.title) {
                                EngineSettings(
                                    store: pane.store,
                                    graphics: Fixtures.graphics,
                                    shaders: Fixtures.shaders,
                                    compatibility: Fixtures.compatibility,
                                    provisioner: pane.provisioner,
                                    highlighted: nil,
                                )
                                .frame(width: 480, height: 820)
                            }
                        }
                    }

                    section("Settings — Engine, dependencies", minimum: 500) {
                        ForEach(Fixtures.compatibilityPanes, id: \.scenario) { pane in
                            tile(pane.scenario.title) {
                                EngineSettings(
                                    store: Fixtures.engine,
                                    graphics: Fixtures.graphics,
                                    shaders: Fixtures.shaders,
                                    compatibility: pane.store,
                                    provisioner: Fixtures.settings,
                                    highlighted: nil,
                                )
                                .frame(width: 480, height: 820)
                            }
                        }
                    }

                    section("Settings — Recovery", minimum: 500) {
                        ForEach(Fixtures.repairs, id: \.label) { pane in
                            tile(pane.label) {
                                RecoverySettings(
                                    provisioner: pane.provisioner,
                                    supervisor: ClientSupervisor(previewHealth: .healthy),
                                    highlighted: nil,
                                )
                                .frame(width: 480, height: 820)
                            }
                        }
                    }

                    section("Settings — About") {
                        tile("About") {
                            AboutSettings(highlighted: nil)
                                .frame(width: 420, height: 230)
                        }
                    }

                    // The wizard is a fixed-size window and is shown at that
                    // size: a scaled-down tile is a picture of the UI
                    // rather than the UI, and this gallery exists to be
                    // clicked through.
                    section("First-run assistant — every step", minimum: 700) {
                        ForEach(Fixtures.wizardSteps, id: \.step) { entry in
                            tile(entry.step.title) {
                                wizard(entry.provisioner, startingAt: entry.step)
                            }
                        }
                    }

                    section("First-run assistant — every machine", minimum: 700) {
                        ForEach(Fixtures.wizards, id: \.scenario) { entry in
                            tile(entry.scenario.title) {
                                wizard(entry.provisioner, startingAt: .welcome)
                            }
                        }
                    }
                }
                .padding(Theme.Space.xl)
        }

        private func wizard(
            _ provisioner: Provisioner, startingAt step: SetupView.Step,
        ) -> some View {
            SetupView(
                provisioner: provisioner,
                startingAt: step,
                makeGraphics: { Fixtures.wizardGraphics },
                onFinished: {},
            )
            .background(.background, in: Theme.cardShape)
            .clipShape(Theme.cardShape)
        }

        private func section(
            _ title: String, minimum: CGFloat = 360, @ViewBuilder _ content: () -> some View,
        ) -> some View {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text(title)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: minimum), spacing: Theme.Space.lg)],
                    alignment: .leading,
                    spacing: Theme.Space.lg,
                ) {
                    content()
                }
            }
        }

        private func tile(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                content()
            }
        }
    }

    /// The states the gallery draws. One place to add a case the design has
    /// to answer for.
    enum Fixtures {
        struct Popover {
            let label: String
            let host: SteamWebHost
            let supervisor: ClientSupervisor
            /// Notifications are a popover state too — nothing else in the
            /// app draws the permission card.
            var notifications: SteamNotifications = .preview()
        }

        struct Pane {
            let label: String
            let provisioner: Provisioner
        }

        struct GraphicsPane {
            let scenario: DemoGraphicsEnvironment.Scenario
            let store: GraphicsStore
        }

        struct EnginePane {
            let scenario: DemoEngineEnvironment.Scenario
            /// Its own, so a tile that starts a switch narrates only itself.
            let provisioner: Provisioner
            let store: EngineStore
        }

        struct CompatibilityPane {
            let scenario: DemoCompatibilityEnvironment.Scenario
            let store: CompatibilityStore
        }

        struct StoragePane {
            let scenario: DemoStorageEnvironment.Scenario
            let store: StorageStore
        }

        static let games: [SteamWebHost.RecentGame] = [
            .init(id: 1_245_620, name: "ELDEN RING"),
            .init(id: 2_050_650, name: "Resident Evil 4"),
            .init(id: 1_868_140, name: "DAVE THE DIVER"),
            .init(id: 892_970, name: "Valheim"),
            .init(id: 427_520, name: "Factorio"),
        ]

        /// Built once and held: a fixture created inside a `body` is a new
        /// object on every evaluation, and an observable one at that — the
        /// gallery would rebuild itself forever.
        static let popovers: [Popover] = [
            Popover(
                label: "Healthy",
                host: .preview(games: games),
                supervisor: ClientSupervisor(previewHealth: .healthy),
            ),
            Popover(
                label: "Empty library",
                host: .preview(),
                supervisor: ClientSupervisor(previewHealth: .healthy),
            ),
            Popover(
                label: "Starting",
                host: .preview(games: games, status: "Starting Steam…"),
                supervisor: ClientSupervisor(previewHealth: .starting),
            ),
            Popover(
                label: "Waiting for sign-in",
                host: .preview(),
                supervisor: ClientSupervisor(previewHealth: .waitingForSignIn),
            ),
            Popover(
                label: "Restarting",
                host: .preview(games: games),
                supervisor: ClientSupervisor(
                    previewHealth: .restarting("waiting for the client (12s)"),
                ),
            ),
            Popover(
                label: "Degraded",
                host: .preview(games: games),
                supervisor: ClientSupervisor(
                    previewHealth: .degraded("CDP unreachable — client down"),
                ),
            ),
            Popover(
                label: "Gave up",
                host: .preview(games: games),
                supervisor: ClientSupervisor(
                    previewHealth: .gaveUp("the client keeps crashing on start"),
                ),
            ),
            Popover(
                label: "Launching a game",
                host: .preview(
                    games: games,
                    launching: .init(appID: 1_245_620, detail: "Preparing…"),
                ),
                supervisor: ClientSupervisor(previewHealth: .healthy),
            ),
            Popover(
                label: "One message waiting",
                host: .preview(games: games, unreadChats: 1),
                supervisor: ClientSupervisor(previewHealth: .healthy),
            ),
            Popover(
                label: "Several conversations waiting",
                host: .preview(games: games, unreadChats: 4),
                supervisor: ClientSupervisor(previewHealth: .healthy),
            ),
            Popover(
                label: "Notifications not asked for yet",
                host: .preview(games: games, unreadChats: 1),
                supervisor: ClientSupervisor(previewHealth: .healthy),
                notifications: .preview(authorization: .notDetermined, unasked: true),
            ),
            Popover(
                label: "Notifications refused",
                host: .preview(games: games, unreadChats: 2),
                supervisor: ClientSupervisor(previewHealth: .healthy),
                notifications: .preview(authorization: .denied),
            ),
        ]

        static let repairs: [Pane] = [
            Pane(label: "Idle", provisioner: provisioner(.idle)),
            Pane(label: "Working", provisioner: provisioner(.working("Installing Steam…"))),
            Pane(label: "Done", provisioner: provisioner(.done)),
            Pane(
                label: "Failed",
                provisioner: provisioner(.failed("the installer exited with status 1")),
            ),
        ]

        /// One wizard per fixture machine, each on its own provisioner so a
        /// tile that advances leaves its neighbors where they were.
        static let wizards: [(scenario: SetupScenario, provisioner: Provisioner)] =
            SetupScenario.allCases.map { scenario in
                // Paced, not instant: with no think time every stage
                // completes between two frames and every scenario looks like
                // a machine that was already provisioned.
                (scenario, Provisioner(environment: DryRunSetupEnvironment(
                    scenario: scenario, stepDelay: .milliseconds(900),
                )))
            }

        /// Every step of the assistant at once, on the machine that reaches
        /// each of them: the bottle question only exists where more than one
        /// Steam was found, and the install step only reads as an install on
        /// a machine that still has one to do.
        static let wizardSteps: [(step: SetupView.Step, provisioner: Provisioner)] =
            SetupView.Step.allCases.map { step in
                let scenario: SetupScenario = switch step {
                case .welcome, .engine: .freshMachine
                case .bottle: .multipleBottles
                case .steam: .licensedNoBottle
                case .graphics, .options, .done: .provisioned
                }
                return (step, Provisioner(
                    previewActivity: step == .steam ? .working("Downloading Steam…") : .idle,
                    detection: scenario.fixture,
                    environment: DryRunSetupEnvironment(
                        scenario: scenario, stepDelay: .milliseconds(900),
                    ),
                ))
            }

        static let settings = provisioner(.idle)
        /// Fixed values in memory: the gallery draws the settings window, and
        /// drawing it must not rewrite the machine's bottle.
        static let graphics = GraphicsStore(
            environment: DemoGraphicsEnvironment(scenario: .builtInWithToolkit),
        )
        static let storage = StorageStore(
            environment: DemoStorageEnvironment(scenario: .library),
        )
        static let shaders = ShaderStore(simulated: true)
        /// Two adopted programs, so the Quick Launch group draws with rows.
        static let quickLaunch = QuickLaunchStore(simulated: [
            adopted(id: AdoptedPrograms.firstID, name: "Fate/stay night", exe: "fsn.exe"),
            adopted(id: AdoptedPrograms.firstID + 1, name: "RPG Maker MV", exe: "rpgmv.exe"),
        ])

        private static func adopted(id: Int, name: String, exe: String) -> AdoptedPrograms.Entry {
            AdoptedPrograms.Entry(
                id: id, name: name,
                program: AdoptedProgram(
                    path: "/Users/demo/Games/\(name)/\(exe)", bottle: SteamBottle.name,
                    kind: ProgramKind.game, addedAt: .now,
                ),
            )
        }
        /// The wizard's own graphics step reads a store too — a separate one,
        /// so a toolkit added in a wizard tile doesn't appear in the Graphics
        /// pane tiles beside it.
        static let wizardGraphics = GraphicsStore(
            environment: DemoGraphicsEnvironment(scenario: .builtInNoToolkit),
        )
        static let engine = EngineStore(
            provisioner: settings, supervisor: nil,
            environment: DemoEngineEnvironment(scenario: .crossOverAndBuiltIn),
        )
        static let compatibility = CompatibilityStore(
            environment: DemoCompatibilityEnvironment(scenario: .partlyInstalled),
        )

        static let graphicsPanes: [GraphicsPane] =
            DemoGraphicsEnvironment.Scenario.allCases.map { scenario in
                GraphicsPane(
                    scenario: scenario,
                    store: GraphicsStore(
                        environment: DemoGraphicsEnvironment(
                            scenario: scenario, stepDelay: .milliseconds(900),
                        ),
                    ),
                )
            }

        static let storagePanes: [StoragePane] =
            DemoStorageEnvironment.Scenario.allCases.map { scenario in
                StoragePane(
                    scenario: scenario,
                    store: StorageStore(
                        environment: DemoStorageEnvironment(scenario: scenario),
                    ),
                )
            }

        /// One engine pane per fixture machine, each on its own provisioner
        /// so a tile that starts a switch leaves its neighbors alone.
        static let enginePanes: [EnginePane] =
            DemoEngineEnvironment.Scenario.allCases.map { scenario in
                let provisioner = Provisioner(
                    previewActivity: .idle,
                    detection: scenario.detection,
                    environment: DryRunSetupEnvironment(
                        scenario: .provisioned,
                        stepDelay: .milliseconds(900),
                        detection: scenario.detection,
                    ),
                )
                return EnginePane(
                    scenario: scenario,
                    provisioner: provisioner,
                    store: EngineStore(
                        provisioner: provisioner, supervisor: nil,
                        environment: DemoEngineEnvironment(scenario: scenario),
                    ),
                )
            }

        static let compatibilityPanes: [CompatibilityPane] =
            DemoCompatibilityEnvironment.Scenario.allCases.map { scenario in
                CompatibilityPane(
                    scenario: scenario,
                    store: CompatibilityStore(
                        environment: DemoCompatibilityEnvironment(scenario: scenario),
                    ),
                )
            }

        private static func provisioner(_ activity: Provisioner.Activity) -> Provisioner {
            Provisioner(
                previewActivity: activity,
                detection: SetupScenario.provisioned.fixture,
                environment: DryRunSetupEnvironment(scenario: .provisioned, stepDelay: .zero),
            )
        }
    }
#endif
