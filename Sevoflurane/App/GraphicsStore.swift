import Foundation

/// Where the Graphics pane reads and writes.
///
/// The pane used to call ``BottleGraphics`` directly, which made it a live
/// wire: the gallery draws every surface, and drawing the settings window
/// there meant a stray click rewrote the machine's real bottle. Everything
/// that reaches an engine or a bottle now goes through ``GraphicsEnvironment``,
/// so a simulated one keeps the same shape in memory and touches nothing.
@MainActor
@Observable
final class GraphicsStore {
    private(set) var selection: BottleGraphics.Selection
    private(set) var d3dMetalVersions: [D3DMetalInstaller.Installed]
    private(set) var activeD3DMetal: String?
    private let environment: any GraphicsEnvironment

    init(environment: (any GraphicsEnvironment)? = nil) {
        let environment = environment ?? LiveGraphicsEnvironment()
        self.environment = environment
        selection = environment.currentSelection()
        d3dMetalVersions = environment.installedToolkits()
        activeD3DMetal = environment.activeToolkit()?.version
        gptkEngineInstalled = environment.dx12EngineInstalled
    }

    /// Where installed toolkits are kept for this engine.
    var toolkitStore: URL {
        environment.toolkitStore
    }

    /// Whether the engine brings a D3DMetal of its own, which the user's copy
    /// then replaces rather than supplies.
    var engineHasOwnD3DMetal: Bool {
        environment.engineHasOwnD3DMetal
    }

    /// The renderers the machine can switch between. CrossOver carries
    /// everything; managed engines pool what each declares — choosing a
    /// renderer boots whichever installed engine hosts it (D3DMetal is
    /// ABI-locked to the GPTk Wine, DXMT/DXVK to wine-staging).
    var availableRenderers: [Renderer] {
        guard !engineHasOwnD3DMetal else { return Renderer.allCases }
        return Renderer.allCases.filter(Set(environment.hostedRenderers()).contains)
    }

    // MARK: - The DX12 engine

    private(set) var gptkEngineInstalled = false
    private(set) var gptkEnginePhase: String?
    private(set) var gptkEngineFraction: Double?
    private(set) var gptkEngineError: String?

    /// Downloads Gcenx's game-porting-toolkit Wine and overlays the active
    /// D3DMetal toolkit onto it — the engine the D3DMetal renderer boots.
    func installGPTkEngine() {
        guard gptkEnginePhase == nil else { return }
        guard let toolkit = environment.activeToolkit() else {
            gptkEngineError = "add a D3DMetal toolkit below first"
            return
        }
        let version = environment.dx12EngineVersion
        gptkEngineError = nil
        gptkEnginePhase = "starting"
        Task(name: "Install DX12 engine") { [weak self] in
            guard let self else { return }
            do {
                try await environment.installDX12Engine(overlaying: toolkit) { phase, fraction in
                    DispatchQueue.main.async {
                        self.gptkEnginePhase = phase
                        self.gptkEngineFraction = fraction
                    }
                }
                EventLog.enqueue(.setup, "DX12 engine \(version) installed")
            } catch {
                gptkEngineError = "\(error)"
            }
            gptkEnginePhase = nil
            gptkEngineFraction = nil
            gptkEngineInstalled = environment.dx12EngineInstalled
        }
    }

    func update(_ selection: BottleGraphics.Selection) {
        guard selection != self.selection else { return }
        self.selection = selection
        do {
            try environment.apply(selection)
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
        do {
            try environment.chooseToolkit(version: version)
        } catch {
            EventLog.shared.log(.setup, "D3DMetal version change failed: \(error)")
        }
    }

    /// Trashes an installed toolkit version. The newest remaining one (or
    /// the engine's own copy, where the engine has one) takes over when the
    /// removed version was active.
    func removeD3DMetal(version: String) {
        guard let entry = d3dMetalVersions.first(where: { $0.version == version })
        else { return }
        do {
            try environment.removeToolkit(entry)
        } catch {
            EventLog.shared.log(.setup, "D3DMetal \(version) removal failed: \(error)")
            return
        }
        d3dMetalVersions = environment.installedToolkits()
        EventLog.shared.log(.setup, "D3DMetal \(version) moved to the Trash")
        if activeD3DMetal == version {
            chooseD3DMetal(version: d3dMetalVersions.last?.version)
        }
    }

    /// Answers the failure, so the pane can show it.
    func installD3DMetal(from source: URL) async -> String? {
        do {
            let entry = try await environment.installToolkit(from: source)
            d3dMetalVersions = environment.installedToolkits()
            activeD3DMetal = entry.version
            EventLog.shared.log(.setup, "D3DMetal \(entry.version) added to the engine")
            return nil
        } catch {
            return "\(error)"
        }
    }
}
