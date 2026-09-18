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
    private static let everyChip: [MacChip] = (1 ... GPUEquivalence.newestGeneration).flatMap {
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

    /// Two rungs of the ladder, with the ids read out of the pci.ids
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
        let environment = GPUIdentity.nvidia.environment(for: chip)
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
        let environment = GPUIdentity.nvidia.environment(for: chip)
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
        let environment = GPUIdentity.amd.environment(for: chip)
        #expect(environment["SEVO_GPU_DRIVER_PROVIDER"] == "Advanced Micro Devices, Inc.")
        #expect(environment["SEVO_GPU_DRIVER_VERSION"] == GPUEquivalence.amdDriver.version)
        #expect(environment["D3DM_VENDOR_ID"] == "0x1002")
    }

    /// Choosing the Apple chip has to name every variable the other choices
    /// set, or a bottle keeps whichever card it was told about last.
    @Test
    func `the Apple chip clears every name the others write`() {
        let apple = GPUIdentity.automatic.environment(for: chip)
        #expect(apple.count == GPUIdentity.environmentKeys.count)
        #expect(apple.values.filter { !$0.isEmpty } == [])
        for identity in [GPUIdentity.nvidia, .amd] {
            #expect(Set(identity.environment(for: chip).keys) == Set(GPUIdentity.environmentKeys))
        }
    }

    @Test
    func `wined3d gets the same card as a decimal pair`() {
        let entries = GPUIdentity.nvidia.wineD3DRegistry(for: chip)
        #expect(entries.count == 2)
        #expect(entries.first { $0.value == "VideoPciVendorID" }?.data == "4318")
        #expect(entries.first { $0.value == "VideoPciDeviceID" }?.data == "10118")
        #expect(GPUIdentity.automatic.wineD3DRegistry(for: chip).isEmpty)
    }

    @Test
    func `the picker names the card and marks the recommendation`() {
        #expect(GPUIdentity.nvidia.label(for: chip) == "NVIDIA GeForce RTX 4070 (recommended)")
        #expect(GPUIdentity.amd.label(for: chip) == "AMD Radeon RX 7700 XT")
        #expect(GPUIdentity.automatic.label(for: chip) == "Apple M1 Max")
        // The label carries the card; the detail says what reporting it buys.
        #expect(GPUIdentity.nvidia.detail.contains("NVIDIA card"))
        #expect(GPUIdentity.amd.detail.contains("AMD card"))
        #expect(GPUIdentity.automatic.detail.contains("your Mac's chip"))
    }

    @Test
    func `a bottle that has chosen nothing claims a GeForce`() {
        #expect(BottleGraphics.defaultGPU == .nvidia)
    }
}

/// DXVK reads a file rather than the environment, and its parser is strict in
/// two ways that a plainly written file gets wrong. These tests read the file
/// the way DXVK will, rather than matching it against a string.
struct DXVKConfigFileTests {
    /// DXVK's line parser, transcribed from
    /// `DXVK-macOS/src/util/config/config.cpp:824-869`.
    private func parse(_ file: String) -> [String: String] {
        var options: [String: String] = [:]
        for line in file.split(separator: "\n", omittingEmptySubsequences: false) {
            let characters = Array(line)
            var index = 0
            func isWhitespace(_ character: Character) -> Bool {
                character == " " || character == "\t" || character == "\r"
            }
            func isValidKeyCharacter(_ character: Character) -> Bool {
                ("0" ... "9").contains(character)
                    || ("A" ... "Z").contains(character)
                    || ("a" ... "z").contains(character)
                    || character == "." || character == "_"
            }
            func skipWhitespace() {
                while index < characters.count, isWhitespace(characters[index]) { index += 1 }
            }
            skipWhitespace()
            var key = ""
            while index < characters.count, isValidKeyCharacter(characters[index]) {
                key.append(characters[index])
                index += 1
            }
            skipWhitespace()
            guard index < characters.count, characters[index] == "=" else { continue }
            index += 1
            skipWhitespace()
            var value = ""
            var insideString = false
            while index < characters.count {
                if !insideString, isWhitespace(characters[index]) { break }
                if characters[index] == "\"" {
                    insideString.toggle()
                } else {
                    value.append(characters[index])
                }
                index += 1
            }
            options[key] = value
        }
        return options
    }

