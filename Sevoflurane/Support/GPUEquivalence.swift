import Foundation

/// The Apple chip this Mac has, in the two dimensions that decide how fast
/// its GPU is: which generation, and how wide.
///
/// Read from `machdep.cpu.brand_string`, which is the marketing name
/// ("Apple M1 Max") and the one place both halves are stated together. The
/// generation is parsed as a number rather than matched against a list, so a
/// chip newer than this build still lands on its own rung.
nonisolated struct MacChip: Equatable, Sendable {
    /// How wide the GPU is, in Apple's own ladder.
    enum Tier: String, Sendable, CaseIterable {
        case base, pro, max, ultra
    }

    /// The generation number: 1 for M1, 3 for M3. `nil` on a Mac whose brand
    /// string is not an Apple chip at all — an Intel Mac, or a name shaped in
    /// a way this parser has never seen.
    let generation: Int?
    let tier: Tier
    /// The brand string as macOS gives it, for showing to the user.
    let name: String

    /// The chip this process is running on, read once.
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

/// One graphics card, as a game reads it: the four numbers DXGI hands over
/// and the driver metadata Windows keeps in the registry beside them.
nonisolated struct GraphicsCard: Equatable, Sendable {
    let name: String
    let vendorID: UInt16
    let deviceID: UInt16
    /// The card's own memory, in megabytes. A Mac has one pool of memory and
    /// every layer reports a slice of it; this is what a game is told instead,
    /// so the figure agrees with the card it is being sold.
    let videoMemoryMB: Int
    /// The Windows driver version string, in the vendor's own internal shape.
    let driverVersion: String
    /// `M-D-YYYY`, the format Windows keeps in the registry.
    let driverDate: String
    let provider: String
}

/// Which real graphics card each Apple chip is reported as.
///
/// The basis is approximate raster parity at 1440p — how the chip and the
/// card actually land in the same games, from published benchmark runs, and
/// not either vendor's marketing tier. Cards come from the RTX 40/50 and
/// Radeon RX 7000/9000 generations, with PCI device ids taken from the
/// pci.ids registry, so a game that looks the id up finds the card the name
/// promises.
///
/// Memory figures are the shipping card's, which is usually less than the
/// Mac has to give. Reporting less than the machine can supply is the safe
/// direction: it keeps the card believable, and a game that sizes its
/// textures to it stays inside what the chip can hold.
nonisolated enum GPUEquivalence {
    /// The newest generation with a row of its own. A chip past it is read as
    /// this generation at its own tier — a future Mac is at least this fast.
    static let newestGeneration = 5

    /// What an unrecognized chip is reported as: the Max-tier card of the
    /// newest generation. Any Mac that can run this app is at least a base
    /// chip, and the Max rung is the one that leaves a game's settings
    /// somewhere sensible.
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

    /// Navi 32 and Navi 48 each cover several retail cards under one device
    /// id, which is why the same id appears at more than one rung with a
    /// different name and memory size — exactly as the real cards ship.
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

    /// GeForce Game Ready 610.88, released 2026-08-03; recorded 2026-09-02.
    ///
    /// The four groups are Windows' own driver-version shape, and only the
    /// last two carry the number a game recognizes: joined and cut to five
    /// digits they spell 610.88, which is what NVIDIA's control panel — and a
    /// game's minimum-driver check — call the version. ``unifiedNVIDIAVersion``
    /// does that conversion, and the tests hold the two in agreement.
    ///
    /// The leading `32.0` is the pair NVIDIA's shipping drivers carry. Wine
    /// writes a higher first group for the cards it invents; matching NVIDIA
    /// is the point here, because a game that reads driver strings at all
    /// reads them as NVIDIA's, and the first group is the Windows driver
    /// model rather than anything about recency.
    static let nvidiaDriver = (
        version: "32.0.16.1088",
        date: "8-3-2026",
        provider: "NVIDIA",
        vendor: UInt16(0x10DE),
    )

    /// AMD Software: Adrenalin Edition 26.8.1; recorded 2026-09-02.
    ///
    /// AMD publishes no mapping from the internal string to the Adrenalin
    /// release, so the release is spelled into the third group where a reader
    /// can see it, in the five-digit shape AMD's own strings use.
    static let amdDriver = (
        version: "32.0.26081.1001",
        date: "8-12-2026",
        provider: "Advanced Micro Devices, Inc.",
        vendor: UInt16(0x1002),
    )

    /// The version a game shows the player and compares against its own
    /// floor, from the internal four-group string: the last two groups
    /// joined, cut to their last five digits, split three-and-two. NVIDIA's
    /// `32.0.15.9571` is `595.71` by this rule.
    static func unifiedNVIDIAVersion(from internalVersion: String) -> String? {
        let groups = internalVersion.split(separator: ".")
        guard groups.count >= 4 else { return nil }
        let digits = groups[groups.count - 2] + groups[groups.count - 1]
        guard digits.count >= 5, digits.allSatisfy(\.isNumber) else { return nil }
        let tail = digits.suffix(5)
        return "\(tail.prefix(3)).\(tail.suffix(2))"
    }
}
