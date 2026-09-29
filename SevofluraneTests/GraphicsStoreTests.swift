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
}