    /// `parsePciId` from `DXVK-macOS/src/dxgi/dxgi_options.cpp:7-27`, which
    /// answers -1 for anything that is not exactly four hex characters.
    private func parsePciID(_ text: String) -> Int32? {
        guard text.count == 4 else { return nil }
        return text.reduce(Int32(0)) { total, character in
            guard let total, let digit = character.hexDigitValue else { return nil }
            return total * 16 + Int32(digit)
        }
    }

    @Test
    func `the file DXVK reads carries the whole card`() throws {
        let file = try #require(GPUIdentity.nvidia.dxvkConfigFile)
        let options = parse(file)
        let card = try #require(GPUIdentity.nvidia.card)
        #expect(try parsePciID(#require(options["dxgi.customVendorId"])) == Int32(card.vendorID))
        #expect(try parsePciID(#require(options["dxgi.customDeviceId"])) == Int32(card.deviceID))
        #expect(options["dxgi.customDeviceDesc"] == card.name)
        #expect(options["dxgi.maxDeviceMemory"] == String(card.videoMemoryMB))
    }

    /// The name has a space in it, and an unquoted value ends at the first
    /// one — the failure that reached DXMT as `customDeviceDesc = "NVIDIA"`.
    @Test
    func `the card's whole name survives the parser`() throws {
        let options = try parse(#require(GPUIdentity.nvidia.dxvkConfigFile))
        #expect(options["dxgi.customDeviceDesc"]?.contains(" ") == true)
    }

    /// A `[name]` line would gate everything below it on the running
    /// executable's name, and the comment line has to fall through the key
    /// parser rather than become an option.
    @Test
    func `the file has no section header and no stray options`() throws {
        let file = try #require(GPUIdentity.amd.dxvkConfigFile)
        #expect(file.contains("[") == false)
        #expect(parse(file).count == 4)
        #expect(file.hasPrefix("#"))
    }

    @Test
    func `reporting the Apple chip means no file at all`() {
        #expect(GPUIdentity.automatic.dxvkConfigFile == nil)
        #expect(GPUIdentity.automatic.environment["DXVK_CONFIG_FILE"] == "")
    }

    @Test
    func `every renderer is pointed at the same file`() {
        #expect(GPUIdentity.nvidia.environment["DXVK_CONFIG_FILE"] == #"C:\windows\dxvk.conf"#)
        #expect(GPUIdentity.amd.environment["DXVK_CONFIG_FILE"] == #"C:\windows\dxvk.conf"#)
    }

    @Test
    func `the bottle gains the file with a card and loses it without one`() throws {
        let bottle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sevo-dxvk-\(UUID().uuidString)")
        let windows = bottle.appendingPathComponent("drive_c/windows")
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let file = windows.appendingPathComponent("dxvk.conf")

        GPUIdentity.nvidia.writeInto(bottle)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(parse(written)["dxgi.customDeviceDesc"] == GPUIdentity.nvidia.card?.name)

        GPUIdentity.automatic.writeInto(bottle)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    /// A path with no prefix under it is left alone rather than grown a
    /// `drive_c` of its own.
    @Test
    func `a path that is not a bottle gets nothing`() throws {
        let stranger = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sevo-not-a-bottle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stranger) }
        GPUIdentity.nvidia.writeInto(stranger)
        #expect(
            FileManager.default.fileExists(
                atPath: stranger.appendingPathComponent("drive_c").path,
            ) == false,
        )
    }
}

private extension GPUIdentity {
    func writeInto(_ bottle: URL) {
        GPUIdentity.writeDXVKConfig(self, intoBottle: bottle)
    }
}

