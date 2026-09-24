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

    /// The DXMT and DXVK versions beside the engine's own (``RendererVersions``).
    func installedRendererVersions(_ component: RendererVersions.Component) -> [RendererVersions.Installed]
    func chosenRendererVersion(_ component: RendererVersions.Component) -> String?
    func defaultRendererVersion(_ component: RendererVersions.Component) -> String?
    /// `nil` chooses the engine's own.
    func chooseRendererVersion(_ component: RendererVersions.Component, version: String?)
    func installRendererVersion(
        _ component: RendererVersions.Component, from source: URL, version: String?, sha256: String?,
    ) async throws -> RendererVersions.Installed
    func removeRendererVersion(_ installed: RendererVersions.Installed) throws
    func rendererReleases(_ component: RendererVersions.Component) async -> [RendererVersions.Release]
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
        toolkitStore = D3DMetalInstaller.store
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

    func installedRendererVersions(_ component: RendererVersions.Component) -> [RendererVersions.Installed] {
        RendererVersions.installed(component)
    }

    func chosenRendererVersion(_ component: RendererVersions.Component) -> String? {
        RendererVersions.chosen(component)
    }

    func defaultRendererVersion(_ component: RendererVersions.Component) -> String? {
        RendererVersions.defaultVersion(component, engine: Engine.active.root)
    }

    func chooseRendererVersion(_ component: RendererVersions.Component, version: String?) {
        RendererVersions.choose(component, version: version)
    }

    func installRendererVersion(
        _ component: RendererVersions.Component, from source: URL, version: String?, sha256: String?,
    ) async throws -> RendererVersions.Installed {
        // Detached: the unpack and the copies are disk work, and this is the
        // main actor.
        try await Task.detached(name: "Install \(component.label) \(version ?? "")") {
            try await RendererVersions.install(component, from: source, version: version, sha256: sha256)
        }.value
    }

    func removeRendererVersion(_ installed: RendererVersions.Installed) throws {
        try RendererVersions.remove(installed)
    }

    func rendererReleases(_ component: RendererVersions.Component) async -> [RendererVersions.Release] {
        let manifest = try? await EngineManifest.fetch()
        return await RendererVersions.releases(component, manifest: manifest)
    }
}
