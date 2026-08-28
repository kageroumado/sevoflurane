import Foundation

/// The graphics translation layer games render through. Steam's own UI never
/// touches Direct3D, so switching takes effect at the next game launch.
nonisolated enum Renderer: String, CaseIterable, Codable, Sendable {
    /// The engine picks per game from CrossOver's own database, falling
    /// back to wined3d for a game it does not list.
    case auto
    /// Apple's Game Porting Toolkit layer: D3D11 + D3D12.
    case d3dmetal
    /// DXMT: D3D10/11 straight to Metal (CrossOver 26 bundles 0.72).
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

    /// When to reach for this one, for the Graphics pane's explainer.
    /// Sourced from CodeWeavers' own toggle documentation and their ARM64
    /// guidance; `Docs/engines-and-renderers.md` carries the dates.
    var guidance: String {
        switch self {
        case .auto:
            "Leave it here unless a game misbehaves. CrossOver's database has "
                + "a per-game answer for most of them."
        case .d3dmetal:
            "The only option that speaks DirectX 12, and the one MetalFX "
                + "upscaling needs. Best for recent, demanding titles."
        case .dxmt:
            "DirectX 11 with no Vulkan in between. Often the steadiest frame "
                + "pacing, and the kinder option on an older Mac."
        case .dxvk:
            "DirectX 9 to 11 by way of Vulkan. Two translations deep — worth "
                + "trying when a game refuses to draw on the Metal paths."
        case .wined3d:
            "Wine's own translation. Slow, and the most likely to render "
                + "something at all: old and 2D games live here."
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
        /// What the bottle tells a game its GPU is.
        var gpu: GPUIdentity = .automatic
    }

    /// What the bottle is set to right now, whichever engine owns the store.
    static func currentSelection() -> Selection {
        Engine.active == .crossover
            ? selection(forBottle: SteamBottle.root)
            : managedSelection()
    }

    /// Writes a selection wherever the active engine keeps it.
    static func applyToActiveEngine(_ selection: Selection) throws {
        if Engine.active == .crossover {
            try apply(selection, toBottle: SteamBottle.root)
        } else {
            setManagedSelection(selection)
        }
    }

    // MARK: - Per-game overrides

    /// A game that wants a renderer of its own, and the name to show for it.
    struct Override: Codable, Equatable, Sendable {
        var renderer: Renderer
        var name: String
    }

    /// Games pinned to a renderer, by Steam app id.
    ///
    /// The bottle's renderer reaches a game through the environment of the
    /// process tree Steam already lives in, so a game cannot be given its own
    /// without restarting the client first. That is what the menu bar warns
    /// about before it launches one.
    static func overrides() -> [Int: Override] {
        guard let data = Preferences.shared.data(forKey: overridesKey),
              let stored = try? JSONDecoder().decode([String: Override].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }

    static func setOverride(_ override: Override?, forApp appID: Int, named name: String) {
        var stored = overrides()
        stored[appID] = override.map { Override(renderer: $0.renderer, name: name) }
        let encodable = Dictionary(
            uniqueKeysWithValues: stored.map { (String($0.key), $0.value) },
        )
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        Preferences.shared.set(data, forKey: overridesKey)
    }

    /// The renderer this game must run under, when that is not what the
    /// bottle is set to — the client has to be restarted to change it.
    static func rendererNeedingRestart(forApp appID: Int) -> Renderer? {
        guard let wanted = overrides()[appID]?.renderer,
              wanted != currentSelection().renderer else { return nil }
        return wanted
    }

    private static let overridesKey = "rendererOverrides"
    private static let gpuKey = "SEVO_GPU_IDENTITY"

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
        return Selection(
            renderer: renderer,
            msync: vars["WINEMSYNC"] != "0",
            gpu: vars[gpuKey].flatMap(GPUIdentity.init(rawValue:)) ?? .automatic,
        )
    }

    /// The renderer a bottle gets when nobody has chosen one.
    ///
    /// Not CrossOver's "Automatic": that consults their per-game database and
    /// falls back to **wined3d**, which is the slowest layer here and the one
    /// a modern title is least likely to run on. A bottle whose whole purpose
    /// is Steam is better served starting on D3DMetal — the only layer that
    /// speaks Direct3D 12 — and a user who prefers the database can still
    /// pick Automatic, which is written as an empty value and left alone.
    static let defaultRenderer = Renderer.d3dmetal

    /// Brings a bottle's graphics settings up to what this app writes:
    /// ``defaultRenderer`` when nothing was ever chosen, and in every case the
    /// derived knobs — the translation defaults and the GPU the games are
    /// told about — which an older bottle predates.
    ///
    /// A renderer already chosen, Automatic included (stored as an empty
    /// value), is left exactly as the user left it.
    static func reassertDefaults(forBottle bottle: URL) throws {
        let text = confText(forBottle: bottle)
        guard !text.isEmpty else { return }
        var selection = selection(forBottle: bottle)
        if environmentVariables(inConf: text)["CX_GRAPHICS_BACKEND"] == nil {
            selection.renderer = defaultRenderer
        }
        try apply(selection, toBottle: bottle)
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
        for (name, value) in Self.translationDefaults {
            text = settingVariable(name, to: value, inConf: text)
        }
        // The choice itself is stored, and every layer's own variables are
        // derived from it — reading five knobs back into one answer would
        // guess where this simply knows.
        text = settingVariable(gpuKey, to: selection.gpu.rawValue, inConf: text)
        for (name, value) in selection.gpu.environment {
            text = settingVariable(name, to: value.isEmpty ? nil : value, inConf: text)
        }
        try Data(text.utf8).write(to: confURL(forBottle: bottle))
    }

    /// Knobs Apple documents for the evaluation environment, and that a Steam
    /// bottle wants on:
    ///
    /// - `ROSETTA_ADVERTISE_AVX` makes the translation layer publish AVX
    ///   support to the game. Rosetta translates those instructions either
    ///   way; without the advertisement a growing number of titles decide the
    ///   CPU is too old and refuse to start.
    /// - `D3DM_ENABLE_METALFX` lets D3DMetal answer a game's DLSS calls with
    ///   MetalFX on macOS 26. It does nothing under the other renderers.
    static let translationDefaults = [
        "ROSETTA_ADVERTISE_AVX": "1",
        "D3DM_ENABLE_METALFX": "1",
    ]

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
        // DXMT rather than ``defaultRenderer``: D3DMetal comes from Apple's
        // Game Porting Toolkit, which the managed engine does not carry.
        let renderer = defaults.string(forKey: rendererKey)
            .flatMap(Renderer.init(rawValue:)) ?? .dxmt
        let msync = defaults.object(forKey: msyncKey) as? Bool ?? true
        let gpu = defaults.string(forKey: gpuKey).flatMap(GPUIdentity.init(rawValue:))
        return Selection(renderer: renderer, msync: msync, gpu: gpu ?? .automatic)
    }

    static func setManagedSelection(_ selection: Selection) {
        let defaults = Preferences.shared
        defaults.set(selection.renderer.rawValue, forKey: rendererKey)
        defaults.set(selection.msync, forKey: msyncKey)
        defaults.set(selection.gpu.rawValue, forKey: gpuKey)
    }

    private struct GraphicsError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