/// Wine's own renderer reads the card from the prefix's registry, so the
/// choice is only real once the prefix has it. These cover the file that
/// carries it there, which is written the moment the picker moves.
struct WineD3DRegistryTests {
    private func makeBottle() throws -> URL {
        let bottle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sevo-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: bottle.appendingPathComponent("drive_c/windows"),
            withIntermediateDirectories: true,
        )
        return bottle
    }

    private func queuedWrite(in bottle: URL) throws -> String {
        let file = bottle.appendingPathComponent("drive_c/windows/sevo-gpu.reg")
        let data = try Data(contentsOf: file)
        #expect(data.prefix(2) == Data([0xFF, 0xFE]))
        return try #require(String(data: data, encoding: .utf16))
    }

    @Test
    func `a card is written as the two values wined3d reads`() throws {
        let file = GPUIdentity.nvidia.wineD3DRegistryFile
        let card = try #require(GPUIdentity.nvidia.card)
        #expect(file.hasPrefix("Windows Registry Editor Version 5.00"))
        #expect(file.contains(#"[HKEY_CURRENT_USER\Software\Wine\Direct3D]"#))
        #expect(file.contains(String(format: #""VideoPciVendorID"=dword:%08x"#, card.vendorID)))
        #expect(file.contains(String(format: #""VideoPciDeviceID"=dword:%08x"#, card.deviceID)))
        #expect(file.contains("\r\n"))
    }

    /// Writing nothing would leave the bottle claiming the card it was moved
    /// off, so the Apple chip is spelled as a deletion.
    @Test
    func `the Apple chip takes the two values away`() {
        let file = GPUIdentity.automatic.wineD3DRegistryFile
        #expect(file.contains(#""VideoPciVendorID"=-"#))
        #expect(file.contains(#""VideoPciDeviceID"=-"#))
        #expect(file.contains("dword") == false)
    }

    @Test
    func `the bottle has the write the moment the picker moves`() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        for identity in [GPUIdentity.nvidia, .amd, .automatic, .nvidia] {
            GPUIdentity.writeWineD3DRegistry(identity, intoBottle: bottle)
            #expect(try queuedWrite(in: bottle) == identity.wineD3DRegistryFile)
        }
    }

    /// The store's own entry point, with the prefix already holding the answer
    /// so no import is spawned — what is being checked is that the file lands
    /// during the call rather than at some later boot.
    @Test
    func `applying a selection leaves the write in the bottle`() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        try Data("[EnvironmentVariables]\n".utf8)
            .write(to: bottle.appendingPathComponent("cxbottle.conf"))
        let card = try #require(GPUIdentity.amd.card)
        try Data(
            [
                String(format: #""VideoPciVendorID"=dword:%08x"#, card.vendorID),
                String(format: #""VideoPciDeviceID"=dword:%08x"#, card.deviceID),
            ].joined(separator: "\n").utf8,
        ).write(to: bottle.appendingPathComponent("user.reg"))

        try BottleGraphics.apply(
            BottleGraphics.Selection(renderer: .dxvk, msync: true, gpu: .amd),
            toBottle: bottle,
        )
        #expect(try queuedWrite(in: bottle) == GPUIdentity.amd.wineD3DRegistryFile)
    }

    @Test
    func `a prefix already holding the card needs no import`() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let card = try #require(GPUIdentity.nvidia.card)
        let user = bottle.appendingPathComponent("user.reg")

        #expect(BottleGraphics.registryHolds(.nvidia, inBottle: bottle) == false)
        // No values at all is what the Apple chip looks like in a prefix.
        #expect(BottleGraphics.registryHolds(.automatic, inBottle: bottle))

        try Data(
            String(format: #""VideoPciVendorID"=dword:%08x"#, card.vendorID).utf8,
        ).write(to: user)
        #expect(BottleGraphics.registryHolds(.nvidia, inBottle: bottle) == false)

        try Data(
            [
                String(format: #""VideoPciVendorID"=dword:%08x"#, card.vendorID),
                String(format: #""VideoPciDeviceID"=dword:%08x"#, card.deviceID),
            ].joined(separator: "\n").utf8,
        ).write(to: user)
        #expect(BottleGraphics.registryHolds(.nvidia, inBottle: bottle))
        #expect(BottleGraphics.registryHolds(.amd, inBottle: bottle) == false)
        #expect(BottleGraphics.registryHolds(.automatic, inBottle: bottle) == false)
    }

    @Test
    func `a path that is not a bottle gets no write`() throws {
        let stranger = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sevo-not-a-bottle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stranger) }
        #expect(GPUIdentity.writeWineD3DRegistry(.nvidia, intoBottle: stranger) == nil)
    }
}
