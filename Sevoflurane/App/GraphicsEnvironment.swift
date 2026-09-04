import Foundation

/// The engine-and-disk half of the Graphics pane, split from ``GraphicsStore``
/// the way ``SetupEnvironment`` is split from ``Provisioner``: the store keeps
/// the policy, this keeps the effects. A simulated environment can then pose
/// any engine, any set of installed toolkits, and an install that fails —
/// with no bottle behind any of it.
@MainActor
protocol GraphicsEnvironment: AnyObject {
    /// Whether the effects are simulated.
    var isSimulation: Bool { get }

    /// Where installed copies of Apple's toolkit are kept for this engine:
    /// inside a managed engine, or the shared store CrossOver is pointed at
    /// through the shadow tree.
    var toolkitStore: URL { get }

    /// Whether the engine brings a D3DMetal of its own, which the user's copy
    /// then replaces rather than supplies.
    var engineHasOwnD3DMetal: Bool { get }

    /// What the installed engines between them can host, as each declares in
    /// its `engine-info.json`; a renderer nothing hosts cannot be offered.
    func hostedRenderers() -> [Renderer]

    func currentSelection() -> BottleGraphics.Selection
    func apply(_ selection: BottleGraphics.Selection) throws

    func installedToolkits() -> [D3DMetalInstaller.Installed]
    func activeToolkit() -> D3DMetalInstaller.Installed?
    /// `nil` chooses the engine's own copy.
    func chooseToolkit(version: String?) throws
    func removeToolkit(_ entry: D3DMetalInstaller.Installed) throws
    func installToolkit(from source: URL) async throws -> D3DMetalInstaller.Installed

    /// The Wine build the DirectX 12 renderer is locked to.
    var dx12EngineVersion: String { get }
    var dx12EngineInstalled: Bool { get }
    func installDX12Engine(
        overlaying toolkit: D3DMetalInstaller.Installed,
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async throws
}

extension GraphicsEnvironment {
    var isSimulation: Bool {
        false
    }
}

/// The real one: the bottle's own graphics configuration, and the engines and
/// toolkits on disk.
@MainActor
final class LiveGraphicsEnvironment: GraphicsEnvironment {
    let toolkitStore: URL
    let engineHasOwnD3DMetal: Bool

    init() {
        toolkitStore = if case let .managed(version) = Engine.active {
            Engine.managedRoot.appendingPathComponent(version)
        } else {
            D3DMetalInstaller.sharedRoot
        }
        engineHasOwnD3DMetal = Engine.active.isCrossOver
    }

    func hostedRenderers() -> [Renderer] {
        SetupProbe.managedEngineVersions()
            .flatMap { Engine.managed(version: $0).supportedRenderers }
    }

    func currentSelection() -> BottleGraphics.Selection {
        BottleGraphics.currentSelection()
    }

    func apply(_ selection: BottleGraphics.Selection) throws {
        try BottleGraphics.applyToActiveEngine(selection)
    }

    func installedToolkits() -> [D3DMetalInstaller.Installed] {
        D3DMetalInstaller.installed(inEngine: toolkitStore)
    }

    func activeToolkit() -> D3DMetalInstaller.Installed? {
        D3DMetalInstaller.active(inEngine: toolkitStore)
    }

    func chooseToolkit(version: String?) throws {
        guard let version,
              let entry = installedToolkits().first(where: { $0.version == version })
        else {
            D3DMetalInstaller.choose(version: nil)
            CrossOverShadow.remove()
            return
        }
        // Record only: the tree is staged from this choice at the next spawn
        // (``EngineRenderers/stage``), both halves together. Placing the macOS
        // half here while the Windows half waits for a restart is what crossed
        // 4.0's dylib with 3.0's DLLs.
        D3DMetalInstaller.choose(version: entry.version)
    }

    func removeToolkit(_ entry: D3DMetalInstaller.Installed) throws {
        try FileManager.default.trashItem(at: entry.root, resultingItemURL: nil)
    }

    func installToolkit(from source: URL) async throws -> D3DMetalInstaller.Installed {
        try await D3DMetalInstaller.install(from: source, intoEngine: toolkitStore)
    }

    var dx12EngineVersion: String {
        GPTkEngineInstaller.version
    }

    var dx12EngineInstalled: Bool {
        GPTkEngineInstaller.isInstalled
    }

    func installDX12Engine(
        overlaying toolkit: D3DMetalInstaller.Installed,
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async throws {
        try await GPTkEngineInstaller.install(overlaying: toolkit, progress: progress)
    }
}
