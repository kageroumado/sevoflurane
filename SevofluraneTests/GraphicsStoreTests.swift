import Foundation
import Testing
@testable import Sevoflurane

/// Which renderers the store offers, on the simulated engines.
@MainActor
struct GraphicsStoreTests {
    private func store(_ scenario: DemoGraphicsEnvironment.Scenario) -> GraphicsStore {
        GraphicsStore(environment: DemoGraphicsEnvironment(scenario: scenario, stepDelay: .zero))
    }

    @Test
    func `a managed engine with no D3DMetal added does not offer it`() {
        let store = store(.builtInNoToolkit)
        #expect(!store.availableRenderers.contains(.d3dmetal))
        #expect(store.availableRenderers == [.auto, .dxmt, .dxvk, .wined3d])
        #expect(store.menuRenderers == [.dxmt, .dxvk, .wined3d])
        // The engine itself can run it, so Settings does not ask for another engine.
        #expect(store.canHostD3DMetal)
    }

    @Test
    func `a managed engine with a D3DMetal added offers it`() {
        let store = store(.builtInWithToolkit)
        #expect(store.availableRenderers == Renderer.allCases)
        #expect(store.menuRenderers == [.d3dmetal, .dxmt, .dxvk, .wined3d])
    }

    @Test
    func `adding a D3DMetal is what starts offering it`() async {
        let store = store(.builtInNoToolkit)
        #expect(!store.availableRenderers.contains(.d3dmetal))
        let failure = await store.installD3DMetal(from: URL(fileURLWithPath: "/demo/gptk.dmg"), choosing: true)
        #expect(failure == nil)
        #expect(store.availableRenderers.contains(.d3dmetal))
        #expect(store.menuRenderers.contains(.d3dmetal))
    }

    @Test
    func `removing the last D3DMetal stops offering it`() {
        let store = store(.builtInWithToolkit)
        store.removeD3DMetal(version: "4.0 beta 2")
        #expect(store.availableRenderers.contains(.d3dmetal))
        store.removeD3DMetal(version: "3.0")
        #expect(!store.availableRenderers.contains(.d3dmetal))
    }

    @Test
    func `a bottle already on D3DMetal keeps showing it without a toolkit`() {
        let store = store(.builtInNoToolkit)
        var selection = store.selection
        selection.renderer = .d3dmetal
        store.update(selection)
        #expect(store.availableRenderers.contains(.d3dmetal))
        #expect(store.menuRenderers.contains(.d3dmetal))
        selection.renderer = .dxmt
        store.update(selection)
        #expect(!store.availableRenderers.contains(.d3dmetal))
    }

    @Test
    func `CrossOver offers every renderer with its own D3DMetal`() {
        let store = store(.crossOver)
        #expect(store.availableRenderers == Renderer.allCases)
        #expect(store.canHostD3DMetal)
        #expect(store.menuRenderers == [.d3dmetal, .dxmt, .dxvk, .wined3d])
    }

    @Test
    func `a pin the machine no longer offers stays in the pin menu`() {
        let offered: [Renderer] = [.dxmt, .dxvk, .wined3d]
        #expect(GraphicsStore.pinChoices(offered, pinned: .d3dmetal) == [.d3dmetal, .dxmt, .dxvk, .wined3d])
        #expect(GraphicsStore.pinChoices(offered, pinned: .dxvk) == offered)
        #expect(GraphicsStore.pinChoices(offered, pinned: nil) == offered)
    }

    @Test
    func `a renderer change that fails to reach the bottle puts the picker back`() {
        let environment = RefusingGraphicsEnvironment()
        let store = GraphicsStore(environment: environment)
        let before = store.selection
        var wanted = before
        wanted.renderer = before.renderer == .dxvk ? .dxmt : .dxvk

        store.update(wanted)

        #expect(store.selection == before)
        #expect(store.selection == environment.currentSelection())
    }

    @Test
    func `a D3DMetal choice that fails puts back the version in force`() {
        let store = GraphicsStore(environment: RefusingGraphicsEnvironment())
        let before = store.activeD3DMetal
        store.chooseD3DMetal(version: before == "3.0" ? "4.0 beta 2" : "3.0")
        #expect(store.activeD3DMetal == before)
    }
}

/// The simulated built-in engine with a toolkit, except that the bottle
/// refuses every graphics write.
@MainActor
private final class RefusingGraphicsEnvironment: GraphicsEnvironment {
    private let base = DemoGraphicsEnvironment(scenario: .builtInWithToolkit, stepDelay: .zero)
    private struct Refused: Error {}

    var isSimulation: Bool {
        true
    }

    var engineHasOwnD3DMetal: Bool {
        base.engineHasOwnD3DMetal
    }

    var engineName: String {
        base.engineName
    }

    func hostedRenderers() -> [Renderer] {
        base.hostedRenderers()
    }

    func currentSelection() -> BottleGraphics.Selection {
        base.currentSelection()
    }

    func apply(_: BottleGraphics.Selection) throws {
        throw Refused()
    }

    func installedToolkits() -> [D3DMetalInstaller.Installed] {
        base.installedToolkits()
    }

    func activeToolkit() -> D3DMetalInstaller.Installed? {
        base.activeToolkit()
    }

    func chooseToolkit(version _: String?) throws {
        throw Refused()
    }

    func removeToolkit(_: D3DMetalInstaller.Installed) throws {
        throw Refused()
    }

    func installToolkit(from source: URL, origin: D3DMetalInstaller.Origin) async throws -> D3DMetalInstaller.Installed {
        try await base.installToolkit(from: source, origin: origin)
    }

    func installedRendererVersions(_ component: RendererVersions.Component) -> [RendererVersions.Installed] {
        base.installedRendererVersions(component)
    }

    func chosenRendererVersion(_ component: RendererVersions.Component) -> String? {
        base.chosenRendererVersion(component)
    }

    func defaultRendererVersion(_ component: RendererVersions.Component) -> String? {
        base.defaultRendererVersion(component)
    }

    func chooseRendererVersion(_ component: RendererVersions.Component, version: String?) {
        base.chooseRendererVersion(component, version: version)
    }

    func installRendererVersion(
        _ component: RendererVersions.Component, from source: URL, version: String?, sha256: String?,
    ) async throws -> RendererVersions.Installed {
        try await base.installRendererVersion(component, from: source, version: version, sha256: sha256)
    }

    func removeRendererVersion(_ installed: RendererVersions.Installed) throws {
        try base.removeRendererVersion(installed)
    }

    func rendererReleases(_ component: RendererVersions.Component) async -> [RendererVersions.Release] {
        await base.rendererReleases(component)
    }
}
