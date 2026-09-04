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
        case .auto: "Automatic (recommended)"
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .wined3d: "Wine built-in"
        }
    }

    var detail: String {
        switch self {
        case .auto: "A per-game choice made for you. Leave it here."
        case .d3dmetal: "Apple's own. The only one that handles DirectX 12."
        case .dxmt: "DirectX 11, translated straight to Metal."
        case .dxvk: "DirectX 9 to 11, by way of Vulkan."
        case .wined3d: "The slow, safe one that draws almost anything."
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
        case .dxmt:
            "d3d10core,d3d11,dxgi=n,b"
        case .d3dmetal:
            // The GPTk engine's canonical builtins ARE D3DMetal (Apple's
            // libraries overlaid onto Gcenx's game-porting-toolkit Wine),
            // so builtin resolution is already correct.
            nil
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
        var gpu: GPUIdentity = defaultGPU
        /// The D3DMetal toolkit version a game gets, resolved (auto → newest)
        /// for the active managed engine; `nil` for CrossOver or no toolkit.
        /// Part of the booted diff so an engine switch and a version switch
        /// coalesce into one restart rather than two.
        var d3dMetalVersion: String? = nil
    }

    /// The card a bottle claims when nobody has chosen one.
    ///
    /// A GeForce rather than the Apple chip: a game that recognizes the
    /// vendor picks its normal settings and skips its driver-install prompt,
    /// and the card ``GPUEquivalence`` matches is one of about the machine's
    /// real speed, so nothing is promised that the Mac cannot deliver.
    static let defaultGPU = GPUIdentity.nvidia

    /// What the bottle is set to right now, whichever engine owns the store.
    ///
    /// For a managed engine the D3DMetal version is resolved here — not in
    /// ``managedSelection``, which engine resolution itself calls, so reading
    /// ``Engine/active`` from there would recurse.
    static func currentSelection() -> Selection {
        if Engine.active.isCrossOver {
            return selection(forBottle: SteamBottle.root)
        }
        var selection = managedSelection()
        selection.d3dMetalVersion = D3DMetalInstaller.active(inEngine: Engine.active.root)?.version
        return selection
    }

    /// Writes a selection wherever the active engine keeps it.
    static func applyToActiveEngine(_ selection: Selection) throws {
        if Engine.active.isCrossOver {
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
    /// running client can give it. Games inherit the client's environment,
    /// so a per-game pin and a changed bottle default both mean a restart —
    /// the comparison is against what the client *booted* with, never the
    /// stored selection.
    static func rendererNeedingRestart(forApp appID: Int) -> Renderer? {
        let wanted = overrides()[appID]?.renderer ?? currentSelection().renderer
        let booted = bootedSelection()?.renderer ?? currentSelection().renderer
        return wanted == booted ? nil : wanted
    }

    // MARK: - Desired vs booted

    /// How the desired graphics differ from what the running client booted
    /// with — the single classification the launch and restart paths read.
    ///
    /// A renderer or D3DMetal-version change is a **restage**: the DLLs are
    /// resolved from the engine tree, so ``EngineRenderers/stage`` puts the
    /// new ones in place and the next game to launch loads them, with the
    /// client left up. An msync or engine change is a **bounce**: those are
    /// negotiated with a fresh wineserver at spawn, so the client restarts.
    struct GraphicsChange: Equatable {
        /// Renderer or D3DMetal version moved — a restage applies it.
        var restage = false
        /// msync or the engine root moved — the wineserver must go.
        var bounce = false
        var any: Bool { restage || bounce }
    }

    /// Whether a renderer/version change can be applied under a running
    /// client by restaging the tree in place — the next game to launch loads
    /// the new DLLs — rather than bouncing the client. Steam itself does not
    /// render (it does not even draw its own UI here), so nothing it runs
    /// should hold the renderer DLLs open. The one predicate the launch path
    /// reads: flip to `false` if a live client is ever shown to hold them.
    static let hotRestageSupported = true

    /// The change since boot for the bottle default. A nil booted record
    /// (nothing has spawned yet) reads as no change — the first spawn stages
    /// from the desired selection regardless.
    static func graphicsChangeSinceBoot() -> GraphicsChange {
        guard let booted = bootedSelection() else { return GraphicsChange() }
        let wanted = currentSelection()
        return GraphicsChange(
            restage: wanted.renderer != booted.renderer
                || wanted.d3dMetalVersion != booted.d3dMetalVersion,
            bounce: wanted.msync != booted.msync
                || bootedEngineRoot() != Engine.active.root.path,
        )
    }

    /// Brings the active managed engine's Wine tree in line with the desired
    /// selection — both halves of the picked D3DMetal version and the
    /// renderer's DLLs — so the next process to load them gets what the picker
    /// says. Run before every client spawn; idempotent. A no-op for CrossOver,
    /// which keeps its renderers in `cxbottle.conf`, not a shared tree.
    @discardableResult
    static func reconcileManagedTree() -> [String] {
        guard case let .managed(version) = Engine.active else { return [] }
        return EngineRenderers.stage(
            managedSelection().renderer,
            engine: Engine.managedRoot.appendingPathComponent(version),
            bottle: SteamBottle.root,
        )
    }

    // MARK: - What the client booted with

    private static let bootedKey = "bootedGraphics"

    /// Called at every client spawn: the selection games will actually
    /// inherit, whatever Settings says later — plus the engine whose
    /// wineserver is now booted, which is what decides whether a later
    /// restart can leave Windows running.
    static func recordBootedSelection() {
        let selection = currentSelection()
        // The engine root comes last: it holds "/" and could hold "|", so
        // every reader takes it as the tail after a bounded split. The
        // D3DMetal version sits before it so an empty version stays one field.
        Preferences.shared.set(
            "\(selection.renderer.rawValue)|\(selection.msync ? "1" : "0")"
                + "|\(selection.d3dMetalVersion ?? "")|\(Engine.active.root.path)",
            forKey: bootedKey,
        )
    }

    static func bootedSelection() -> (renderer: Renderer, msync: Bool, d3dMetalVersion: String?)? {
        guard let stored = Preferences.shared.string(forKey: bootedKey) else { return nil }
        let parts = stored.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard let renderer = parts.first.flatMap({ Renderer(rawValue: String($0)) })
        else { return nil }
        let version = parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil
        return (renderer, parts.count > 1 && parts[1] == "1", version)
    }

    /// The engine root the running wineserver was booted from.
    static func bootedEngineRoot() -> String? {
        guard let stored = Preferences.shared.string(forKey: bootedKey) else { return nil }
        let parts = stored.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count > 3 else { return nil }
        return String(parts[3])
    }

    private static let overridesKey = "rendererOverrides"
    private static let gpuKey = "SEVO_GPU_IDENTITY"
    private static let gpuAdoptedKey = "gpuIdentityDefaultAdopted"

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
            gpu: vars[gpuKey].flatMap(GPUIdentity.init(rawValue:)) ?? defaultGPU,
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

    /// Moves a bottle still reporting the Apple chip onto the recommended
    /// card, once.
    ///
    /// Every bottle this app sets up carries `SEVO_GPU_IDENTITY`, written
    /// whether or not anyone opened the picker, so an absent key cannot tell
    /// a real choice from a default that has since changed. One pass over the
    /// stored value settles it: a bottle sitting where the old default left
    /// it moves to ``defaultGPU``, and a bottle put back on the Apple chip
    /// after this pass stays there.
    static func adoptDefaultGPU(forBottle bottle: URL) {
        let defaults = Preferences.shared
        guard !defaults.bool(forKey: gpuAdoptedKey) else { return }
        defaults.set(true, forKey: gpuAdoptedKey)
        var managed = managedSelection()
        if managed.gpu == .automatic {
            managed.gpu = defaultGPU
            setManagedSelection(managed)
        }
        var bottled = selection(forBottle: bottle)
        guard bottled.gpu == .automatic else { return }
        bottled.gpu = defaultGPU
        try? apply(bottled, toBottle: bottle)
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
        // DXVK takes its share of the same choice as a file, because this one
        // reads no config string from the environment.
        GPUIdentity.writeDXVKConfig(selection.gpu, intoBottle: bottle)
        try Data(text.utf8).write(to: confURL(forBottle: bottle))
        carryGPUToRegistry(selection.gpu, intoBottle: bottle)
    }

    // MARK: - The prefix's own copy of the choice

    /// Carries the card into the prefix's registry at the moment it is chosen.
    ///
    /// Wine's own renderer reads the card from `HKCU\Software\Wine\Direct3D`
    /// rather than from the launch environment, so a choice that has not
    /// reached the registry has not reached that renderer. `regedit` imports
    /// the file through the engine's own wine, which reaches a prefix that is
    /// already running and starts one for a bottle that is down.
    /// `Process.run()` returns at the spawn, so the caller pays a fork.
    ///
    /// The file lands in the bottle whether or not the import does, and
    /// ``SetupEnvironment`` writes the same two values at the next app start,
    /// so a spawn that fails costs the choice a restart rather than losing it.
    private static func carryGPUToRegistry(_ identity: GPUIdentity, intoBottle bottle: URL) {
        guard GPUIdentity.writeWineD3DRegistry(identity, intoBottle: bottle) != nil,
              !registryHolds(identity, inBottle: bottle)
        else { return }
        let invocation = Engine.active.wineInvocation(
            bottle: bottle.lastPathComponent, wait: .children,
            program: ["regedit", "/S", GPUIdentity.wineD3DRegistryWindowsPath],
        )
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        if let environment = invocation.environment {
            process.environment = environment
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Whether the prefix already says what this choice says, so a bottle that
    /// is right pays no spawn. The Apple chip is the absence of both values.
    static func registryHolds(_ identity: GPUIdentity, inBottle bottle: URL) -> Bool {
        let text = (try? String(
            contentsOf: bottle.appendingPathComponent("user.reg"), encoding: .utf8,
        )) ?? ""
        let entries = identity.wineD3DRegistry
        guard !entries.isEmpty else {
            return !text.contains("\"VideoPciVendorID\"") && !text.contains("\"VideoPciDeviceID\"")
        }
        return entries.allSatisfy { entry in
            text.contains(String(format: "\"%@\"=dword:%08x", entry.value, UInt32(entry.data) ?? 0))
        }
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
        return Selection(renderer: renderer, msync: msync, gpu: gpu ?? defaultGPU)
    }

    static func setManagedSelection(_ selection: Selection) {
        let defaults = Preferences.shared
        defaults.set(selection.renderer.rawValue, forKey: rendererKey)
        defaults.set(selection.msync, forKey: msyncKey)
        defaults.set(selection.gpu.rawValue, forKey: gpuKey)
        // After the store, because the launch environment a spawn inherits is
        // derived from it.
        GPUIdentity.writeDXVKConfig(selection.gpu, intoBottle: SteamBottle.root)
        carryGPUToRegistry(selection.gpu, intoBottle: SteamBottle.root)
        // The renderer is part of managed-engine resolution — D3DMetal
        // boots the GPTk engine, DXMT the wine-staging one — so the next
        // client start re-picks the wine.
        Engine.refreshResolution()
    }

    private struct GraphicsError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
