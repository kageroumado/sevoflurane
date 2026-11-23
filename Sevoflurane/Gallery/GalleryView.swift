#if DEBUG
    import Propofol
    import SwiftUI
    import UserNotifications

    /// Every surface in every state, side by side, with no client and no bottle
    /// behind it.
    ///
    /// Opened with `-SEVO_GALLERY 1` (or `SEVO_GALLERY=1`), or from Debug ▸ UI
    /// Gallery. Tiles run on the simulated environments ``DemoMode`` uses;
    /// `SEVO_DEMO=1` walks one of these states as the app.
    struct GalleryView: View {
        var body: some View {
            ScrollView {
                tiles(withWizardStates: true)
            }
            .frame(minWidth: 1200, minHeight: 900)
        }

        /// Every tile at full height, outside any scroll view: what the window
        /// scrolls and ``GalleryExport`` writes. The export leaves out the
        /// first-run assistant's further states, which it writes one to a file.
        func tiles(withWizardStates: Bool) -> some View {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text(verbatim: "Sevoflurane UI Gallery")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                PopoverTiles()
                RunDiagnosisTiles()
                SettingsTiles()
                EngineTiles()
                ToolTiles()
                WizardTiles()
                if withWizardStates {
                    WizardStateTiles()
                }
            }
            .padding(Theme.Space.xl)
        }
    }

    /// One Settings pane whole, for ``GalleryExport`` to write to its own file.
    struct GalleryPane: Identifiable {
        let id: String
        /// A pane that fills what it is given instead of scrolling; the others
        /// are written at their content's height.
        var fixedHeight: CGFloat?
        /// A whole pane, which `Tools/settings-guides.py` measures; a popover or
        /// a pane cut by its window is written as `view-<name>.png` instead.
        var isWholePane = true
        let view: AnyView

        init(
            _ id: String, fixedHeight: CGFloat? = nil, isWholePane: Bool = true,
            @ViewBuilder view: () -> some View,
        ) {
            self.id = id
            self.fixedHeight = fixedHeight
            self.isWholePane = isWholePane
            self.view = AnyView(view())
        }
    }

    extension GalleryView {
        /// The detail column of the real window: 800 less the sidebar.
        static let detailWidth: CGFloat = 610

        /// Every Settings pane as the running app draws it: with Steam's actions
        /// and a supervisor, so the rows that need them are there.
        static var settingsPanes: [GalleryPane] {
            let steam = SteamActions(
                openSteamSettings: {}, uninstall: { _ in }, restartClient: {}, cancelStuckMenus: { [] },
                applyCompatibilityStrip: {}, applyUserStyles: {}, applyStreamerMode: {},
            )
            let builtIn = Fixtures.enginePanes.first { $0.scenario == .builtInOnly }
            let crossOver = Fixtures.enginePanes.first { $0.scenario == .crossOverAndBuiltIn }
            let noToolkit = Fixtures.graphicsPanes.first { $0.scenario == .builtInNoToolkit }
            let linkable = Fixtures.storagePanes.first { $0.scenario == .linkableGames }
            let linked = Fixtures.storagePanes.first { $0.scenario == .alreadyLinked }
            let crossOverGraphics = Fixtures.graphicsPanes.first { $0.scenario == .crossOver }
            let failedInstalls = Fixtures.compatibilityPanes.first { $0.scenario == .installFails }
            return [
                GalleryPane("general") {
                    GeneralSettings(
                        provisioner: Fixtures.settings, store: Fixtures.storage, steam: steam,
                        highlighted: nil, supervisor: Fixtures.healthySupervisor,
                    )
                },
                GalleryPane("graphics") {
                    GraphicsSettings(
                        store: Fixtures.graphics, shaders: Fixtures.shaders, defaults: Fixtures.bottleDefaults,
                        steam: steam, highlighted: nil,
                    )
                },
                GalleryPane("graphics-restart") {
                    GraphicsSettings(
                        store: Fixtures.graphicsAwaitingRestart, shaders: Fixtures.shaders, steam: steam,
                        highlighted: nil,
                    )
                },
                GalleryPane("graphics-no-toolkit") {
                    if let noToolkit {
                        GraphicsSettings(store: noToolkit.store, shaders: Fixtures.shaders, highlighted: nil)
                    }
                },
                GalleryPane("engine") {
                    if let builtIn {
                        EngineSettings(
                            store: builtIn.store, graphics: Fixtures.graphics, shaders: Fixtures.shaders,
                            compatibility: Fixtures.compatibility, provisioner: builtIn.provisioner,
                            highlighted: nil,
                        )
                    }
                },
                GalleryPane("engine-crossover") {
                    if let crossOver {
                        EngineSettings(
                            store: crossOver.store, graphics: Fixtures.graphics, shaders: Fixtures.shaders,
                            compatibility: Fixtures.compatibility, provisioner: crossOver.provisioner,
                            highlighted: nil,
                        )
                    }
                },
                GalleryPane("games") {
                    GamesSettings(
                        shaders: Fixtures.shaders, highlighted: nil, selectsFirstGame: true,
                        fixtureGames: Fixtures.games.map { .init(id: $0.id, name: $0.name, exes: []) },
                    )
                },
                GalleryPane("hoyoverse") { HoYoSettings(highlighted: nil, store: Fixtures.hoyo) },
                GalleryPane("storage") {
                    StorageSettings(store: Fixtures.storage, steam: steam, highlighted: nil)
                },
                GalleryPane("storage-linkable") {
                    if let linkable {
                        StorageSettings(store: linkable.store, steam: steam, highlighted: nil)
                    }
                },
                GalleryPane("storage-linked") {
                    if let linked {
                        StorageSettings(store: linked.store, steam: steam, highlighted: nil)
                    }
                },
                GalleryPane("graphics-crossover") {
                    if let crossOverGraphics {
                        GraphicsSettings(
                            store: crossOverGraphics.store, shaders: Fixtures.shaders, steam: steam,
                            highlighted: nil,
                        )
                    }
                },
                GalleryPane("engine-failed-installs") {
                    if let builtIn, let failedInstalls {
                        EngineSettings(
                            store: builtIn.store, graphics: Fixtures.graphics, shaders: Fixtures.shaders,
                            compatibility: failedInstalls.store, provisioner: builtIn.provisioner,
                            highlighted: nil,
                        )
                    }
                },
                GalleryPane("recovery-failed") {
                    if let failed = Fixtures.repairs.last {
                        RecoverySettings(
                            provisioner: failed.provisioner, compatibility: Fixtures.compatibility,
                            supervisor: Fixtures.healthySupervisor, steam: steam, highlighted: nil,
                        )
                    }
                },
                GalleryPane("recovery") {
                    RecoverySettings(
                        provisioner: Fixtures.settings, compatibility: Fixtures.compatibility,
                        supervisor: Fixtures.healthySupervisor, steam: steam, highlighted: nil,
                    )
                },
                GalleryPane("diagnostics") {
                    DiagnosticsSettings(store: Fixtures.diagnostics, highlighted: nil, showReports: {})
                },
                GalleryPane("about", fixedHeight: 518) { AboutSettings(highlighted: nil) },
                GalleryPane("kit") { SettingsKitGallery() },
                GalleryPane("general-automation") {
                    GeneralSettings(
                        provisioner: Fixtures.settings, store: Fixtures.storage, steam: steam,
                        highlighted: nil, supervisor: Fixtures.healthySupervisor,
                        automationFixture: AgentIntegration.Harness.allCases,
                    )
                },
                GalleryPane("engine-switching") {
                    EngineSettings(
                        store: Fixtures.switchingEngine.store, graphics: Fixtures.graphics,
                        shaders: Fixtures.shaders, compatibility: Fixtures.compatibility,
                        provisioner: Fixtures.switchingEngine.provisioner, highlighted: nil,
                    )
                },
                GalleryPane("engine-switch-failed") {
                    EngineSettings(
                        store: Fixtures.failedEngine.store, graphics: Fixtures.graphics,
                        shaders: Fixtures.shaders, compatibility: Fixtures.compatibility,
                        provisioner: Fixtures.failedEngine.provisioner, highlighted: nil,
                    )
                },
                GalleryPane("games-fixes") {
                    GamesSettings(
                        shaders: Fixtures.shaders, highlighted: nil, selectsFirstGame: true,
                        fixtureGames: Fixtures.games.map { .init(id: $0.id, name: $0.name, exes: ["game.exe"]) },
                        fixtureForm: Fixtures.fixedGame, showsProgramSections: true,
                    )
                },
                GalleryPane("hoyoverse-installing") {
                    HoYoSettings(highlighted: nil, store: Fixtures.hoyoInstalling)
                },
                // A window shorter than the pane, opened on a row far down it and
                // then sent to another: the form scrolls to each.
                GalleryPane("jump-on-appear", fixedHeight: 420, isWholePane: false) {
                    RecoverySettings(
                        provisioner: Fixtures.settings, compatibility: Fixtures.compatibility,
                        supervisor: Fixtures.healthySupervisor, steam: steam, highlighted: .recoveryWinecfg,
                    )
                },
                GalleryPane("jump-later", fixedHeight: 420, isWholePane: false) {
                    JumpHarness(steam: steam)
                },
                GalleryPane("help-renderers", fixedHeight: 520, isWholePane: false) {
                    SettingsHelpPopover(help: SettingCopy.renderers(Renderer.allCases))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                },
                GalleryPane("help-usage", fixedHeight: 520, isWholePane: false) {
                    SettingsHelpPopover(help: .usageCount)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                },
                GalleryPane("help-archive", fixedHeight: 520, isWholePane: false) {
                    SettingsHelpPopover(help: .diagnosticsArchive)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                },
                GalleryPane("help-windows", fixedHeight: 620, isWholePane: false) {
                    SettingsHelpPopover(help: SettingCopy.windows.help ?? .usageCount)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                },
            ]
        }
    }

    /// The menu-bar popover in each client state.
    /// The Recovery pane, sent to a row past its window's end a moment after
    /// it appears, as a jump from one of its own rows does.
    private struct JumpHarness: View {
        let steam: SteamActions
        @State private var highlighted: SettingsAnchor?

        var body: some View {
            RecoverySettings(
                provisioner: Fixtures.settings, compatibility: Fixtures.compatibility,
                supervisor: Fixtures.healthySupervisor, steam: steam, highlighted: highlighted,
            )
            .task {
                try? await Task.sleep(for: .seconds(1))
                highlighted = .recoveryClearShaderCache
            }
        }
    }

    private struct PopoverTiles: View {
        var body: some View {
            GallerySection("Menu bar popover") {
                ForEach(Fixtures.popovers, id: \.label) { fixture in
                    GalleryTile(fixture.label) {
                        fixture.view
                            .background(.background, in: Theme.cardShape)
                    }
                }
            }
        }
    }

    /// The panel about a run, once per cause and once with several findings.
    private struct RunDiagnosisTiles: View {
        var body: some View {
            GallerySection("What happened to a run", minimum: RunDiagnosisView.width) {
                ForEach(RunDiagnosisFixtures.panels) { panel in
                    GalleryTile(panel.id) {
                        RunDiagnosisView(model: panel.model)
                            .background(.background, in: Theme.cardShape)
                    }
                }
            }
        }
    }

    /// The settings window whole, then its General, Graphics and Storage panes.
    private struct SettingsTiles: View {
        var body: some View {
            GallerySection("Settings — the whole window", minimum: 740) {
                GalleryTile("Window") {
                    SettingsView(
                        provisioner: Fixtures.settings,
                        graphics: Fixtures.graphics,
                        storage: Fixtures.storage,
                        engine: Fixtures.engine,
                        shaders: Fixtures.shaders,
                        compatibility: Fixtures.compatibility,
                        diagnostics: Fixtures.diagnostics,
                    )
                    .frame(width: 800, height: 560)
                }
            }
            GallerySection("Settings — General") {
                GalleryTile("Open at login, the CLI, uninstall") {
                    GeneralSettings(provisioner: Fixtures.settings, store: Fixtures.storage, highlighted: nil)
                        .frame(width: 460, height: 620)
                }
            }
            GallerySection("Settings — Graphics", minimum: 480) {
                ForEach(Fixtures.graphicsPanes, id: \.scenario) { pane in
                    GalleryTile(pane.scenario.title) {
                        // Tall enough for the toolkit section below the fold.
                        GraphicsSettings(store: pane.store, shaders: Fixtures.shaders, highlighted: nil)
                            .frame(width: 460, height: 620)
                    }
                }
            }
            GallerySection("Settings — Storage", minimum: 480) {
                ForEach(Fixtures.storagePanes, id: \.scenario) { pane in
                    GalleryTile(pane.scenario.title) {
                        StorageSettings(store: pane.store, highlighted: nil)
                            .frame(width: 460, height: 620)
                    }
                }
            }
        }
    }

    /// The Engine pane on each engine, then on each dependency state.
    private struct EngineTiles: View {
        var body: some View {
            // Each engine tile draws the whole pane: the switch at the top
            // decides which bottle the sections below apply to.
            GallerySection("Settings — Engine", minimum: 500) {
                ForEach(Fixtures.enginePanes, id: \.scenario) { pane in
                    GalleryTile(pane.scenario.title) {
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
            GallerySection("Settings — Engine, dependencies", minimum: 500) {
                ForEach(Fixtures.compatibilityPanes, id: \.scenario) { pane in
                    GalleryTile(pane.scenario.title) {
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
        }
    }

    /// The panes for one job each: HoYoverse, Recovery, Games, Diagnostics,
    /// the report window and About.
    private struct ToolTiles: View {
        var body: some View {
            GallerySection("Settings — HoYoverse", minimum: 520) {
                GalleryTile("Up to date, a patch out, an update running") {
                    HoYoSettings(highlighted: nil, store: Fixtures.hoyo)
                        .frame(width: 520, height: 640)
                }
            }
            GallerySection("Settings — Recovery", minimum: 500) {
                ForEach(Fixtures.repairs, id: \.label) { pane in
                    GalleryTile(pane.label) {
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
            GallerySection("Settings — Games, Diagnostics", minimum: 620) {
                GalleryTile("Games, this Mac's own list") {
                    GamesSettings(shaders: Fixtures.shaders, highlighted: nil, selectsFirstGame: true)
                        .frame(width: 610, height: 1100)
                }
                GalleryTile("Diagnostics") {
                    DiagnosticsSettings(store: Fixtures.diagnostics, highlighted: nil)
                        .frame(width: 610, height: 1100)
                }
            }
            GallerySection("Reports window", minimum: 800) {
                GalleryTile("This Mac's own runs") {
                    ReportView()
                        .frame(width: 780, height: 520)
                }
            }
            GallerySection("Settings — About") {
                GalleryTile("About") {
                    AboutSettings(highlighted: nil)
                        .frame(width: 420, height: 230)
                }
            }
        }
    }

    /// The first-run assistant on every step, then on every machine. Shown at
    /// the wizard's fixed window size, so a tile can be clicked through.
    private struct WizardTiles: View {
        var body: some View {
            GallerySection("First-run assistant — every step", minimum: 700) {
                ForEach(Fixtures.wizardSteps, id: \.step) { entry in
                    GalleryTile(entry.step.title) { wizard(entry.store) }
                }
            }
            GallerySection("First-run assistant — every machine", minimum: 700) {
                ForEach(Fixtures.wizards, id: \.scenario) { entry in
                    GalleryTile(entry.scenario.title) { wizard(entry.store) }
                }
            }
        }

        private func wizard(_ store: SetupStore) -> some View {
            SetupView(store: store, onFinished: {})
                .frame(height: SetupMetrics.windowSize.height)
                .background(.background, in: Theme.cardShape)
                .clipShape(Theme.cardShape)
        }
    }

    /// The first-run assistant in every state past a step's first look
    /// (``WizardState``), each walked to its state as its tile appears.
    private struct WizardStateTiles: View {
        var body: some View {
            GallerySection("First-run assistant — every other state", minimum: 700) {
                ForEach(WizardState.all) { state in
                    GalleryTile(state.id) {
                        state.view
                            .frame(height: state.height)
                            .background(.background, in: Theme.cardShape)
                            .clipShape(Theme.cardShape)
                            .task { await state.arrange() }
                    }
                }
            }
        }
    }

    /// A titled grid of tiles.
    private struct GallerySection<Content: View>: View {
        let title: String
        let minimum: CGFloat
        @ViewBuilder let content: () -> Content

        init(_ title: String, minimum: CGFloat = 360, @ViewBuilder content: @escaping () -> Content) {
            self.title = title
            self.minimum = minimum
            self.content = content
        }

        var body: some View {
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
    }

    /// One surface in one state, under its label.
    private struct GalleryTile<Content: View>: View {
        let label: String
        @ViewBuilder let content: () -> Content

        init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
            self.label = label
            self.content = content
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                content()
            }
        }
    }

    /// The states the gallery draws.
    enum Fixtures {
        /// The popover's questions as this Mac's answers leave them.
        static let questions = ConsentQuestions.current()
        static let diagnostics = DiagnosticsStore()

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

        struct Popover {
            let label: String
            let host: SteamWebHost
            let supervisor: ClientSupervisor
            /// Nothing else in the app draws the notification permission card.
            var notifications: SteamNotifications = .preview()
            /// The first-run assistant, for the popover that leads back to it.
            var setup: SetupWindow?

            /// The popover at its own width.
            var view: some View {
                MenuBarView(
                    host: host,
                    supervisor: supervisor,
                    notifications: notifications,
                    quickLaunch: Fixtures.quickLaunch,
                    graphics: Fixtures.graphics,
                    questions: Fixtures.questions,
                    setup: setup,
                )
                .frame(width: Theme.popoverWidth + Theme.Space.md * 2)
            }
        }

        /// The popover while the first-run assistant is open or set aside.
        static let setupUnfinished: Popover = {
            let setup = SetupWindow()
            setup.stageUnfinished()
            return Popover(
                label: "Setup unfinished", host: .preview(),
                supervisor: ClientSupervisor(previewHealth: .starting), setup: setup,
            )
        }()

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
        /// observable object on every evaluation, and the gallery would rebuild
        /// itself forever.
        static let popovers: [Popover] = [
            setupUnfinished,
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

        /// One wizard per fixture machine, each on its own provisioner so tiles
        /// advance independently.
        static let wizards: [(scenario: SetupScenario, store: SetupStore)] =
            SetupScenario.allCases.map { scenario in
                // Paced: with no think time every stage completes between two
                // frames and every scenario looks already provisioned.
                (scenario, wizardStore(Provisioner(environment: DryRunSetupEnvironment(
                    scenario: scenario, stepDelay: .milliseconds(900),
                )), startingAt: .welcome))
            }

        private static func wizardStore(_ provisioner: Provisioner, startingAt step: SetupStep) -> SetupStore {
            SetupStore(provisioner: provisioner, startingAt: step, makeGraphics: { Fixtures.wizardGraphics })
        }

        /// Every step of the assistant at once, each on a machine that reaches
        /// it: the bottle question needs more than one Steam, and the install
        /// step needs one still to do.
        static let wizardSteps: [(step: SetupStep, store: SetupStore)] =
            SetupStep.allCases.map { step in
                let scenario: SetupScenario = switch step {
                case .welcome, .engine: .freshMachine
                case .bottle: .multipleBottles
                case .steam: .licensedNoBottle
                case .graphics, .options, .sharing, .done: .provisioned
                }
                return (step, wizardStore(Provisioner(
                    previewActivity: step == .steam ? .working("Downloading Steam…") : .idle,
                    detection: scenario.fixture,
                    environment: DryRunSetupEnvironment(
                        scenario: scenario, stepDelay: .milliseconds(900),
                    ),
                ), startingAt: step))
            }

        static let settings = provisioner(.idle)
        static let healthySupervisor = ClientSupervisor(previewHealth: .healthy)
        /// In memory: drawing the settings window must not rewrite the
        /// machine's bottle.
        static let graphics = GraphicsStore(
            environment: DemoGraphicsEnvironment(scenario: .builtInWithToolkit),
        )
        static let storage = StorageStore(
            environment: DemoStorageEnvironment(scenario: .library),
        )
        /// The bottle's defaults, in memory like every gallery store.
        static let bottleDefaults = SettingsStore(scope: .bottle(SteamBottle.name))
        /// A client that booted on another renderer, with a version changed since.
        static let graphicsAwaitingRestart: GraphicsStore = {
            let store = GraphicsStore(environment: DemoGraphicsEnvironment(scenario: .builtInWithToolkit))
            let other = store.availableRenderers.first { $0 != store.selection.renderer } ?? .wined3d
            store.stageBoot(on: other, versionsChanged: true)
            return store
        }()
        /// A switch under way, and one that failed and left Steam unable to start.
        static let switchingEngine = stagedEngine {
            $0.stage(switching: "Downloading Dormison r14…", fraction: 0.42)
        }
        static let failedEngine = stagedEngine {
            $0.stage(
                switching: nil, failure: "The engine’s signature does not match its release.", blocksClient: true,
            )
        }

        private static func stagedEngine(_ stage: (EngineStore) -> Void) -> EnginePane {
            let scenario = DemoEngineEnvironment.Scenario.builtInOnly
            let provisioner = Provisioner(
                previewActivity: .idle,
                detection: scenario.detection,
                environment: DryRunSetupEnvironment(scenario: .provisioned, stepDelay: .zero, detection: scenario.detection),
            )
            let store = EngineStore(
                provisioner: provisioner, supervisor: nil, environment: DemoEngineEnvironment(scenario: scenario),
            )
            stage(store)
            return EnginePane(scenario: scenario, provisioner: provisioner, store: store)
        }

        /// A game the fix list set two values on, with a DLL override and a
        /// variable of its own.
        static let fixedGame: SettingsStore = {
            let scope = SettingScope.game(games[0].id, bottle: SteamBottle.name)
            var fixed = ConfigValues.empty
            fixed.processors = 4
            fixed.videoDecoding = .software
            var values = fixed
            values.dllOverrides = ["dinput8": "n,b", "version": "b"]
            values.environment = ["DXVK_HUD": "fps", "WINEDLLOVERRIDES": "winmm=n,b"]
            return SettingsStore(
                scope: scope,
                environment: InMemorySettingsEnvironment(seed: [.bottle(SteamBottle.name): .empty, scope: values]),
                fixtureFixes: AppliedFixes(
                    fixes: [
                        .init(title: "Unity 5 worker threads", reason: "Unity 5 starts a busy worker for every processor."),
                        .init(title: "Intro video", reason: "Its intro video stays blank on the hardware decoder."),
                    ],
                    applied: fixed, previous: .empty, date: .now,
                ),
            )
        }()

        /// One installation, and an install of another game under way.
        static let hoyoInstalling: HoYoStore = {
            let folder = URL(fileURLWithPath: "/Users/you/Games/Zenless Zone Zero")
            return HoYoStore(
                fixtureRows: hoyo.rows.filter { $0.installation.game == .genshin },
                jobs: [folder.standardizedFileURL.path: HoYoStore.Job(
                    kind: .install,
                    progress: SophonProgress(
                        phase: .downloading, bytesDone: 31_400_000_000, bytesTotal: 98_700_000_000,
                        filesDone: 2811, filesTotal: 9402,
                    ),
                )],
                installing: (.zenless, folder),
            )
        }()
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
        /// The wizard's graphics step gets its own store, so a toolkit added in
        /// a wizard tile stays out of the Graphics pane tiles.
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

        /// One engine pane per fixture machine, each on its own provisioner.
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
