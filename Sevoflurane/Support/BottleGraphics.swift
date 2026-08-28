import Foundation

/// The graphics translation layer games render through. Steam's own UI never
/// touches Direct3D, so switching takes effect at the next game launch.
nonisolated enum Renderer: String, CaseIterable, Sendable {
    /// The engine picks (CrossOver's "Auto"); today that means D3DMetal
    /// where available.
    case auto
    /// Apple's Game Porting Toolkit layer: D3D11 + D3D12.
    case d3dmetal
    /// DXMT: D3D11 straight to Metal (what CrossOver 26 bundles as 0.72).
    case dxmt
    /// DXVK: D3D9–11 over Vulkan/MoltenVK.
    case dxvk
    /// Wine's own GL/Vulkan-backed wined3d.
    case wined3d

    var label: String {
        switch self {
        case .auto: "Automatic"
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .wined3d: "Wine built-in"
        }
    }

    var detail: String {
        switch self {
        case .auto: "The engine picks the best layer per game."
        case .d3dmetal: "Apple's Game Porting Toolkit — D3D11 and D3D12."
        case .dxmt: "Direct3D 11 straight to Metal."
        case .dxvk: "Direct3D 9–11 over Vulkan."
        case .wined3d: "Wine's own translation — the compatibility fallback."
        }
    }

    /// `WINEDLLOVERRIDES` for a managed engine, whose renderer DLLs are
    /// copied into the prefix as native overrides; nil when built-in Wine
    /// should keep its own DLLs.
    var managedDLLOverrides: String? {
        switch self {
        case .dxvk:
            "d3d9,d3d10core,d3d11,dxgi=n,b"
        case .dxmt, .d3dmetal:
            "d3d10core,d3d11,dxgi=n,b"
        case .auto, .wined3d:
            nil
        }
    }
}

/// Reads and writes the per-bottle graphics knobs. For CrossOver bottles the
/// store is `cxbottle.conf`'s `[EnvironmentVariables]` section — the same
/// store CrossOver's own GUI writes, so the two never fight over a second
/// copy of the truth. For managed engines the store is UserDefaults and the
/// values ride each launch's environment (``Engine/environment(bottle:)``).
nonisolated enum BottleGraphics {
    struct Selection: Equatable, Sendable {
        var renderer: Renderer
        var msync: Bool
    }

    // MARK: - CrossOver bottles (cxbottle.conf)

    /// The knob vocabulary CrossOver's own tooling uses (win10_64 template +
    /// the live bottle): `CX_GRAPHICS_BACKEND` selects the layer, the legacy
    /// per-layer flags (`WINED3DMETAL`, `WINEDXVK`) are kept in agreement
    /// because the bottle templates still read them, and `WINEMSYNC` gates
    /// msync (CrossOver 26 migrated `WINEESYNC` away).
    static func selection(forBottle bottle: URL) -> Selection {
        let vars = environmentVariables(inConf: confText(forBottle: bottle))
        let renderer: Renderer =
            if let backend = vars["CX_GRAPHICS_BACKEND"], !backend.isEmpty {
                Renderer(rawValue: backend) ?? .auto
            } else if vars["WINED3DMETAL"] == "1" {
                .d3dmetal
            } else if vars["WINEDXVK"] == "1" {
                .dxvk
            } else {
                .auto
            }
        return Selection(renderer: renderer, msync: vars["WINEMSYNC"] != "0")
    }

    static func apply(_ selection: Selection, toBottle bottle: URL) throws {
        var text = confText(forBottle: bottle)
        guard !text.isEmpty else {
            throw GraphicsError("no cxbottle.conf in \(bottle.path)")
        }
        let backend = selection.renderer == .auto ? "" : selection.renderer.rawValue
        text = settingVariable("CX_GRAPHICS_BACKEND", to: backend, inConf: text)
        text = settingVariable(
            "WINED3DMETAL", to: selection.renderer == .d3dmetal ? "1" : nil, inConf: text,
        )
        text = settingVariable(
            "WINEDXVK", to: selection.renderer == .dxvk ? "1" : nil, inConf: text,
        )
        text = settingVariable("WINEMSYNC", to: selection.msync ? "1" : "0", inConf: text)
        try Data(text.utf8).write(to: confURL(forBottle: bottle))
    }

    private static func confURL(forBottle bottle: URL) -> URL {
        bottle.appendingPathComponent("cxbottle.conf")
    }

    private static func confText(forBottle bottle: URL) -> String {
        (try? String(contentsOf: confURL(forBottle: bottle), encoding: .utf8)) ?? ""
    }

    /// The `"NAME" = "value"` pairs of `[EnvironmentVariables]`, the last
    /// section of the conf. Comment lines (`;;`) are skipped.
    static func environmentVariables(inConf text: String) -> [String: String] {
        var inSection = false
        var vars: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inSection = trimmed == "[EnvironmentVariables]"
                continue
            }
            guard inSection, !trimmed.hasPrefix(";"),
                  let pair = parseAssignment(trimmed) else { continue }
            vars[pair.0] = pair.1
        }
        return vars
    }

    /// Replaces, appends, or removes (`value: nil`) one variable inside
    /// `[EnvironmentVariables]`, leaving every other byte of the file alone —
    /// CrossOver's own tools read and rewrite this file, so edits must be
    /// surgical.
    static func settingVariable(
        _ name: String, to value: String?, inConf text: String,
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        var inSection = false
        var sectionEnd = lines.count
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inSection {
                    sectionEnd = index
                    break
                }
                inSection = trimmed == "[EnvironmentVariables]"
                continue
            }
            guard inSection, !trimmed.hasPrefix(";"),
                  parseAssignment(trimmed)?.0 == name else { continue }
            if let value {
                lines[index] = "\"\(name)\" = \"\(value)\""
                return lines.joined(separator: "\n")
            }
            lines.remove(at: index)
            return lines.joined(separator: "\n")
        }
        guard let value else { return text }
        guard inSection else {
            return text + "\n[EnvironmentVariables]\n\"\(name)\" = \"\(value)\"\n"
        }
        // Lands after the section's last real assignment: CrossOver parks
        // commented-out examples at the end of the section, and appending
        // below those scatters the file a little more on every write.
        var insertion = sectionEnd
        while insertion > 0 {
            let line = lines[insertion - 1].trimmingCharacters(in: .whitespaces)
            guard line.isEmpty || line.hasPrefix(";") else { break }
            insertion -= 1
        }
        lines.insert("\"\(name)\" = \"\(value)\"", at: insertion)
        return lines.joined(separator: "\n")
    }

    /// Parses one `"NAME" = "value"` line.
    private static func parseAssignment(_ line: String) -> (String, String)? {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2,
              value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else {
            return nil
        }
        return (String(name.dropFirst().dropLast()), String(value.dropFirst().dropLast()))
    }

    // MARK: - Managed engines (UserDefaults)

    private static let rendererKey = "managedRenderer"
    private static let msyncKey = "managedMsync"

    static func managedSelection() -> Selection {
        let defaults = Preferences.shared
        let renderer = defaults.string(forKey: rendererKey)
            .flatMap(Renderer.init(rawValue:)) ?? .dxmt
        let msync = defaults.object(forKey: msyncKey) as? Bool ?? true
        return Selection(renderer: renderer, msync: msync)
    }

    static func setManagedSelection(_ selection: Selection) {
        let defaults = Preferences.shared
        defaults.set(selection.renderer.rawValue, forKey: rendererKey)
        defaults.set(selection.msync, forKey: msyncKey)
    }

    private struct GraphicsError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
