import Foundation

/// What the bottle tells a game its graphics card is.
///
/// Games that see an unknown vendor refuse to start, hold back settings or
/// offer an NVIDIA driver, so one choice is written for every translation
/// layer; ``GPUEquivalence`` matches the card to this Mac's chip.
nonisolated enum GPUIdentity: String, CaseIterable, Codable, Sendable {
    /// The truth: an Apple GPU.
    case automatic
    case nvidia
    case amd

    /// The card this Mac is reported as; `nil` for itself.
    var card: GraphicsCard? {
        card(for: MacChip.current)
    }

    func card(for chip: MacChip) -> GraphicsCard? {
        switch self {
        case .automatic: nil
        case .nvidia: GPUEquivalence.nvidia(for: chip)
        case .amd: GPUEquivalence.amd(for: chip)
        }
    }

    /// The picker row: the card by name.
    var label: String {
        label(for: MacChip.current)
    }

    func label(for chip: MacChip) -> String {
        switch self {
        case .automatic: chip.name
        case .nvidia: "\(GPUEquivalence.nvidia(for: chip).name) (recommended)"
        case .amd: GPUEquivalence.amd(for: chip).name
        }
    }

    /// What picking this identity buys, the same on every Mac.
    var detail: String {
        switch self {
        case .automatic:
            "Reports your Mac's chip to the DirectX 11 and 12 renderers. Wine's built-in renderer reports its own card."
        case .nvidia:
            "Reports an NVIDIA card, which passes most GPU and driver checks. Speed still depends on your Mac."
        case .amd:
            "Reports an AMD card. Try this if a game rejects the NVIDIA card."
        }
    }

    /// The environment every renderer reads, so a renderer change keeps what
    /// the game is told. D3DMetal reads `0x`-prefixed hex variables; DXMT and
    /// DXVK read `;`-separated `dxgi.*` keys, ids as four bare hex digits and
    /// spaced values quoted. Only DXVK honors `dxgi.maxDeviceMemory`.
    ///
    /// The `SEVO_GPU_*` names are Wine's own. Wine writes the Windows driver
    /// registry, where a game's driver-version check reads, from the display
    /// driver's idea of the GPU at every display enumeration, with a version
    /// it invents; the engine patch makes it prefer these, and an engine
    /// without the patch ignores them.
    var environment: [String: String] {
        environment(for: MacChip.current)
    }

    func environment(for chip: MacChip) -> [String: String] {
        guard let card = card(for: chip) else {
            return Self.environmentKeys.reduce(into: [:]) { $0[$1] = "" }
        }
        let vendor = String(format: "0x%04X", card.vendorID)
        let device = String(format: "0x%04X", card.deviceID)
        let config = [
            String(format: "dxgi.customVendorId = %04x", card.vendorID),
            String(format: "dxgi.customDeviceId = %04x", card.deviceID),
            "dxgi.customDeviceDesc = \"\(card.name)\"",
            "dxgi.maxDeviceMemory = \(card.videoMemoryMB)",
        ].joined(separator: "; ")
        return [
            "D3DM_VENDOR_ID": vendor,
            "D3DM_DEVICE_ID": device,
            "D3DM_DEVICE_DESCRIPTION": card.name,
            "DXMT_CONFIG": config,
            "DXVK_CONFIG": config,
            "DXVK_CONFIG_FILE": Self.dxvkConfigWindowsPath,
            "SEVO_GPU_VENDOR_ID": vendor,
            "SEVO_GPU_DEVICE_ID": device,
            "SEVO_GPU_NAME": card.name,
            "SEVO_GPU_MEMORY_MB": String(card.videoMemoryMB),
            "SEVO_GPU_DRIVER_VERSION": card.driverVersion,
            "SEVO_GPU_DRIVER_DATE": card.driverDate,
            "SEVO_GPU_DRIVER_PROVIDER": card.provider,
        ]
    }

    /// Every name ``environment`` sets, cleared when choosing Apple.
    static let environmentKeys = [
        "D3DM_VENDOR_ID", "D3DM_DEVICE_ID", "D3DM_DEVICE_DESCRIPTION",
        "DXMT_CONFIG", "DXVK_CONFIG", "DXVK_CONFIG_FILE",
        "SEVO_GPU_VENDOR_ID", "SEVO_GPU_DEVICE_ID", "SEVO_GPU_NAME",
        "SEVO_GPU_MEMORY_MB", "SEVO_GPU_DRIVER_VERSION",
        "SEVO_GPU_DRIVER_DATE", "SEVO_GPU_DRIVER_PROVIDER",
    ]

    // MARK: - DXVK's config file

    /// DXVK's config as Windows names it: DXVK opens `DXVK_CONFIG_FILE`
    /// through Win32, so the file lives in the bottle
    /// (`DXVK-macOS/src/util/config/config.cpp:1020-1033`).
    static let dxvkConfigWindowsPath = #"C:\windows\dxvk.conf"#

    private static let dxvkConfigBottlePath = "drive_c/windows/dxvk.conf"

    /// The file in DXVK's syntax (`config.cpp:824-869`,
    /// `dxgi_options.cpp:7-27`): ids as four bare hex digits, spaced values
    /// quoted, the first line dropped as a non-key, and no `[section]`, which
    /// would gate options on the exe name.
    var dxvkConfigFile: String? {
        guard let card else { return nil }
        return """
        # Sevoflurane writes this file. It is replaced when the card changes.
        dxgi.customVendorId = \(String(format: "%04x", card.vendorID))
        dxgi.customDeviceId = \(String(format: "%04x", card.deviceID))
        dxgi.customDeviceDesc = "\(card.name)"
        dxgi.maxDeviceMemory = \(card.videoMemoryMB)
        
        """
    }

    /// Writes the file, or removes it for the Apple chip, since DXVK has no
    /// "no override" value.
    static func writeDXVKConfig(_ identity: GPUIdentity, intoBottle bottle: URL) {
        let file = bottle.appendingPathComponent(dxvkConfigBottlePath)
        let manager = FileManager.default
        guard let contents = identity.dxvkConfigFile else {
            try? manager.removeItem(at: file)
            return
        }
        // Only inside a prefix.
        guard manager.fileExists(atPath: file.deletingLastPathComponent().path) else { return }
        try? Data(contents.utf8).write(to: file)
    }

    // MARK: - Wine's own renderer

    /// wined3d's copy, in `HKCU\Software\Wine\Direct3D`.
    var wineD3DRegistry: [(value: String, data: String)] {
        wineD3DRegistry(for: MacChip.current)
    }

    func wineD3DRegistry(for chip: MacChip) -> [(value: String, data: String)] {
        guard let card = card(for: chip) else { return [] }
        return [
            ("VideoPciVendorID", String(card.vendorID)),
            ("VideoPciDeviceID", String(card.deviceID)),
        ]
    }

    /// The queued registry file, as `regedit` in the prefix names it.
    static let wineD3DRegistryWindowsPath = #"C:\windows\sevo-gpu.reg"#

    private static let wineD3DRegistryBottlePath = "drive_c/windows/sevo-gpu.reg"

    /// The registry file for this choice. The Apple chip deletes the values
    /// (`=-`), since wined3d keeps what it was last told. CRLF and UTF-16
    /// with a BOM, or `regedit` reads the machine's code page.
    var wineD3DRegistryFile: String {
        let values = card.map { card in
            [
                String(format: #""VideoPciVendorID"=dword:%08x"#, card.vendorID),
                String(format: #""VideoPciDeviceID"=dword:%08x"#, card.deviceID),
            ]
        } ?? [#""VideoPciVendorID"=-"#, #""VideoPciDeviceID"=-"#]
        return ([
            "Windows Registry Editor Version 5.00",
            "",
            #"[HKEY_CURRENT_USER\Software\Wine\Direct3D]"#,
        ] + values + [""]).joined(separator: "\r\n")
    }

    /// Writes the registry file into the bottle at once, so an unreachable
    /// prefix still has it waiting.
    @discardableResult
    static func writeWineD3DRegistry(
        _ identity: GPUIdentity, intoBottle bottle: URL,
    ) -> URL? {
        let file = bottle.appendingPathComponent(wineD3DRegistryBottlePath)
        guard FileManager.default.fileExists(
            atPath: file.deletingLastPathComponent().path,
        ) else { return nil }
        var bytes = Data([0xFF, 0xFE])
        bytes.append(contentsOf: Array(identity.wineD3DRegistryFile.utf16).flatMap {
            [UInt8($0 & 0xFF), UInt8($0 >> 8)]
        })
        guard (try? bytes.write(to: file)) != nil else { return nil }
        return file
    }
}
