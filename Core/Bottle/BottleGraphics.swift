import Foundation

/// The graphics translation layer games render through; a switch takes
/// effect at the next game launch.
nonisolated enum Renderer: String, CaseIterable, Codable, Sendable {
    /// The renderers this Mac can run: D3DMetal needs Apple silicon.
    static func hostable(onAppleSilicon appleSilicon: Bool = MacHardware.isAppleSilicon) -> [Renderer] {
        allCases.filter { appleSilicon || $0 != .d3dmetal }
    }

    /// CrossOver's per-game database, falling back to wined3d.
    case auto
    /// Apple's Game Porting Toolkit layer: D3D11 + D3D12.
    case d3dmetal
    /// DXMT: D3D10/11 straight to Metal.
    case dxmt
    /// DXVK: D3D10/11 over Vulkan/MoltenVK.
    case dxvk
    /// Wine's own GL/Vulkan-backed wined3d.
    case wined3d

    var label: String {
        let value = switch self {
        case .auto: "Automatic"
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .wined3d: "Wine built-in"
        }
        return InterfaceCopy.localized(value)
    }

    var detail: String {
        let value = switch self {
        case .auto: "Uses CrossOver's game settings, then Wine's renderer."
        case .d3dmetal: "DirectX 11 and 12 through Apple's Game Porting Toolkit."
        case .dxmt: "DirectX 11, translated straight to Metal."
        case .dxvk: "DirectX 10 and 11, by way of Vulkan."
        case .wined3d: "Wine's built-in Direct3D renderer."
        }
        return InterfaceCopy.localized(value)
    }

    /// When to reach for this one, after CodeWeavers' own documentation.
    var guidance: String {
        let value = switch self {
        case .auto:
            "Uses CrossOver's per-game settings, then Wine's renderer."
        case .d3dmetal:
            "DirectX 11 and 12 through Metal, for 64-bit games. A 32-bit game "
                + "uses Wine's renderer instead. Needs Apple's Game Porting Toolkit, "
                + "or a CrossOver engine with it."
        case .dxmt:
            "DirectX 10 and 11 through Metal. Try it if a DirectX 11 game looks wrong."
        case .dxvk:
            "DirectX 10 and 11 through Vulkan and MoltenVK. DXGI stays Wine's own."
        case .wined3d:
            "Wine's built-in renderer. Try it when the others fail."
        }
        return InterfaceCopy.localized(value)
    }

    /// The layers a game can pin, plus `inherit`.
    static var gameRungs: String {
        allCases.filter { $0 != .auto }.map(\.rawValue).joined(separator: " | ") + " | inherit"
    }

    /// `WINEDLLOVERRIDES` for a managed engine; nil keeps Wine's own DLLs.
    var managedDLLOverrides: String? {
        switch self {
        case .dxvk:
            // Only what the payload ships: naming a DLL it lacks sends a game
            // looking for a native file that is not there.
            "d3d10core,d3d11=n,b"
        case .dxmt:
            "d3d10core,d3d11,dxgi=n,b"
        case .d3dmetal:
            // Staged as the engine's own d3d11/d3d12/dxgi.
            nil
        case .auto, .wined3d:
            nil
        }
    }
}

