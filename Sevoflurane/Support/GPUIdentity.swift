import Foundation

/// What the bottle tells a game its graphics card is.
///
/// Every translation layer reports the Mac's GPU honestly, and a growing
/// number of Windows games read that, fail to find a vendor they know, and
/// either refuse to start, keep their best settings back, or offer to install
/// an NVIDIA driver. Each layer has its own way to be told otherwise, so the
/// choice is made once here and written for all of them — whichever one a
/// game ends up on, the answer is the same.
///
/// Which card stands in for this Mac comes from ``GPUEquivalence``, matched to
/// the chip the machine actually has.
nonisolated enum GPUIdentity: String, CaseIterable, Codable, Sendable {
    /// The truth: an Apple GPU.
    case automatic
    case nvidia
    case amd

    /// The card this Mac is reported as, or `nil` when it is reported as
    /// itself.
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

    /// The row in the picker: the card by name, so the choice and its
    /// consequence are the same sentence.
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

    var detail: String {
        detail(for: MacChip.current)
    }

    func detail(for chip: MacChip) -> String {
        switch self {
        case .automatic:
            "Your Mac's own chip, by its real name, on the DirectX 11 and 12 "
                + "renderers; Wine's own Direct3D answers with its stock card, "
                + "a GeForce from 2004. Some games read either one, find a card "
                + "they have never heard of, and offer to install a Windows "
                + "driver instead of starting."
        case .nvidia:
            "Matched to your \(chip.name): a GeForce that runs the same games "
                + "at about the same speed. Games that keep their best "
                + "settings for NVIDIA, or that check the driver before they "
                + "start, find what they are looking for."
        case .amd:
            "Matched to your \(chip.name): a Radeon of about the same speed. "
                + "Worth trying when a game misbehaves specifically on NVIDIA."
        }
    }

    /// The environment every renderer reads, written together: a bottle can
    /// change renderer without changing what the game is told.
    ///
    /// D3DMetal takes the pieces as separate variables and reads them as
    /// `0x`-prefixed hexadecimal. DXMT and DXVK take a config string of
    /// `dxgi.*` keys, semicolon-separated, in the shape both projects use in
    /// their `.conf` files: an id is exactly four bare hex digits, and a
    /// value with a space in it has to be quoted or the parser keeps only the
    /// first word.
    ///
    /// `dxgi.maxDeviceMemory` is DXVK's alone. DXMT reads the same string and
    /// passes over keys it has none of, and D3DMetal has no memory knob at
    /// all, so under those two a game is told how much memory Metal offers
    /// rather than how much the card ships with.
    ///
    /// The `SEVO_GPU_*` names are Wine's own. Wine writes the Windows driver
    /// registry from the display driver's idea of the GPU at every display
    /// enumeration, which is where a game's driver-version check reads, and
    /// where the number is one Wine invents for a card nobody ships; the
    /// engine patch in `Docs/gpu-identity.md` makes it prefer these instead.
    /// An engine without that patch ignores them.
    var environment: [String: String] {
        guard let card else {
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

    /// Every name ``environment`` can set, so choosing Apple clears the ones a
    /// previous choice wrote into a bottle's stored environment.
    static let environmentKeys = [
        "D3DM_VENDOR_ID", "D3DM_DEVICE_ID", "D3DM_DEVICE_DESCRIPTION",
        "DXMT_CONFIG", "DXVK_CONFIG", "DXVK_CONFIG_FILE",
        "SEVO_GPU_VENDOR_ID", "SEVO_GPU_DEVICE_ID", "SEVO_GPU_NAME",
        "SEVO_GPU_MEMORY_MB", "SEVO_GPU_DRIVER_VERSION",
        "SEVO_GPU_DRIVER_DATE", "SEVO_GPU_DRIVER_PROVIDER",
    ]

    // MARK: - DXVK's config file

    /// Where the bottle keeps DXVK's config, as Windows names it.
    ///
    /// This DXVK reads `DXVK_CONFIG_FILE`, and failing that a `dxvk.conf` in
    /// whatever the game's working directory happens to be
    /// (`DXVK-macOS/src/util/config/config.cpp:1020-1033`). It opens the path
    /// through Win32 from inside the prefix, so the path has to be one Windows
    /// can name, which is why the file lives in the bottle rather than in the
    /// app's own storage.
    static let dxvkConfigWindowsPath = #"C:\windows\dxvk.conf"#

    private static let dxvkConfigBottlePath = "drive_c/windows/dxvk.conf"

    /// The file's contents, in DXVK's syntax: one `key = value` a line, an id
    /// as four bare hex digits, and any value holding a space in quotes.
    ///
    /// The rules are the parser's, at `config.cpp:824-869` and
    /// `dxgi_options.cpp:7-27`: a value ends at the first whitespace unless it
    /// is quoted, and `parsePciId` returns -1 for anything that is not exactly
    /// four hex characters. A line whose first character cannot start a key is
    /// read as far as the missing `=` and dropped, which is what makes the
    /// first line a comment. There is no `[section]` header, because one would
    /// gate every option below it on the running executable's name.
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

    /// Puts the file where the bottle's DXVK will find it, and takes it away
    /// again when the bottle goes back to reporting the Apple chip — DXVK has
    /// no way to say "no override", so an absent file is the way to say it.
    static func writeDXVKConfig(_ identity: GPUIdentity, intoBottle bottle: URL) {
        let file = bottle.appendingPathComponent(dxvkConfigBottlePath)
        let manager = FileManager.default
        guard let contents = identity.dxvkConfigFile else {
            try? manager.removeItem(at: file)
            return
        }
        // A path that is not a prefix gets nothing: the file is only meaningful
        // beside a `drive_c` that a bottled DXVK can reach.
        guard manager.fileExists(atPath: file.deletingLastPathComponent().path) else { return }
        try? Data(contents.utf8).write(to: file)
    }

    // MARK: - Wine's own renderer

    /// Wine's own renderer keeps the same numbers in the registry rather than
    /// the environment: `HKCU\Software\Wine\Direct3D`.
    var wineD3DRegistry: [(value: String, data: String)] {
        guard let card else { return [] }
        return [
            ("VideoPciVendorID", String(card.vendorID)),
            ("VideoPciDeviceID", String(card.deviceID)),
        ]
    }

    /// Where the queued registry write waits, in the bottle and as Windows
    /// names it — `regedit` opens it from inside the prefix.
    static let wineD3DRegistryWindowsPath = #"C:\windows\sevo-gpu.reg"#

    private static let wineD3DRegistryBottlePath = "drive_c/windows/sevo-gpu.reg"

    /// The registry file that carries this choice into a prefix.
    ///
    /// Choosing the Apple chip deletes the two values rather than writing
    /// nothing. wined3d keeps whatever it was last told, so a bottle moved off
    /// a card would otherwise go on claiming that card; `=-` is how a registry
    /// file says a value should go away.
    ///
    /// CRLF and UTF-16: `regedit` decides the encoding from the byte order
    /// mark, and a `Version 5.00` file without one is read as the machine's
    /// code page.
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

    /// Puts the registry file in the bottle, ready to import, and answers
    /// where it went.
    ///
    /// The file is written the moment the choice is made, so a prefix that
    /// cannot be reached right now still has the answer waiting in it.
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
