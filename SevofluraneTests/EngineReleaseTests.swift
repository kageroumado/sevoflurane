import Testing
@testable import Sevoflurane

/// Which engine keeps winebus's SDL backend.
struct EngineReleaseTests {
    @Test
    func `a managed engine's release number is read from its directory name`() {
        #expect(Engine.managed(version: "dormison-r11").managedRelease == 11)
        #expect(Engine.managed(version: "dormison-r9").managedRelease == 9)
        #expect(Engine.managed(version: "dormison-r9-network-20260917").managedRelease == nil)
        #expect(Engine.managed(version: "dormison-b1").managedRelease == 1)
        #expect(Engine.managed(version: "dormison-b12").managedRelease == 12)
        #expect(Engine.managed(version: "dormison-b1-tray").managedRelease == nil)
        #expect(Engine.managed(version: "custom").managedRelease == nil)
        #expect(Engine.crossover.managedRelease == nil)
    }

    @Test
    func `the SDL bus stays on for Dormison releases, and only there`() {
        #expect(Engine.managed(version: "dormison-r1").keepsSDLBus)
        #expect(Engine.managed(version: "dormison-b2").keepsSDLBus)
        #expect(!Engine.managed(version: "custom").keepsSDLBus)
        #expect(!Engine.crossover.keepsSDLBus)
        #expect(!Engine.crossoverPreview.keepsSDLBus)
    }
}
