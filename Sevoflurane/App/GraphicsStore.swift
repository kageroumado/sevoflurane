import Foundation

/// Where the Graphics pane reads and writes.
///
/// The pane used to call ``BottleGraphics`` directly, which made it a live
/// wire: the gallery draws every surface, and drawing the settings window
/// there meant a stray click rewrote the machine's real bottle. A preview
/// store keeps the same shape in memory and touches nothing.
@MainActor
@Observable
final class GraphicsStore {
    private(set) var selection: BottleGraphics.Selection
    private(set) var d3dMetalVersions: [D3DMetalInstaller.Installed]
    private(set) var activeD3DMetal: String?
    /// Where installed toolkits are kept for this engine: inside a managed
    /// engine, or the shared store CrossOver is pointed at through the shadow
    /// tree.
    let toolkitStore: URL
    /// Whether the engine brings a D3DMetal of its own, which the user's copy
    /// then replaces rather than supplies.
    let engineHasOwnD3DMetal: Bool
    private let isLive: Bool

    /// The store the app runs on: the bottle and the engine on disk.
    static func live() -> GraphicsStore {
        let store: URL = if case let .managed(version) = Engine.active {
            Engine.managedRoot.appendingPathComponent(version)
        } else {
            D3DMetalInstaller.sharedRoot
        }
        return GraphicsStore(
            selection: BottleGraphics.currentSelection(),
            toolkitStore: store,
            engineHasOwnD3DMetal: Engine.active == .crossover,
            versions: D3DMetalInstaller.installed(inEngine: store),
            active: D3DMetalInstaller.active(inEngine: store)?.version,
            isLive: true,
        )
    }

    #if DEBUG
        /// A store for the gallery: fixed values, no disk behind them.
        static func preview() -> GraphicsStore {
            let engine = URL(fileURLWithPath: "/preview/engine")
            return GraphicsStore(
                selection: BottleGraphics.Selection(
                    renderer: .dxmt, msync: true, gpu: .automatic,
                ),
                toolkitStore: engine,
                engineHasOwnD3DMetal: false,
                versions: [
                    .init(version: "3.0", root: engine),
                    .init(version: "4.0 beta 2", root: engine),
                ],
                active: "4.0 beta 2",
                isLive: false,
            )
        }
    #endif

    private init(
        selection: BottleGraphics.Selection,
        toolkitStore: URL,
        engineHasOwnD3DMetal: Bool,
        versions: [D3DMetalInstaller.Installed],
        active: String?,
        isLive: Bool,
    ) {
        self.selection = selection
        self.toolkitStore = toolkitStore
        self.engineHasOwnD3DMetal = engineHasOwnD3DMetal
        d3dMetalVersions = versions
        activeD3DMetal = active
        self.isLive = isLive
    }

    /// The renderers this engine can switch between. CrossOver carries
    /// D3DMetal itself; a managed engine has it once the user has added their
    /// own copy of Apple's toolkit.
    var availableRenderers: [Renderer] {
        guard !engineHasOwnD3DMetal else { return Renderer.allCases }
        var renderers: [Renderer] = [.auto, .dxmt, .dxvk, .wined3d]
        if !d3dMetalVersions.isEmpty { renderers.insert(.d3dmetal, at: 1) }
        return renderers
    }

    func update(_ selection: BottleGraphics.Selection) {
        guard selection != self.selection else { return }
        self.selection = selection
        guard isLive else { return }
        do {
            try BottleGraphics.applyToActiveEngine(selection)
            EventLog.shared.log(
                .setup,
                "graphics: renderer=\(selection.renderer.rawValue) "
                    + "msync=\(selection.msync) gpu=\(selection.gpu.rawValue)",
            )
        } catch {
            EventLog.shared.log(.setup, "graphics change failed: \(error)")
        }
    }

    /// `nil` means the engine's own — CrossOver's copy, with no shadow tree.
    func chooseD3DMetal(version: String?) {
        activeD3DMetal = version
        guard isLive else { return }
        guard let version, let entry = d3dMetalVersions.first(where: { $0.version == version })
        else {
            D3DMetalInstaller.choose(version: nil)
            CrossOverShadow.remove()
            return
        }
        try? D3DMetalInstaller.activate(entry, inEngine: toolkitStore)
    }

    /// Trashes an installed toolkit version. The newest remaining one (or
    /// the engine's own copy, where the engine has one) takes over when the
    /// removed version was active.
    func removeD3DMetal(version: String) {
        guard isLive,
              let entry = d3dMetalVersions.first(where: { $0.version == version })
        else { return }
        do {
            try FileManager.default.trashItem(at: entry.root, resultingItemURL: nil)
        } catch {
            EventLog.shared.log(.setup, "D3DMetal \(version) removal failed: \(error)")
            return
        }
        d3dMetalVersions = D3DMetalInstaller.installed(inEngine: toolkitStore)
        EventLog.shared.log(.setup, "D3DMetal \(version) moved to the Trash")
        if activeD3DMetal == version {
            chooseD3DMetal(version: d3dMetalVersions.last?.version)
        }
    }

    /// Answers the failure, so the pane can show it.
    func installD3DMetal(from source: URL) async -> String? {
        guard isLive else { return nil }
        do {
            let entry = try await D3DMetalInstaller.install(
                from: source, intoEngine: toolkitStore,
            )
            d3dMetalVersions = D3DMetalInstaller.installed(inEngine: toolkitStore)
            activeD3DMetal = entry.version
            EventLog.shared.log(.setup, "D3DMetal \(entry.version) added to the engine")
            return nil
        } catch {
            return "\(error)"
        }
    }
}