/// Reads and writes the per-bottle graphics knobs: in `cxbottle.conf`'s
/// `[EnvironmentVariables]` for CrossOver, which its own GUI writes too, and
/// in UserDefaults for managed engines (``Engine/environment(bottle:)``).
nonisolated enum BottleGraphics {
    struct Selection: Equatable, Sendable {
        var renderer: Renderer
        var msync: Bool
        /// What the bottle tells a game its GPU is.
        var gpu: GPUIdentity = defaultGPU
        /// The resolved D3DMetal toolkit version for a managed engine; `nil`
        /// for CrossOver or no toolkit.
        var d3dMetalVersion: String?
    }

    /// The default card: a GeForce a game recognizes, matched by
    /// ``GPUEquivalence`` to about the machine's real speed.
    static let defaultGPU = GPUIdentity.nvidia

    /// What the bottle is set to now. The D3DMetal version is resolved here
    /// because ``managedSelection`` runs inside engine resolution, where
    /// reading ``Engine/active`` would recurse.
    static func currentSelection() -> Selection {
        if Engine.active.isCrossOver {
            return selection(forBottle: SteamBottle.root)
        }
        var selection = managedSelection()
        selection.d3dMetalVersion = D3DMetalInstaller.active(inEngine: D3DMetalInstaller.store)?.version
        return selection
    }

    /// Writes a selection wherever the active engine keeps it. A choice made
    /// here is the bottle's own, so a launch's renderer still in flight
    /// (``LaunchRenderer``) has nothing left to hand back.
    static func applyToActiveEngine(_ selection: Selection) throws {
        Preferences.shared.removeObject(forKey: launchRendererKey)
        if Engine.active.isCrossOver {
            try apply(selection, toBottle: SteamBottle.root)
        } else {
            setManagedSelection(selection)
        }
    }

    // MARK: - Per-game renderers

    /// Whether this game's own renderer reaches it through its env file: the
    /// engine reads env files and the renderer supports
    /// ``EngineRenderers/supportsPerGame(_:)``.
    static func perGameRendererIsLive(forApp appID: Int) -> Bool {
        guard Engine.active.supportsEnvFiles, let own = GameConfig.game(appID).renderer
        else { return false }
        return EngineRenderers.supportsPerGame(own)
    }

    /// The renderer this game needs a client restart for: compared against
    /// what the client *booted* with, never the stored selection.
    static func rendererNeedingRestart(forApp appID: Int) -> Renderer? {
        guard !perGameRendererIsLive(forApp: appID) else { return nil }
        let wanted = GameConfig.renderer(game: appID).value
        let booted = bootedSelection()?.renderer ?? currentSelection().renderer
        return wanted == booted ? nil : wanted
    }

    /// The renderer a launch moves the bottle onto for the length of the run:
    /// an `explicit` "Run with", else the game's own choice when its env file
    /// cannot carry it.
    static func rendererToStage(forApp appID: Int, explicit: Renderer?) -> Renderer? {
        if let explicit { return explicit }
        guard !perGameRendererIsLive(forApp: appID) else { return nil }
        return GameConfig.game(appID).renderer
    }

    // MARK: - A launch's renderer

    /// The bottle on a renderer for one run: `renderer` holds it until the
    /// run of `appID` ends, then `restore` comes back.
    struct LaunchRenderer: Equatable, Sendable {
        var appID: Int
        var renderer: Renderer
        var restore: Renderer

        /// `<appid>|<renderer>|<restore>`, as kept in the preferences.
        init?(stored: String) {
            let parts = stored.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let appID = Int(parts[0]),
                  let renderer = Renderer(rawValue: String(parts[1])),
                  let restore = Renderer(rawValue: String(parts[2])) else { return nil }
            self.init(appID: appID, renderer: renderer, restore: restore)
        }

        init(appID: Int, renderer: Renderer, restore: Renderer) {
            self.appID = appID
            self.renderer = renderer
            self.restore = restore
        }

        var stored: String {
            "\(appID)|\(renderer.rawValue)|\(restore.rawValue)"
        }

        /// What a launch of `appID` on `renderer` leaves in flight. A launch
        /// made while another's renderer holds the bottle keeps that one's
        /// renderer to return to; a launch back onto it leaves nothing.
        static func starting(
            _ renderer: Renderer, forApp appID: Int, current: Renderer, inFlight: LaunchRenderer?,
        ) -> LaunchRenderer? {
            let restore = inFlight?.restore ?? current
            return renderer == restore ? nil : LaunchRenderer(appID: appID, renderer: renderer, restore: restore)
        }

        /// The renderer the bottle returns to when a run of `appID` ends:
        /// none for another game's run, or once the bottle has left the
        /// launch's renderer.
        func rendererToRestore(afterRunOf appID: Int, current: Renderer) -> Renderer? {
            appID == self.appID && current == renderer ? restore : nil
        }
    }

    private static let launchRendererKey = "launchRenderer"

    static func launchRendererInFlight() -> LaunchRenderer? {
        Preferences.shared.string(forKey: launchRendererKey).flatMap(LaunchRenderer.init(stored:))
    }

    /// Moves the bottle onto `renderer` for one run of `appID`; the caller
    /// stages the tree. ``endLaunchRenderer(afterRunOf:)`` hands it back.
    static func beginLaunchRenderer(_ renderer: Renderer, forApp appID: Int) throws {
        let current = currentSelection()
        let inFlight = launchRendererInFlight()
        try applyToActiveEngine(Selection(renderer: renderer, msync: current.msync, gpu: current.gpu))
        let record = LaunchRenderer.starting(
            renderer, forApp: appID, current: current.renderer, inFlight: inFlight,
        )
        Preferences.shared.set(record?.stored, forKey: launchRendererKey)
    }

    /// Returns the bottle to its own renderer once the run a launch moved it
    /// for has ended, restaging the tree, and answers a line for the log.
    @discardableResult
    static func endLaunchRenderer(afterRunOf appID: Int) -> String? {
        guard let inFlight = launchRendererInFlight(), inFlight.appID == appID else { return nil }
        let current = currentSelection()
        guard let restore = inFlight.rendererToRestore(afterRunOf: appID, current: current.renderer) else {
            Preferences.shared.removeObject(forKey: launchRendererKey)
            return nil
        }
        do {
            try applyToActiveEngine(Selection(renderer: restore, msync: current.msync, gpu: current.gpu))
        } catch {
            return "could not return the bottle to \(restore.label) after app \(appID): \(error)"
        }
        reconcileManagedTree()
        recordBootedSelection()
        return "the bottle is back on \(restore.label) now that app \(appID), started on \(inFlight.renderer.label), has ended"
    }

    // MARK: - Desired vs booted

    /// How the desired graphics differ from what the client booted with. A
    /// renderer or D3DMetal-version change is a **restage** of the tree under
    /// a running client; an msync or engine change is a **bounce**, since
    /// those are negotiated with a fresh wineserver.
    struct GraphicsChange: Equatable {
        var restage = false
        var bounce = false
        var any: Bool {
            restage || bounce
        }
    }

    /// Whether a renderer/version change can be applied under a running
    /// client by restaging the tree in place rather than bouncing the client.
    /// Steam itself renders nothing here, so nothing it runs should hold the
    /// renderer DLLs open; flip to `false` if a live client is ever shown to
    /// hold them.
    static let hotRestageSupported = true

    /// The change since boot; no booted record reads as no change.
    static func graphicsChangeSinceBoot() -> GraphicsChange {
        guard let booted = bootedSelection() else { return GraphicsChange() }
        let wanted = currentSelection()
        return GraphicsChange(
            restage: wanted.renderer != booted.renderer
                || wanted.d3dMetalVersion != booted.d3dMetalVersion
                || rendererVersionsChangedSinceBoot(),
            bounce: wanted.msync != booted.msync
                || bootedEngineRoot() != Engine.active.root.path,
        )
    }

    /// Whether the DXMT or DXVK version picked differs from the one recorded
    /// at the last spawn; no record reads as no change.
    static func rendererVersionsChangedSinceBoot() -> Bool {
        guard let booted = Preferences.shared.string(forKey: bootedRenderersKey) else {
            return false
        }
        return booted != rendererVersionRecord()
    }

    private static let bootedRenderersKey = "bootedRendererVersions"

    /// `dxmt=0.80|dxvk=` — one field per component, an empty value meaning
    /// the engine's own. Compared as a whole, never parsed back.
    private static func rendererVersionRecord() -> String {
        RendererVersions.Component.allCases
            .map { "\($0.rawValue)=\(RendererVersions.chosen($0) ?? "")" }
            .joined(separator: "|")
    }

    /// Stages the selected renderer and D3DMetal version into the active
    /// managed engine's tree; run before every client spawn, idempotent.
    @discardableResult
    static func reconcileManagedTree() -> [String] {
        guard case let .managed(version) = Engine.active else { return [] }
        return EngineRenderers.stage(
            managedSelection().renderer,
            engine: Engine.managedRoot.appendingPathComponent(version),
            bottle: SteamBottle.root,
        )
    }

    /// One log line naming what a staging pass put in the tree, so a
    /// black-screen report names the layer the game loaded.
    static func stagingNote(_ staged: [String]) -> String? {
        guard case .managed = Engine.active else { return nil }
        let toolkit = D3DMetalInstaller.active(inEngine: D3DMetalInstaller.store)?.version
        return "staged \(staged.count) renderer DLL(s) for \(managedSelection().renderer.label)"
            + (toolkit.map { ", D3DMetal \($0)" } ?? "")
    }

    // MARK: - What the client booted with

    private static let bootedKey = "bootedGraphics"

    /// The preference keys every client spawn rewrites.
    static let bootRecordKeys = [bootedKey, bootedRenderersKey]

    /// Records at every client spawn the selection games inherit and the
    /// engine whose wineserver is booted.
    static func recordBootedSelection() {
        let selection = currentSelection()
        // The engine root comes last because it could hold "|": readers take
        // it as the tail of a bounded split.
        Preferences.shared.set(
            "\(selection.renderer.rawValue)|\(selection.msync ? "1" : "0")"
                + "|\(selection.d3dMetalVersion ?? "")|\(Engine.active.root.path)",
            forKey: bootedKey,
        )
        Preferences.shared.set(rendererVersionRecord(), forKey: bootedRenderersKey)
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

    private static let gpuKey = "SEVO_GPU_IDENTITY"
    private static let gpuAdoptedKey = "gpuIdentityDefaultAdopted"

    // MARK: - CrossOver bottles (cxbottle.conf)

    /// CrossOver's knobs: `CX_GRAPHICS_BACKEND` selects the layer, the legacy
    /// `WINED3DMETAL` and `WINEDXVK` flags are kept in agreement because the
    /// templates still read them, and `WINEMSYNC` gates msync.
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
    /// D3DMetal, the only layer that speaks Direct3D 12. CrossOver's
    /// "Automatic" falls back to wined3d, the slowest layer here and the one a
    /// modern title is least likely to run on; a user who prefers its database
    /// can still pick Automatic, which is written as an empty value and left
    /// alone.
    static let defaultRenderer = Renderer.d3dmetal

    /// Writes ``defaultRenderer`` when no renderer was ever chosen (Automatic
    /// is an empty value and stays), and in every case the derived knobs.
    static func reassertDefaults(forBottle bottle: URL) throws {
        let text = confText(forBottle: bottle)
        guard !text.isEmpty else { return }
        var selection = selection(forBottle: bottle)
        if environmentVariables(inConf: text)["CX_GRAPHICS_BACKEND"] == nil {
            selection.renderer = defaultRenderer
        }
        try apply(selection, toBottle: bottle)
    }

    /// Moves a bottle still reporting the Apple chip onto ``defaultGPU``, once
    /// per Mac, so a bottle put back on the Apple chip afterwards stays there.
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
        // The choice is stored; each layer's variables are derived from it.
        text = settingVariable(gpuKey, to: selection.gpu.rawValue, inConf: text)
        for (name, value) in selection.gpu.environment {
            text = settingVariable(name, to: value.isEmpty ? nil : value, inConf: text)
        }
        // This DXVK reads its share only from a file.
        GPUIdentity.writeDXVKConfig(selection.gpu, intoBottle: bottle)
        try Data(text.utf8).write(to: confURL(forBottle: bottle))
        carryGPUToRegistry(selection.gpu, intoBottle: bottle)
    }

    // MARK: - The prefix's own copy of the choice

    /// Carries the card into the prefix's registry at the moment it is chosen.
    ///
    /// Wine's own renderer reads the card from `HKCU\Software\Wine\Direct3D`,
    /// not from the launch environment. `regedit` imports the file through the
    /// engine's own wine, which reaches a running prefix and boots a stopped one.
    ///
    /// For the Steam bottle the daemon, which owns every process there, runs
    /// the import with a minute's bound and the outcome is logged; another
    /// bottle has no daemon, so the import is spawned and not waited for.
    /// ``SetupEnvironment`` writes the same two values at the next app start,
    /// so a failed import costs the choice a restart rather than losing it.
    private static func carryGPUToRegistry(_ identity: GPUIdentity, intoBottle bottle: URL) {
        guard GPUIdentity.writeWineD3DRegistry(identity, intoBottle: bottle) != nil,
              !registryHolds(identity, inBottle: bottle)
        else { return }
        let program = ["regedit", "/S", GPUIdentity.wineD3DRegistryWindowsPath]
        guard bottle.standardizedFileURL.path == SteamBottle.root.standardizedFileURL.path else {
            spawn(program, inBottle: bottle)
            return
        }
        Task.detached(name: "Carry the GPU choice to the registry") {
            let result = await ClientLifecycle.runSupervisedInBottle(program, timeout: .seconds(60))
            ClientLifecycle.log(result.status == 0
                ? "the GPU choice reached the bottle's registry"
                : "regedit of the GPU choice ended with status \(result.status.map(String.init) ?? "killed")")
        }
    }

    private static func spawn(_ program: [String], inBottle bottle: URL) {
        let invocation = Engine.active.wineInvocation(
            bottle: bottle.lastPathComponent, wait: .children, program: program,
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

    /// Whether `user.reg` already holds this choice (the Apple chip is the
    /// absence of both values), so a right bottle pays no spawn.
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

    /// Apple-documented knobs a Steam bottle wants on: `ROSETTA_ADVERTISE_AVX`
    /// (titles that see no AVX refuse to start) and `D3DM_ENABLE_METALFX`
    /// (D3DMetal answers DLSS with MetalFX on macOS 26).
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

    /// The `"NAME" = "value"` pairs of `[EnvironmentVariables]`, skipping
    /// `;` comments.
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

    /// Replaces, appends or removes (`nil`) one variable in
    /// `[EnvironmentVariables]`, leaving every other byte alone, since
    /// CrossOver's own tools rewrite this file.
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
        // After the last real assignment, above CrossOver's commented-out
        // examples at the section's end.
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
            .flatMap(Renderer.init(rawValue:))
            ?? unchosenManagedRenderer(
                toolkitInstalled: D3DMetalInstaller.active(inEngine: D3DMetalInstaller.store) != nil,
            )
        let msync = defaults.object(forKey: msyncKey) as? Bool ?? true
        let gpu = defaults.string(forKey: gpuKey).flatMap(GPUIdentity.init(rawValue:))
        return Selection(renderer: renderer, msync: msync, gpu: gpu ?? defaultGPU)
    }

    /// An unchosen managed renderer: ``defaultRenderer`` once a D3DMetal
    /// toolkit is installed, DXMT until then.
    static func unchosenManagedRenderer(toolkitInstalled: Bool) -> Renderer {
        toolkitInstalled ? defaultRenderer : .dxmt
    }

    static func setManagedSelection(_ selection: Selection) {
        let defaults = Preferences.shared
        defaults.set(selection.renderer.rawValue, forKey: rendererKey)
        defaults.set(selection.msync, forKey: msyncKey)
        defaults.set(selection.gpu.rawValue, forKey: gpuKey)
        GPUIdentity.writeDXVKConfig(selection.gpu, intoBottle: SteamBottle.root)
        carryGPUToRegistry(selection.gpu, intoBottle: SteamBottle.root)
        // The renderer is part of engine resolution.
        Engine.refreshResolution()
    }

    private struct GraphicsError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
