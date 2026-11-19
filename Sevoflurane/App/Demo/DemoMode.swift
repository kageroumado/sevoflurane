#if DEBUG
    import Foundation

    /// The demo switch: puts the first-run assistant and every Settings pane on
    /// simulated environments, so the app can be walked and screenshotted in
    /// any state with nothing on disk behind it.
    ///
    /// On with `SEVO_DEMO=1`, `-SEVO_DEMO 1` as a scheme argument, or `--demo`.
    /// Naming a machine instead of `1` (`SEVO_DEMO=fresh-machine`) picks the
    /// assistant's scenario, and `SEVO_DEMO_GRAPHICS`, `SEVO_DEMO_STORAGE`,
    /// `SEVO_DEMO_ENGINE` and `SEVO_DEMO_COMPATIBILITY` pick the panes'. Every
    /// simulated action is logged to `~/Library/Logs/Sevoflurane.log` under
    /// `setup`.
    enum DemoMode {
        static var isOn: Bool {
            rawValue != nil
        }

        /// The machine the first-run assistant runs against.
        static var setup: SetupScenario {
            rawValue.flatMap(SetupScenario.init(rawValue:)) ?? .freshMachine
        }

        static var graphics: DemoGraphicsEnvironment.Scenario {
            value(of: "SEVO_DEMO_GRAPHICS")
                .flatMap(DemoGraphicsEnvironment.Scenario.init(rawValue:)) ?? .builtInWithToolkit
        }

        static var storage: DemoStorageEnvironment.Scenario {
            value(of: "SEVO_DEMO_STORAGE")
                .flatMap(DemoStorageEnvironment.Scenario.init(rawValue:)) ?? .library
        }

        static var engine: DemoEngineEnvironment.Scenario {
            value(of: "SEVO_DEMO_ENGINE")
                .flatMap(DemoEngineEnvironment.Scenario.init(rawValue:)) ?? .crossOverAndBuiltIn
        }

        static var compatibility: DemoCompatibilityEnvironment.Scenario {
            value(of: "SEVO_DEMO_COMPATIBILITY")
                .flatMap(DemoCompatibilityEnvironment.Scenario.init(rawValue:)) ?? .partlyInstalled
        }

        /// The scenario name the process was launched with, or `"1"` for the
        /// bare switch.
        private static var rawValue: String? {
            for argument in CommandLine.arguments
                where argument == "--demo" || argument.hasPrefix("--demo=") {
                let named = String(argument.dropFirst("--demo=".count))
                return named.isEmpty ? "1" : named
            }
            return value(of: "SEVO_DEMO")
        }

        /// The environment first, then `UserDefaults`, where a `-KEY value`
        /// scheme argument lands.
        private static func value(of key: String) -> String? {
            ProcessInfo.processInfo.environment[key]
                ?? UserDefaults.standard.string(forKey: key)
        }
    }
#endif
