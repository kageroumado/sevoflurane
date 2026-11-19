import Foundation

/// The engine-and-disk half of the Graphics pane: ``GraphicsStore`` keeps the
/// policy, this keeps the effects, so a simulated environment can pose any
/// engine, toolkits and failures with no bottle behind them.
@MainActor
protocol GraphicsEnvironment: AnyObject {
    /// Whether the effects are simulated.
    var isSimulation: Bool { get }

    /// Whether the engine brings its own D3DMetal, which a user's copy
    /// replaces.
    var engineHasOwnD3DMetal: Bool { get }

    /// The engine's name, for the popover.
    var engineName: String { get }

    /// What the installed engines can host, per their `engine-info.json`;
    /// nothing else can be offered.
    func hostedRenderers() -> [Renderer]

    func currentSelection() -> BottleGraphics.Selection
    func apply(_ selection: BottleGraphics.Selection) throws

    func installedToolkits() -> [D3DMetalInstaller.Installed]
    func activeToolkit() -> D3DMetalInstaller.Installed?
    /// `nil` chooses the engine's own copy.
    func chooseToolkit(version: String?) throws
    func removeToolkit(_ entry: D3DMetalInstaller.Installed) throws
    func installToolkit(from source: URL, origin: D3DMetalInstaller.Origin) async throws -> D3DMetalInstaller.Installed

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

    /// The renderer the running client booted on; `nil` before a first boot.
    func bootedRenderer() -> Renderer?
    /// Whether a DXMT or DXVK pick differs from the one the client booted with.
    func rendererVersionsChangedSinceBoot() -> Bool
    /// Calls `onChange` each time a client boot records its selection, in
    /// this process or the helper.
    func watchBoots(_ onChange: @escaping @MainActor () -> Void)
}

extension GraphicsEnvironment {
    var isSimulation: Bool {
        false
    }

    func bootedRenderer() -> Renderer? {
        nil
    }

    func rendererVersionsChangedSinceBoot() -> Bool {
        false
    }

    func watchBoots(_: @escaping @MainActor () -> Void) {}
}

/// The real one: the bottle's graphics configuration, and the engines and
/// toolkits on disk.
@MainActor
final class LiveGraphicsEnvironment: GraphicsEnvironment {
    private let toolkitStore: URL
    let engineHasOwnD3DMetal: Bool

    init() {
        toolkitStore = D3DMetalInstaller.store
        engineHasOwnD3DMetal = Engine.active.isCrossOver
    }

    var engineName: String {
        Engine.active.description
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
        // (``EngineRenderers/stage``), both halves together. Never place the
        // macOS half here while the Windows half waits for a restart: that
        // pairs one version's dylib with another's DLLs.
        D3DMetalInstaller.choose(version: entry.version)
    }

    func removeToolkit(_ entry: D3DMetalInstaller.Installed) throws {
        try FileManager.default.trashItem(at: entry.root, resultingItemURL: nil)
    }

    func installToolkit(from source: URL, origin: D3DMetalInstaller.Origin) async throws -> D3DMetalInstaller.Installed {
        try await D3DMetalInstaller.install(from: source, intoEngine: toolkitStore, origin: origin)
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
        // Detached: unpacking and copying are disk work.
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

    func bootedRenderer() -> Renderer? {
        BottleGraphics.bootedSelection()?.renderer
    }

    func rendererVersionsChangedSinceBoot() -> Bool {
        BottleGraphics.rendererVersionsChangedSinceBoot()
    }

    func watchBoots(_ onChange: @escaping @MainActor () -> Void) {
        bootWatch = PreferenceWatch(keys: BottleGraphics.bootRecordKeys, in: Preferences.shared, onChange: onChange)
    }

    private var bootWatch: PreferenceWatch?
}

/// Key-value observation of preference keys, which hears a write from any
/// process sharing the suite.
private final class PreferenceWatch: NSObject {
    private let defaults: UserDefaults
    private let keys: [String]
    private let onChange: @MainActor () -> Void

    init(keys: [String], in defaults: UserDefaults, onChange: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.keys = keys
        self.onChange = onChange
        super.init()
        for key in keys {
            defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
    }

    isolated deinit {
        for key in keys {
            defaults.removeObserver(self, forKeyPath: key)
        }
    }

    override nonisolated func observeValue(
        forKeyPath _: String?, of _: Any?, change _: [NSKeyValueChangeKey: Any]?,
        context _: UnsafeMutableRawPointer?,
    ) {
        Task { @MainActor [weak self] in self?.onChange() }
    }
}
