import Foundation

/// The Apple chip's generation and width, parsed from
/// `machdep.cpu.brand_string` ("Apple M1 Max"); the generation is a number,
/// so a newer chip lands on its own rung.
nonisolated struct MacChip: Equatable, Sendable {
    enum Tier: String, Sendable, CaseIterable {
        case base
        case pro
        case max
        case ultra
    }

    /// 1 for M1; `nil` for an Intel Mac or an unparsed name.
    let generation: Int?
    let tier: Tier
    let name: String

    static let current = read()

    static func parse(_ brand: String) -> MacChip {
        let trimmed = brand.trimmingCharacters(in: .whitespaces)
        let words = trimmed.split(separator: " ")
        guard words.count >= 2, words[0] == "Apple", words[1].hasPrefix("M"),
              let generation = Int(words[1].dropFirst()), generation > 0
        else {
            return MacChip(generation: nil, tier: .max, name: trimmed)
        }
        let tier = words.count >= 3
            ? Tier(rawValue: words[2].lowercased()) ?? .base
            : .base
        return MacChip(generation: generation, tier: tier, name: trimmed)
    }

    private static func read() -> MacChip {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return MacChip(generation: nil, tier: .max, name: "this Mac")
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return MacChip(generation: nil, tier: .max, name: "this Mac")
        }
        return parse(String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self))
    }
}

/// One graphics card as a game reads it, with its registry driver metadata.
nonisolated struct GraphicsCard: Equatable, Sendable {
    let name: String
    let vendorID: UInt16
    let deviceID: UInt16
    /// The card's shipping memory in megabytes, so the figure fits the card.
    let videoMemoryMB: Int
    /// The vendor's internal Windows driver version string.
    let driverVersion: String
    /// `M-D-YYYY`, the format Windows keeps in the registry.
    let driverDate: String
    let provider: String
}

