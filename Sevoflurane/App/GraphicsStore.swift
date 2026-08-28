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
    /// The managed engine's directory, when that is what is running. `nil`
    /// under CrossOver, which carries its own D3DMetal.
    let managedEngine: URL?
    private let isLive: Bool

    /// The store the app runs on: the bottle and the engine on disk.
    static func live() -> GraphicsStore {
        let engine: URL? = if case let .managed(version) = Engine.active {
            Engine.managedRoot.appendingPathComponent(version)
        } else {
            nil
        }
        return GraphicsStore(
            selection: BottleGraphics.currentSelection(),
            managedEngine: engine,
            versions: engine.map(D3DMetalInstaller.installed) ?? [],
            active: engine.flatMap { D3DMetalInstaller.active(inEngine: $0)?.version },
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
                managedEngine: engine,
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
        managedEngine: URL?,
        versions: [D3DMetalInstaller.Installed],
        active: String?,
        isLive: Bool,
    ) {
        self.selection = selection
        self.managedEngine = managedEngine
        d3dMetalVersions = versions
        activeD3DMetal = active
        self.isLive = isLive
    }

    /// The renderers this engine can switch between. CrossOver carries
    /// D3DMetal itself; a managed engine has it once the user has added their
    /// own copy of Apple's toolkit.
    var availableRenderers: [Renderer] {
        guard managedEngine != nil else { return Renderer.allCases }
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

    func chooseD3DMetal(version: String) {
        activeD3DMetal = version
        guard isLive, let managedEngine,
              let entry = d3dMetalVersions.first(where: { $0.version == version })
        else { return }
        try? D3DMetalInstaller.activate(entry, inEngine: managedEngine)
    }

    /// Answers the failure, so the pane can show it.
    func installD3DMetal(from source: URL) async -> String? {
        guard isLive, let managedEngine else { return nil }
        do {
            let entry = try await D3DMetalInstaller.install(
                from: source, intoEngine: managedEngine,
            )
            d3dMetalVersions = D3DMetalInstaller.installed(inEngine: managedEngine)
            activeD3DMetal = entry.version
            EventLog.shared.log(.setup, "D3DMetal \(entry.version) added to the engine")
            return nil
        } catch {
            return "\(error)"
        }
    }
}
