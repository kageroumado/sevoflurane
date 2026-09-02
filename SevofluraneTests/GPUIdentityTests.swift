import Foundation
import Testing
@testable import Sevoflurane

struct MacChipTests {
    @Test(arguments: [
        ("Apple M1", 1, MacChip.Tier.base),
        ("Apple M1 Pro", 1, .pro),
        ("Apple M1 Max", 1, .max),
        ("Apple M2 Ultra", 2, .ultra),
        ("Apple M3 Max", 3, .max),
        ("Apple M4", 4, .base),
        ("Apple M5 Ultra", 5, .ultra),
        ("Apple M9 Max", 9, .max),
    ])
    func `reads the generation and the tier from the brand string`(
        brand: String, generation: Int, tier: MacChip.Tier,
    ) {
        let chip = MacChip.parse(brand)
        #expect(chip.generation == generation)
        #expect(chip.tier == tier)
        #expect(chip.name == brand)
    }

    @Test(arguments: [
        "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz",
        "Apple Silicon",
        "",
    ])
    func `an unreadable brand string has no generation`(brand: String) {
        #expect(MacChip.parse(brand).generation == nil)
    }

    @Test
    func `this Mac parses`() {
        #expect(MacChip.current.name.isEmpty == false)
    }
}

struct GPUEquivalenceTests {
    private static let everyChip: [MacChip] = (1...GPUEquivalence.newestGeneration).flatMap {
        generation in
        MacChip.Tier.allCases.map {
            MacChip(generation: generation, tier: $0, name: "Apple M\(generation) \($0)")
        }
    }

    @Test(arguments: Self.everyChip)
    func `every rung has a GeForce and a Radeon`(chip: MacChip) {
        let nvidia = GPUEquivalence.nvidia(for: chip)
        #expect(nvidia.vendorID == 0x10DE)
        #expect(nvidia.name.hasPrefix("NVIDIA GeForce RTX"))
        #expect(nvidia.deviceID != 0)
        #expect(nvidia.videoMemoryMB >= 8 * 1024)

        let amd = GPUEquivalence.amd(for: chip)
        #expect(amd.vendorID == 0x1002)
        #expect(amd.name.hasPrefix("AMD Radeon RX"))
        #expect(amd.deviceID != 0)
        #expect(amd.videoMemoryMB >= 8 * 1024)
    }

    /// The two rungs chosen, with the ids read out of the pci.ids
    /// registry: a mid-range card for the M1 Max, a much stronger one for the
    /// M3 Ultra.
    @Test
    func `the documented rungs are the documented cards`() {
        let m1Max = GPUEquivalence.nvidia(for: MacChip.parse("Apple M1 Max"))
        #expect(m1Max.name == "NVIDIA GeForce RTX 4070")
        #expect(m1Max.deviceID == 0x2786)
        #expect(m1Max.videoMemoryMB == 12 * 1024)

        let m3Ultra = GPUEquivalence.nvidia(for: MacChip.parse("Apple M3 Ultra"))
        #expect(m3Ultra.name == "NVIDIA GeForce RTX 5080")
        #expect(m3Ultra.deviceID == 0x2C02)

        #expect(GPUEquivalence.amd(for: MacChip.parse("Apple M1 Max")).deviceID == 0x747E)
    }

    @Test
    func `a chip past the table is read as the newest generation`() {
        let future = GPUEquivalence.nvidia(for: MacChip.parse("Apple M9 Ultra"))
        #expect(future == GPUEquivalence.nvidia(for: MacChip.parse("Apple M5 Ultra")))
    }

    @Test
    func `an unreadable chip falls back to the Max rung`() {
        let unknown = GPUEquivalence.nvidia(for: MacChip.parse("Some Other Processor"))
        let newest = MacChip(
            generation: GPUEquivalence.newestGeneration,
            tier: GPUEquivalence.fallbackTier,
            name: "newest",
        )
        #expect(unknown == GPUEquivalence.nvidia(for: newest))
    }

    @Test(arguments: [
        ("32.0.15.9571", "595.71"),
        ("32.0.15.6094", "560.94"),
        ("31.0.15.1694", "516.94"),
        ("35.0.10.1000", "010.00"),
        ("32.0.16.1088", "610.88"),
    ])
    func `the version a game checks comes out of the internal string`(
        internalVersion: String, unified: String,
    ) {
        #expect(GPUEquivalence.unifiedNVIDIAVersion(from: internalVersion) == unified)
    }

