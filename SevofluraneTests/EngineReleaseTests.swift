import Testing
@testable import Sevoflurane

/// Which engine keeps winebus's SDL backend, by release number.
struct EngineReleaseTests {
    @Test
    func `a managed engine's release number is read from its directory name`() {
        #expect(Engine.managed(version: "dormison-r11").managedRelease == 11)
        #expect(Engine.managed(version: "dormison-r9").managedRelease == 9)
        #expect(Engine.managed(version: "dormison-r9-network-20260917").managedRelease == nil)
        #expect(Engine.managed(version: "custom").managedRelease == nil)
        #expect(Engine.crossover.managedRelease == nil)
    }

    @Test
    func `the SDL bus stays on from r11, and only there`() {
        #expect(Engine.managed(version: "dormison-r11").keepsSDLBus)
        #expect(Engine.managed(version: "dormison-r12").keepsSDLBus)
        #expect(!Engine.managed(version: "dormison-r10").keepsSDLBus)
        #expect(!Engine.managed(version: "custom").keepsSDLBus)
        #expect(!Engine.crossover.keepsSDLBus)
        #expect(!Engine.crossoverPreview.keepsSDLBus)
    }
}
