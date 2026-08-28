import Foundation

/// What the bottle tells a game its graphics card is.
///
/// Every translation layer reports the Mac's GPU honestly, and a growing
/// number of Windows games read that, fail to find a vendor they know, and
/// either refuse to start or offer to install an NVIDIA driver. Each layer
/// has its own way to be told otherwise, so the choice is made once here and
/// written for all of them — whichever one a game ends up on, the answer is
/// the same.
nonisolated enum GPUIdentity: String, CaseIterable, Codable, Sendable {
    /// The truth: an Apple GPU.
    case automatic
    case nvidia
    case amd

    var label: String {
        switch self {
        case .automatic: "Apple (accurate)"
        case .nvidia: "NVIDIA GeForce RTX 4070"
        case .amd: "AMD Radeon RX 7800 XT"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "What the Mac actually has. Some games read this, decide the card "
                + "is unknown, and offer to install a driver."
        case .nvidia:
            "For games that check for a known card, or that only offer their "
                + "best settings to a GeForce."
        case .amd:
            "The other card games recognise. Worth trying when a game "
                + "misbehaves specifically on NVIDIA."
        }
    }

    /// PCI vendor and device, as the layers want them.
    private var identifiers: (vendor: UInt16, device: UInt16)? {
        switch self {
        case .automatic: nil
        case .nvidia: (0x10DE, 0x2786)
        case .amd: (0x1002, 0x747E)
        }
    }

    /// The environment every renderer reads, written together: a bottle can
    /// change renderer without changing what the game is told.
    ///
    /// D3DMetal takes the pieces as separate variables; DXMT and DXVK take a
    /// config string of `dxgi.*` keys, the same shape both projects use in
    /// their `.conf` files. The hexadecimal form is what those two document;
    /// D3DMetal's parser is undocumented and reads `0x`-prefixed values on
    /// the assumption it takes a base-0 conversion, which is the usual
    /// defensive choice — unverified against a game.
    var environment: [String: String] {
        guard let identifiers else {
            return [
                "D3DM_VENDOR_ID": "",
                "D3DM_DEVICE_ID": "",
                "D3DM_DEVICE_DESCRIPTION": "",
                "DXMT_CONFIG": "",
                "DXVK_CONFIG": "",
            ]
        }
        let vendor = String(format: "0x%04X", identifiers.vendor)
        let device = String(format: "0x%04X", identifiers.device)
        let config = [
            "dxgi.customVendorId = \(vendor)",
            "dxgi.customDeviceId = \(device)",
            "dxgi.customDeviceDesc = \(label)",
        ].joined(separator: "; ")
        return [
            "D3DM_VENDOR_ID": vendor,
            "D3DM_DEVICE_ID": device,
            "D3DM_DEVICE_DESCRIPTION": label,
            "DXMT_CONFIG": config,
            "DXVK_CONFIG": config,
        ]
    }

    /// Wine's own renderer keeps the same numbers in the registry rather than
    /// the environment: `HKCU\Software\Wine\Direct3D`.
    var wineD3DRegistry: [(value: String, data: String)] {
        guard let identifiers else { return [] }
        return [
            ("VideoPciVendorID", String(identifiers.vendor)),
            ("VideoPciDeviceID", String(identifiers.device)),
        ]
    }
}