/// Which real graphics card each Apple chip is reported as.
///
/// Matched by approximate raster parity at 1440p in published benchmarks,
/// from the RTX 40/50 and RX 7000/9000 generations, with device ids from
/// pci.ids. Shipping memory figures are usually below what the Mac offers,
/// which keeps a game's texture budget inside what the chip holds.
nonisolated enum GPUEquivalence {
    /// The newest generation with rows; a later chip reads as this one.
    static let newestGeneration = 5

    /// An unrecognized chip's tier, at the newest generation.
    static let fallbackTier = MacChip.Tier.max

    static func nvidia(for chip: MacChip) -> GraphicsCard {
        card(for: chip, in: nvidiaCards, driver: nvidiaDriver)
    }

    static func amd(for chip: MacChip) -> GraphicsCard {
        card(for: chip, in: amdCards, driver: amdDriver)
    }

    private static func card(
        for chip: MacChip,
        in table: [Rung: (String, UInt16, Int)],
        driver: (version: String, date: String, provider: String, vendor: UInt16),
    ) -> GraphicsCard {
        let generation = min(chip.generation ?? newestGeneration, newestGeneration)
        let tier = chip.generation == nil ? fallbackTier : chip.tier
        let entry = table[Rung(generation: generation, tier: tier)]
            ?? table[Rung(generation: newestGeneration, tier: fallbackTier)]!
        return GraphicsCard(
            name: entry.0,
            vendorID: driver.vendor,
            deviceID: entry.1,
            videoMemoryMB: entry.2 * 1024,
            driverVersion: driver.version,
            driverDate: driver.date,
            provider: driver.provider,
        )
    }

    private struct Rung: Hashable {
        let generation: Int
        let tier: MacChip.Tier
    }

    // MARK: - The tables

    /// Name, PCI device id, memory in gigabytes.
    private static let nvidiaCards: [Rung: (String, UInt16, Int)] = [
        Rung(generation: 1, tier: .base): ("NVIDIA GeForce RTX 4060", 0x2882, 8),
        Rung(generation: 1, tier: .pro): ("NVIDIA GeForce RTX 4060 Ti", 0x2803, 8),
        Rung(generation: 1, tier: .max): ("NVIDIA GeForce RTX 4070", 0x2786, 12),
        Rung(generation: 1, tier: .ultra): ("NVIDIA GeForce RTX 4070 Ti SUPER", 0x2705, 16),

        Rung(generation: 2, tier: .base): ("NVIDIA GeForce RTX 4060", 0x2882, 8),
        Rung(generation: 2, tier: .pro): ("NVIDIA GeForce RTX 4060 Ti", 0x2803, 8),
        Rung(generation: 2, tier: .max): ("NVIDIA GeForce RTX 4070 SUPER", 0x2783, 12),
        Rung(generation: 2, tier: .ultra): ("NVIDIA GeForce RTX 4080", 0x2704, 16),

        Rung(generation: 3, tier: .base): ("NVIDIA GeForce RTX 5060", 0x2D05, 8),
        Rung(generation: 3, tier: .pro): ("NVIDIA GeForce RTX 5060 Ti", 0x2D04, 16),
        Rung(generation: 3, tier: .max): ("NVIDIA GeForce RTX 5070", 0x2F04, 12),
        Rung(generation: 3, tier: .ultra): ("NVIDIA GeForce RTX 5080", 0x2C02, 16),

        Rung(generation: 4, tier: .base): ("NVIDIA GeForce RTX 5060", 0x2D05, 8),
        Rung(generation: 4, tier: .pro): ("NVIDIA GeForce RTX 5060 Ti", 0x2D04, 16),
        Rung(generation: 4, tier: .max): ("NVIDIA GeForce RTX 5070 Ti", 0x2C05, 16),
        Rung(generation: 4, tier: .ultra): ("NVIDIA GeForce RTX 5080", 0x2C02, 16),

        Rung(generation: 5, tier: .base): ("NVIDIA GeForce RTX 5060 Ti", 0x2D04, 8),
        Rung(generation: 5, tier: .pro): ("NVIDIA GeForce RTX 5070", 0x2F04, 12),
        Rung(generation: 5, tier: .max): ("NVIDIA GeForce RTX 5080", 0x2C02, 16),
        Rung(generation: 5, tier: .ultra): ("NVIDIA GeForce RTX 5090", 0x2B85, 32),
    ]

    /// Navi 32 and Navi 48 ship several retail cards under one device id.
    private static let amdCards: [Rung: (String, UInt16, Int)] = [
        Rung(generation: 1, tier: .base): ("AMD Radeon RX 7600", 0x7480, 8),
        Rung(generation: 1, tier: .pro): ("AMD Radeon RX 7600 XT", 0x7480, 16),
        Rung(generation: 1, tier: .max): ("AMD Radeon RX 7700 XT", 0x747E, 12),
        Rung(generation: 1, tier: .ultra): ("AMD Radeon RX 7800 XT", 0x747E, 16),

        Rung(generation: 2, tier: .base): ("AMD Radeon RX 7600", 0x7480, 8),
        Rung(generation: 2, tier: .pro): ("AMD Radeon RX 7600 XT", 0x7480, 16),
        Rung(generation: 2, tier: .max): ("AMD Radeon RX 7800 XT", 0x747E, 16),
        Rung(generation: 2, tier: .ultra): ("AMD Radeon RX 7900 XT", 0x744C, 20),

        Rung(generation: 3, tier: .base): ("AMD Radeon RX 9060 XT", 0x7590, 8),
        Rung(generation: 3, tier: .pro): ("AMD Radeon RX 9060 XT", 0x7590, 16),
        Rung(generation: 3, tier: .max): ("AMD Radeon RX 9070", 0x7550, 16),
        Rung(generation: 3, tier: .ultra): ("AMD Radeon RX 9070 XT", 0x7550, 16),

        Rung(generation: 4, tier: .base): ("AMD Radeon RX 9060 XT", 0x7590, 8),
        Rung(generation: 4, tier: .pro): ("AMD Radeon RX 9060 XT", 0x7590, 16),
        Rung(generation: 4, tier: .max): ("AMD Radeon RX 9070 XT", 0x7550, 16),
        Rung(generation: 4, tier: .ultra): ("AMD Radeon RX 9070 XT", 0x7550, 16),

        Rung(generation: 5, tier: .base): ("AMD Radeon RX 9060 XT", 0x7590, 8),
        Rung(generation: 5, tier: .pro): ("AMD Radeon RX 9070", 0x7550, 16),
        Rung(generation: 5, tier: .max): ("AMD Radeon RX 9070 XT", 0x7550, 16),
        Rung(generation: 5, tier: .ultra): ("AMD Radeon RX 9070 XT", 0x7550, 16),
    ]

    // MARK: - Driver versions

    /// GeForce Game Ready 610.88, released 2026-08-03.
    ///
    /// The last two groups spell 610.88 (``unifiedNVIDIAVersion``, held by
    /// the tests), and the leading `32.0` is the pair NVIDIA's shipping
    /// drivers carry, which a game's driver check expects.
    static let nvidiaDriver = (
        version: "32.0.16.1088",
        date: "8-3-2026",
        provider: "NVIDIA",
        vendor: UInt16(0x10DE),
    )

    /// AMD Software: Adrenalin Edition 26.8.1.
    ///
    /// AMD publishes no mapping to the Adrenalin release, so it is spelled
    /// into the third group in AMD's five-digit shape.
    static let amdDriver = (
        version: "32.0.26081.1001",
        date: "8-12-2026",
        provider: "Advanced Micro Devices, Inc.",
        vendor: UInt16(0x1002),
    )

    /// The version a game shows: the last two groups joined, cut to five
    /// digits, split three-and-two (`32.0.15.9571` is `595.71`).
    static func unifiedNVIDIAVersion(from internalVersion: String) -> String? {
        let groups = internalVersion.split(separator: ".")
        guard groups.count >= 4 else { return nil }
        let digits = groups[groups.count - 2] + groups[groups.count - 1]
        guard digits.count >= 5, digits.allSatisfy(\.isNumber) else { return nil }
        let tail = digits.suffix(5)
        return "\(tail.prefix(3)).\(tail.suffix(2))"
    }
}
