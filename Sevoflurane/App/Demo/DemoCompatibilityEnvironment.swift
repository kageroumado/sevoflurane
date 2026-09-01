#if DEBUG
    import Foundation

    /// A ``CompatibilityEnvironment`` with no bottle behind it: the Engine
    /// pane's dependency rows and DLL overrides read fixtures, an install
    /// narrates its stages and lands in memory, and one scenario fails so the
    /// error row can be seen without breaking a real prefix.
    @MainActor
    final class DemoCompatibilityEnvironment: CompatibilityEnvironment {
        /// The dependency situations the pane has to answer for.
        enum Scenario: String, CaseIterable, Identifiable {
            /// A fresh bottle: nothing installed, no overrides.
            case fresh
            /// The common middle — some pieces in, a couple of overrides set.
            case partlyInstalled = "partly-installed"
            /// Everything present, so every row reads as installed.
            case complete
            /// An install that fails, and an override that is refused.
            case installFails = "install-fails"

            var id: String {
                rawValue
            }

            var title: String {
                switch self {
                case .fresh: "Fresh bottle"
                case .partlyInstalled: "Some pieces installed"
                case .complete: "Everything installed"
                case .installFails: "Install fails"
                }
            }
        }

        let isSimulation = true

        private let scenario: Scenario
        private var installed: Set<String>
        private var overrideList: [BottleDependencies.Override]

        init(scenario: Scenario) {
            self.scenario = scenario
            let all = Set(BottleDependencies.catalog.map(\.id))
            switch scenario {
            case .fresh, .installFails:
                installed = []
                overrideList = []
            case .partlyInstalled:
                installed = Set(BottleDependencies.catalog.prefix(2).map(\.id))
                overrideList = [
                    .init(dll: "d3dcompiler_47", mode: "native"),
                    .init(dll: "winemenubuilder.exe", mode: "disabled"),
                ]
            case .complete:
                installed = all
                overrideList = [.init(dll: "quartz", mode: "native, builtin")]
            }
            log("scenario '\(scenario.rawValue)' — no bottle will be written")
        }

        func isInstalled(_ dependency: BottleDependencies.Dependency) -> Bool {
            installed.contains(dependency.id)
        }

        func install(
            _ id: String, phase: @escaping @Sendable (String) -> Void,
        ) async -> String? {
            log("would install \(id) into the bottle")
            for stage in ["downloading", "extracting", "running the installer"] {
                phase(stage)
                try? await Task.sleep(for: .milliseconds(700))
            }
            guard scenario != .installFails else {
                return "the installer exited with status 1"
            }
            installed.insert(id)
            return nil
        }

        func overrides() -> [BottleDependencies.Override] {
            overrideList
        }

        func setOverride(dll: String, mode: String) async -> String? {
            try? await Task.sleep(for: .milliseconds(400))
            guard scenario != .installFails else {
                return "couldn't write to the bottle's registry"
            }
            log("would set \(dll) to \(mode)")
            overrideList.removeAll { $0.dll == dll }
            overrideList.append(.init(dll: dll, mode: mode))
            overrideList.sort { $0.dll < $1.dll }
            return nil
        }

        func removeOverride(dll: String) async -> String? {
            try? await Task.sleep(for: .milliseconds(400))
            log("would remove the \(dll) override")
            overrideList.removeAll { $0.dll == dll }
            return nil
        }

        func openWineConfiguration() {
            log("would launch winecfg in the bottle")
        }

        private func log(_ message: String) {
            EventLog.shared.log(.setup, "demo: compatibility: \(message)")
        }
    }
#endif
