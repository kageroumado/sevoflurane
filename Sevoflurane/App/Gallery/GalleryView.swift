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
                Text(verbatim: "Sevoflurane UI Gallery")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))

                section("Menu bar popover") {
                    ForEach(Fixtures.popovers, id: \.label) { fixture in
                        tile(fixture.label) {
                            MenuBarView(
                                host: fixture.host,
                                supervisor: fixture.supervisor,
                                notifications: fixture.notifications,
                                quickLaunch: Fixtures.quickLaunch,
                                graphics: Fixtures.graphics,
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
                        .frame(width: 800, height: 560)
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

                section("Settings — HoYoverse", minimum: 520) {
                    tile("Up to date, a patch out, an update running") {
                        HoYoSettings(highlighted: nil, store: Fixtures.hoyo)
                            .frame(width: 520, height: 640)
                    }
                }

                section("Settings — Epic & GOG", minimum: 520) {
                    tile("Signed in, one update out, an install running") {
                        StoresSettings(highlighted: nil, store: Fixtures.stores)
                            .frame(width: 520, height: 720)
                    }
                }

                section("Settings — Recovery", minimum: 500) {
                    ForEach(Fixtures.repairs, id: \.label) { pane in
                        tile(pane.label) {
                            RecoverySettings(
                                provisioner: pane.provisioner,
                                compatibility: Fixtures.compatibility,
                                supervisor: Fixtures.healthySupervisor,
                                highlighted: nil,
                            )
                            .frame(width: 480, height: 820)
                        }
                    }
                }

                // The detail column of the real window: 800 less the sidebar.
                section("Settings — Games, Diagnostics", minimum: 620) {
                    tile("Games, this Mac's own list") {
                        GamesSettings(shaders: Fixtures.shaders, highlighted: nil, selectsFirstGame: true)
                            .frame(width: 610, height: 1100)
                    }
                    tile("Diagnostics") {
                        DiagnosticsSettings(highlighted: nil)
                            .frame(width: 610, height: 1100)
                    }
                }

                section("Reports window", minimum: 800) {
                    tile("This Mac's own runs") {
                        ReportView()
                            .frame(width: 780, height: 520)
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
            .frame(height: SetupMetrics.windowSize.height)
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
        /// Three installations: one current, one a patch behind, one updating.
        static let hoyo: HoYoStore = {
            func row(_ game: HoYoGame, _ path: String, _ version: String, _ kind: SophonDownloader.Plan.Kind, _ size: Int64) -> HoYoStore.Row {
                let installation = HoYoInstallation(game: game, folder: URL(fileURLWithPath: path))
                let latest = if case .patch = kind { game == .starRail ? "4.6.0" : "3.2.0" } else { version }
                return HoYoStore.Row(
                    installation: installation, version: version,
                    plan: SophonDownloader.Plan(
                        game: game, installed: version, latest: latest, kind: kind, voices: ["en-us"], downloadSize: size,
                    ),
                )
            }
            let zzz = "/Users/you/Games/Zenless Zone Zero"
            return HoYoStore(
                fixtureRows: [
                    row(.genshin, "/Users/you/Games/Genshin Impact", "7.1.0", .upToDate, 0),
                    row(.starRail, "/Users/you/Games/Honkai Star Rail", "4.5.0", .patch(from: "4.5.0"), 4_290_000_000),
                    row(.zenless, zzz, "3.1.0", .patch(from: "3.1.0"), 5_100_000_000),
                ],
                jobs: [zzz: HoYoStore.Job(
                    kind: .update,
                    progress: SophonProgress(phase: .patching, bytesDone: 3_200_000_000, bytesTotal: 5_100_000_000, filesDone: 811, filesTotal: 1402),
                )],
            )
        }()

        /// An Epic account with two games installed, one of them a build
        /// behind, and a third downloading.
        static let stores: StoresStore = {
            func title(_ id: String, _ name: String) -> StoreTitle {
                StoreTitle(store: .epic, id: id, title: name, art: nil, version: "2.0")
            }
            let base = "/Users/you/Library/Application Support/Sevoflurane/Bottles/Steam/drive_c/Program Files/Epic Games"
            var account = StoresStore.Account(client: .ready, name: "you")
            account.library = [title("Owl", "Owl Story"), title("Fortress", "A Fortress"), title("Tide", "Tidewater"), title("Lumen", "Lumen")]
            account.installs = [
                StoreInstall(store: .epic, id: "Owl", title: "Owl Story", path: "\(base)/Owl", version: "2.0", size: 6_400_000_000),
                StoreInstall(store: .epic, id: "Fortress", title: "A Fortress", path: "\(base)/Fortress", version: "1.9", size: 21_000_000_000),
            ]
            account.updates = ["Fortress": "2.0"]
            account.loaded = true
            var job = StoresStore.Job(kind: .install, title: "Tidewater")
            job.progress = StoreProgress(phase: .downloading, fraction: 0.42)
            job.downloadSize = 9_800_000_000
            return StoresStore(
                fixture: [.epic: account, .gog: StoresStore.Account(client: .ready)],
                jobs: [.epic: ("Tide", job)],
                sizes: ["epic:Tide": 12_300_000_000, "epic:Lumen": 3_100_000_000],
            )
        }()

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

        /// A library past the recent five, for the popover's index.
        static let library: [SteamWebHost.RecentGame] = games + [
            .init(id: 244_210, name: "Assetto Corsa"),
            .init(id: 1_066_890, name: "Automobilista 2"),
            .init(id: 1_145_360, name: "Hades"),
            .init(id: 367_520, name: "Hollow Knight"),
            .init(id: 1_794_680, name: "Vampire Survivors"),
            .init(id: 620, name: "Portal 2"),
            .init(id: 646_570, name: "Slay the Spire"),
            .init(id: 105_600, name: "Terraria"),
            .init(id: 250_900, name: "The Binding of Isaac: Rebirth", sortAs: "Binding of Isaac: Rebirth"),
            .init(id: 2_379_780, name: "Balatro"),
            .init(id: 1_086_940, name: "Baldur's Gate 3"),
            .init(id: 588_650, name: "Dead Cells"),
            .init(id: 413_150, name: "Stardew Valley"),
            .init(id: 1_593_500, name: "God of War"),
            .init(id: 400, name: "Portal"),
            .init(id: 1_172_470, name: "Apex Legends"),
            .init(id: 377_160, name: "Fallout 4"),
            .init(id: 292_030, name: "The Witcher 3: Wild Hunt", sortAs: "Witcher 3: Wild Hunt"),
            .init(id: 1_174_180, name: "Red Dead Redemption 2"),
            .init(id: 108_600, name: "Project Zomboid"),
            .init(id: 2_358_720, name: "Black Myth: Wukong"),
            .init(id: 1_091_500, name: "Cyberpunk 2077"),
            .init(id: 553_850, name: "HELLDIVERS 2"),
            .init(id: 945_360, name: "Among Us"),
            .init(id: 251_570, name: "7 Days to Die"),
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
                label: "Library past the recent five",
                host: .preview(games: games, library: library),
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
                label: "Mac busy — other apps",
                host: .preview(games: games),
                supervisor: ClientSupervisor(
                    previewHealth: .healthy,
                    hostPressure: HostPressure(otherProcessorShare: 0.85, busiestProcess: "Xcode"),
                ),
            ),
            Popover(
                label: "Mac busy — memory",
                host: .preview(games: games),
                supervisor: ClientSupervisor(previewHealth: .healthy, hostPressure: HostPressure(memory: .critical)),
            ),
            Popover(
                label: "Mac busy — heat",
                host: .preview(games: games),
                supervisor: ClientSupervisor(
                    previewHealth: .healthy,
                    hostPressure: HostPressure(temperature: 97, isThrottling: true),
                ),
            ),
            Popover(
                label: "Mac busy — Low Power Mode",
                host: .preview(games: games),
                supervisor: ClientSupervisor(previewHealth: .healthy, hostPressure: HostPressure(isLowPowerMode: true)),
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
                case .graphics, .options, .sharing, .done: .provisioned
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
        /// The Recovery tiles' supervisor, held like every other fixture.
        static let healthySupervisor = ClientSupervisor(previewHealth: .healthy)
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
