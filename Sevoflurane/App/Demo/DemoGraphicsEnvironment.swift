#if DEBUG
    import Foundation

    /// A ``GraphicsEnvironment`` with no engine and no bottle behind it. The
    /// pane reads the scenario's fixture and every change lands in memory, so
    /// the gallery and the demo build can show each engine's Graphics pane —
    /// including the install that fails and the DirectX 12 engine download,
    /// which a real machine reaches once and then never again.
    @MainActor
    final class DemoGraphicsEnvironment: GraphicsEnvironment {
        /// The engine-and-toolkit situations the pane has to answer for.
        enum Scenario: String, CaseIterable, Identifiable {
            /// CrossOver: every renderer, and a D3DMetal the engine brings.
            case crossOver = "crossover"
            /// The built-in engine with no toolkit yet — D3DMetal is absent
            /// from the renderer list and the pane asks for Apple's image.
            case builtInNoToolkit = "built-in-no-toolkit"
            /// The built-in engine with two toolkit versions added, and the
            /// DirectX 12 engine already installed.
            case builtInWithToolkit = "built-in-with-toolkit"
            /// A toolkit is present but the DirectX 12 engine that hosts it
            /// is not, so the pane offers to fetch it.
            case dx12EngineMissing = "dx12-engine-missing"
            /// A disk image that turns out not to carry the toolkit.
            case installFails = "install-fails"

            var id: String {
                rawValue
            }

            var title: String {
                switch self {
                case .crossOver: "CrossOver"
                case .builtInNoToolkit: "Built-in engine, no toolkit"
                case .builtInWithToolkit: "Built-in engine, toolkit added"
                case .dx12EngineMissing: "DirectX 12 engine missing"
                case .installFails: "Toolkit install fails"
                }
            }
        }

        let isSimulation = true
        let toolkitStore = URL(fileURLWithPath: "/demo/engine")
        let dx12EngineVersion = "gptk-3.0-3"

        private let scenario: Scenario
        /// Per-action think time, so a progress state is on screen long enough
        /// to be seen. Tests pass `.zero`.
        private let stepDelay: Duration
        private var selection: BottleGraphics.Selection
        private var toolkits: [D3DMetalInstaller.Installed]
        private var active: String?
        private(set) var dx12EngineInstalled: Bool

        init(scenario: Scenario, stepDelay: Duration = .seconds(2)) {
            self.scenario = scenario
            self.stepDelay = stepDelay
            selection = BottleGraphics.Selection(
                renderer: scenario == .crossOver ? .auto : .dxmt,
                msync: true,
                gpu: .automatic,
            )
            let store = URL(fileURLWithPath: "/demo/engine")
            toolkits = switch scenario {
            case .builtInWithToolkit, .dx12EngineMissing:
                [
                    .init(version: "3.0", root: store),
                    .init(version: "4.0 beta 2", root: store),
                ]
            case .crossOver, .builtInNoToolkit, .installFails:
                []
            }
            active = toolkits.last?.version
            dx12EngineInstalled = scenario == .builtInWithToolkit
            log("scenario '\(scenario.rawValue)' — no bottle will be written")
        }

        var engineHasOwnD3DMetal: Bool {
            scenario == .crossOver
        }

        /// A managed engine hosts what it was built for: wine-staging carries
        /// DXMT and DXVK, the GPTk build carries D3DMetal.
        func hostedRenderers() -> [Renderer] {
            var hosted: [Renderer] = [.auto, .dxmt, .dxvk, .wined3d]
            if dx12EngineInstalled { hosted.append(.d3dmetal) }
            return hosted
        }

        func currentSelection() -> BottleGraphics.Selection {
            selection
        }

        func apply(_ selection: BottleGraphics.Selection) throws {
            self.selection = selection
            log("would write renderer=\(selection.renderer.rawValue) "
                + "msync=\(selection.msync) gpu=\(selection.gpu.rawValue) to the bottle")
        }

        func installedToolkits() -> [D3DMetalInstaller.Installed] {
            toolkits
        }

        func activeToolkit() -> D3DMetalInstaller.Installed? {
            toolkits.first { $0.version == active }
        }

        func chooseToolkit(version: String?) throws {
            active = version
            log("would activate D3DMetal \(version ?? "(the engine's own)")")
        }

        func removeToolkit(_ entry: D3DMetalInstaller.Installed) throws {
            toolkits.removeAll { $0.version == entry.version }
            log("would move D3DMetal \(entry.version) to the Trash")
        }

        func installToolkit(from source: URL) async throws -> D3DMetalInstaller.Installed {
            log("would mount \(source.lastPathComponent) and copy its libraries into the engine")
            try await Task.sleep(for: stepDelay)
            guard scenario != .installFails else {
                throw DemoError("that disk image doesn't contain the Game Porting Toolkit")
            }
            let entry = D3DMetalInstaller.Installed(version: "4.0", root: toolkitStore)
            toolkits = (toolkits + [entry]).sorted()
            active = entry.version
            return entry
        }

        func installDX12Engine(
            overlaying toolkit: D3DMetalInstaller.Installed,
            progress: @escaping @Sendable (String, Double?) -> Void,
        ) async throws {
            log("would download the GPTk Wine and overlay D3DMetal \(toolkit.version) onto it")
            for (stage, fraction) in [
                ("downloading", 0.35), ("verifying", 0.7), ("extracting", 0.9),
            ] {
                progress(stage, fraction)
                try await Task.sleep(for: stepDelay)
            }
            guard scenario != .installFails else {
                throw DemoError("the download didn't match its checksum")
            }
            dx12EngineInstalled = true
        }

        private var rendererVersions: [RendererVersions.Component: [RendererVersions.Installed]] = [
            .dxmt: [.init(component: .dxmt, version: "0.81", root: URL(fileURLWithPath: "/demo/renderers/dxmt/0.81"))],
            .dxvk: [],
        ]
        private var chosenRenderer: [RendererVersions.Component: String] = [:]

        func installedRendererVersions(_ component: RendererVersions.Component) -> [RendererVersions.Installed] {
            rendererVersions[component] ?? []
        }

        func chosenRendererVersion(_ component: RendererVersions.Component) -> String? {
            chosenRenderer[component]
        }

        func defaultRendererVersion(_ component: RendererVersions.Component) -> String? {
            component == .dxmt ? "0.80" : "1.10.3-20230507-repack"
        }

        func chooseRendererVersion(_ component: RendererVersions.Component, version: String?) {
            chosenRenderer[component] = version
            log("would run \(component.label) \(version ?? "(the engine's own)") from the next boot")
        }

        func installRendererVersion(
            _ component: RendererVersions.Component, from source: URL, version: String?, sha256: String?,
        ) async throws -> RendererVersions.Installed {
            log("would fetch \(source.lastPathComponent) into the \(component.label) store")
            try await Task.sleep(for: stepDelay)
            let entry = RendererVersions.Installed(
                component: component, version: version ?? component.version(from: source.lastPathComponent),
                root: URL(fileURLWithPath: "/demo/renderers/\(component.rawValue)"),
            )
            rendererVersions[component, default: []].append(entry)
            return entry
        }

        func removeRendererVersion(_ installed: RendererVersions.Installed) throws {
            rendererVersions[installed.component]?.removeAll { $0.version == installed.version }
            log("would move \(installed.component.label) \(installed.version) to the Trash")
        }

        func rendererReleases(_ component: RendererVersions.Component) async -> [RendererVersions.Release] {
            let url = URL(string: "https://example.invalid/\(component.rawValue).tar.gz")!
            return switch component {
            case .dxmt: [
                    .init(component: .dxmt, version: "0.81", url: url, tested: true, sha256: nil),
                    .init(component: .dxmt, version: "0.80", url: url, tested: true, sha256: nil),
                    .init(component: .dxmt, version: "0.74", url: url, tested: false, sha256: nil),
                ]
            case .dxvk: [
                    .init(component: .dxvk, version: "1.10.3-20230507-repack", url: url, tested: true, sha256: nil),
                ]
            }
        }

        private func log(_ message: String) {
            EventLog.shared.log(.setup, "demo: graphics: \(message)")
        }
    }

    /// A failure a simulated environment poses, worded the way the pane will
    /// show it.
    struct DemoError: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
#endif
