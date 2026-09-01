#if DEBUG
    import Foundation

    /// An ``EngineEnvironment`` with no engines and no bottles behind it. The
    /// pane lists the scenario's fixtures, and a switch moves an in-memory
    /// pair rather than the one every path in the app addresses — the whole
    /// point, since a real switch stops Steam and may build a bottle.
    @MainActor
    final class DemoEngineEnvironment: EngineEnvironment {
        /// The engine-and-bottle situations the pane has to answer for.
        enum Scenario: String, CaseIterable, Identifiable {
            /// Licensed CrossOver plus a built-in engine, several bottles —
            /// the machine where every control is live.
            case crossOverAndBuiltIn = "crossover-and-built-in"
            /// Only the built-in engine, one bottle. Switching means either
            /// staying put or naming a new bottle.
            case builtInOnly = "built-in-only"
            /// No engine installed yet: the built-in option downloads on
            /// switch, which is the longest thing this pane can start.
            case noEngineYet = "no-engine-yet"
            /// A bottle nobody has put Steam in, next to one that has it.
            case bottleWithoutSteam = "bottle-without-steam"

            var id: String {
                rawValue
            }

            var title: String {
                switch self {
                case .crossOverAndBuiltIn: "CrossOver and built-in"
                case .builtInOnly: "Built-in engine only"
                case .noEngineYet: "No engine installed yet"
                case .bottleWithoutSteam: "A bottle without Steam"
                }
            }

            /// The machine the engine list is built from. It has to agree with
            /// what this environment reports as active and installed —
            /// ``EngineStore`` builds its options from detection and its
            /// bottles from the environment, so a fixture that disagreed with
            /// itself would show an engine named twice, once as a label and
            /// once as a raw description.
            var detection: SetupDetection {
                switch self {
                case .crossOverAndBuiltIn:
                    SetupDetection(
                        rosetta: true,
                        crossover: SetupScenario.licensedCrossOver,
                        bottles: [],
                        managedEngineVersions: [DemoEngineEnvironment.builtInVersion],
                    )
                case .builtInOnly, .bottleWithoutSteam:
                    SetupDetection(
                        rosetta: true, crossover: nil, bottles: [],
                        managedEngineVersions: [DemoEngineEnvironment.builtInVersion],
                    )
                case .noEngineYet:
                    SetupDetection(
                        rosetta: true, crossover: nil, bottles: [],
                        managedEngineVersions: [],
                    )
                }
            }
        }

        /// The managed engine every scenario that has one reports.
        static let builtInVersion = "wine-staging-10.14"

        let isSimulation = true

        private(set) var activeEngine: Engine
        private(set) var activeBottle: String
        private let scenario: Scenario
        private var byEngine: [String: [SetupDetection.Bottle]]

        init(scenario: Scenario) {
            self.scenario = scenario
            let crossover = Engine.crossover
            let builtIn = Engine.managed(version: Self.builtInVersion)
            switch scenario {
            case .crossOverAndBuiltIn:
                activeEngine = crossover
                activeBottle = "Steam"
                byEngine = [
                    crossover.description: [
                        Self.bottle("Steam", hasSteam: true),
                        Self.bottle("Steam Beta", hasSteam: true),
                        Self.bottle("Office", hasSteam: false),
                    ],
                    builtIn.description: [Self.bottle("Steam", hasSteam: true)],
                ]
            case .builtInOnly:
                activeEngine = builtIn
                activeBottle = "Steam"
                byEngine = [builtIn.description: [Self.bottle("Steam", hasSteam: true)]]
            case .noEngineYet:
                activeEngine = Engine.managed(version: "")
                activeBottle = SteamBottle.defaultName
                byEngine = [:]
            case .bottleWithoutSteam:
                activeEngine = builtIn
                activeBottle = "Steam"
                byEngine = [builtIn.description: [
                    Self.bottle("Steam", hasSteam: true),
                    Self.bottle("Fresh", hasSteam: false),
                ]]
            }
            log("scenario '\(scenario.rawValue)' — no engine or bottle will be switched")
        }

        private static func bottle(
            _ name: String, hasSteam: Bool,
        ) -> SetupDetection.Bottle {
            SetupDetection.Bottle(
                name: name,
                url: URL(fileURLWithPath: "/demo/Bottles").appendingPathComponent(name),
                hasSteam: hasSteam,
            )
        }

        func bottles(for engine: Engine) -> [SetupDetection.Bottle] {
            byEngine[engine.description] ?? []
        }

        func choose(engine: Engine, bottle: String) {
            activeEngine = engine
            activeBottle = bottle
            // A switch into a bottle that wasn't there leaves it there, so a
            // second switch back reads the machine the first one made.
            var existing = byEngine[engine.description] ?? []
            if !existing.contains(where: { $0.name == bottle }) {
                existing.append(Self.bottle(bottle, hasSteam: false))
                byEngine[engine.description] = existing
            }
            log("would persist engine=\(engine.description) bottle=\(bottle)")
        }

        func stopClient(supervisor _: ClientSupervisor?) async {
            log("would stand supervision down and stop Steam")
            try? await Task.sleep(for: .seconds(1))
        }

        func startClient(supervisor _: ClientSupervisor?) {
            log("would start Steam again in the new bottle")
        }

        private func log(_ message: String) {
            EventLog.shared.log(.setup, "demo: engine: \(message)")
        }
    }
#endif
