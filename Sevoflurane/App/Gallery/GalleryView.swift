#if DEBUG
    import Propofol
    import SwiftUI

    /// Every surface in every state, side by side, with no client and no
    /// bottle behind any of it — the visual pass this app could otherwise
    /// only do by provisioning a machine into each state in turn.
    ///
    /// Opened with `-SEVO_GALLERY 1` (or `SEVO_GALLERY=1`), or from
    /// Debug ▸ UI Gallery. The wizard tiles run the same fixtures as the
    /// onboarding dry run, so what shows here is what a real machine in that
    /// state would show.
    struct GalleryView: View {
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    Text("Sevoflurane — UI Gallery")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))

                    section("Menu bar popover") {
                        ForEach(Fixtures.popovers, id: \.label) { fixture in
                            tile(fixture.label) {
                                MenuBarView(host: fixture.host, supervisor: fixture.supervisor)
                                    .frame(width: Theme.popoverWidth + Theme.Space.md * 2)
                                    .background(.background, in: Theme.cardShape)
                            }
                        }
                    }

                    section("Settings") {
                        tile("Window") {
                            SettingsView(provisioner: Fixtures.settings)
                                .frame(width: 720, height: 460)
                        }
                    }

                    section("Repair") {
                        ForEach(Fixtures.repairs, id: \.label) { pane in
                            tile(pane.label) {
                                RepairSettings(provisioner: pane.provisioner, highlighted: nil)
                                    .frame(width: 420, height: 190)
                            }
                        }
                    }

                    // The wizard is a fixed 680x500 window and is shown at
                    // that size: a scaled-down tile is a picture of the UI
                    // rather than the UI, and this gallery exists to be
                    // clicked through.
                    section("First-run assistant", minimum: 700) {
                        ForEach(Fixtures.wizards, id: \.scenario) { wizard in
                            tile(wizard.scenario.title) {
                                SetupView(provisioner: wizard.provisioner, onFinished: {})
                                    .frame(width: 680, height: 500)
                                    .background(.background, in: Theme.cardShape)
                                    .clipShape(Theme.cardShape)
                            }
                        }
                    }
                }
                .padding(Theme.Space.xl)
            }
            .frame(minWidth: 1200, minHeight: 900)
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
        }

        struct Pane {
            let label: String
            let provisioner: Provisioner
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
        /// tile that advances leaves its neighbours where they were.
        static let wizards: [(scenario: SetupScenario, provisioner: Provisioner)] =
            SetupScenario.allCases.map { scenario in
                (scenario, Provisioner(environment: DryRunSetupEnvironment(
                    scenario: scenario, stepDelay: .zero,
                )))
            }

        static let settings = provisioner(.idle)

        private static func provisioner(_ activity: Provisioner.Activity) -> Provisioner {
            Provisioner(previewActivity: activity, detection: SetupScenario.provisioned.fixture)
        }
    }
#endif