    @Test(arguments: ["32.0.15", "", "32.0.15.abcd", "1.2.3.4"])
    func `a string that is not a driver version converts to nothing`(malformed: String) {
        #expect(GPUEquivalence.unifiedNVIDIAVersion(from: malformed) == nil)
    }

    /// The shipped constant and the number a game compares against have to
    /// stay in step: raising one without the other is the whole bug.
    @Test
    func `the shipped NVIDIA driver reads as the release it names`() {
        #expect(
            GPUEquivalence.unifiedNVIDIAVersion(from: GPUEquivalence.nvidiaDriver.version)
                == "610.88",
        )
    }
}

struct GPUIdentityEnvironmentTests {
    private let chip = MacChip.parse("Apple M1 Max")

    @Test
    func `a GeForce reaches every renderer with the same numbers`() throws {
        let environment = GPUIdentity.nvidia.environment
        #expect(environment["D3DM_VENDOR_ID"] == "0x10DE")
        #expect(environment["D3DM_DEVICE_ID"] == "0x2786")
        #expect(environment["D3DM_DEVICE_DESCRIPTION"] == "NVIDIA GeForce RTX 4070")
        #expect(environment["DXMT_CONFIG"] == environment["DXVK_CONFIG"])
        let config = try #require(environment["DXVK_CONFIG"])
        // Four bare hex digits and a quoted name: DXMT's parser rejects a
        // `0x` prefix outright and truncates an unquoted value at its first
        // space.
        #expect(config.contains("dxgi.customVendorId = 10de"))
        #expect(config.contains("dxgi.customDeviceId = 2786"))
        #expect(config.contains(#"dxgi.customDeviceDesc = "NVIDIA GeForce RTX 4070""#))
        #expect(config.contains("dxgi.maxDeviceMemory = 12288"))
    }

    @Test
    func `the engine gets the whole identity`() {
        let environment = GPUIdentity.nvidia.environment
        #expect(environment["SEVO_GPU_VENDOR_ID"] == "0x10DE")
        #expect(environment["SEVO_GPU_DEVICE_ID"] == "0x2786")
        #expect(environment["SEVO_GPU_NAME"] == "NVIDIA GeForce RTX 4070")
        #expect(environment["SEVO_GPU_MEMORY_MB"] == "12288")
        #expect(environment["SEVO_GPU_DRIVER_VERSION"] == "32.0.16.1088")
        #expect(environment["SEVO_GPU_DRIVER_DATE"] == "8-3-2026")
        #expect(environment["SEVO_GPU_DRIVER_PROVIDER"] == "NVIDIA")
    }

    @Test
    func `a Radeon carries AMD's own driver`() {
        let environment = GPUIdentity.amd.environment
        #expect(environment["SEVO_GPU_DRIVER_PROVIDER"] == "Advanced Micro Devices, Inc.")
        #expect(environment["SEVO_GPU_DRIVER_VERSION"] == GPUEquivalence.amdDriver.version)
        #expect(environment["D3DM_VENDOR_ID"] == "0x1002")
    }

    /// Choosing the Apple chip has to name every variable the other choices
    /// set, or a bottle keeps whichever card it was told about last.
    @Test
    func `the Apple chip clears every name the others write`() {
        let apple = GPUIdentity.automatic.environment
        #expect(apple.count == GPUIdentity.environmentKeys.count)
        #expect(apple.values.filter { !$0.isEmpty } == [])
        for identity in [GPUIdentity.nvidia, .amd] {
            #expect(Set(identity.environment.keys) == Set(GPUIdentity.environmentKeys))
        }
    }

    @Test
    func `wined3d gets the same card as a decimal pair`() {
        let entries = GPUIdentity.nvidia.wineD3DRegistry
        #expect(entries.count == 2)
        #expect(entries.first { $0.value == "VideoPciVendorID" }?.data == "4318")
        #expect(entries.first { $0.value == "VideoPciDeviceID" }?.data == "10118")
        #expect(GPUIdentity.automatic.wineD3DRegistry.isEmpty)
    }

    @Test
    func `the picker names the card and marks the recommendation`() {
        #expect(GPUIdentity.nvidia.label(for: chip) == "NVIDIA GeForce RTX 4070 (recommended)")
        #expect(GPUIdentity.amd.label(for: chip) == "AMD Radeon RX 7700 XT")
        #expect(GPUIdentity.automatic.label(for: chip) == "Apple M1 Max")
        #expect(GPUIdentity.nvidia.detail(for: chip).contains("Apple M1 Max"))
    }

    @Test
    func `a bottle that has chosen nothing claims a GeForce`() {
        #expect(BottleGraphics.defaultGPU == .nvidia)
    }
}
