#if DEBUG
    import Foundation

    /// The demo switch: one flag that puts the first-run assistant and every
    /// Settings pane on simulated environments, so the whole app can be walked
    /// — and screenshotted — in any state with no engine, no bottle and no
    /// byte on disk behind it.
    ///
    /// Turn it on with `SEVO_DEMO=1` in the environment, `-SEVO_DEMO 1` as an
    /// Xcode scheme argument, or `--demo` on the command line. Naming a
    /// machine instead of `1` opens the assistant on that one
    /// (`SEVO_DEMO=fresh-machine`), and `SEVO_DEMO_GRAPHICS`,
    /// `SEVO_DEMO_STORAGE`, `SEVO_DEMO_ENGINE` and `SEVO_DEMO_COMPATIBILITY`
    /// choose the Settings panes' states the same way.
    /// Every simulated action is written to `~/Library/Logs/Sevoflurane.log`
    /// under the `setup` category, so the whole session is greppable after.
    ///
    /// The gallery (`-SEVO_GALLERY 1`) draws the same states side by side;
    /// this is the one that lets them be clicked through as the app.
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

        /// The environment first, then `UserDefaults` — which is where a
        /// `-KEY value` scheme argument lands.
        private static func value(of key: String) -> String? {
            ProcessInfo.processInfo.environment[key]
                ?? UserDefaults.standard.string(forKey: key)
        }
    }
#endif
