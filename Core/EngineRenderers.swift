import Foundation

/// Puts a managed engine's renderer DLLs where Wine will actually load them:
/// over the canonical builtins in `lib/wine/x86_64-windows`, and over the
/// 32-bit ones in `lib/wine/i386-windows` for a payload that carries them.
///
/// The payloads (DXMT's "builtin" release, DXVK-macOS "builtin", GPTk's
/// D3DMetal) are winelib builds carrying Wine's builtin signature, and Wine
/// resolves a builtin DLL to its canonical tree copy whatever sits in
/// `system32`, so a payload staged only there loses to Wine's own (vkd3d's
/// d3d12 answers "DirectX 12 is not supported" with D3DMetal present).
/// Activation swaps the canonical copies instead, keeping each displaced
/// original beside the tree for the swap back.
///
/// D3DMetal's two halves — `libd3dshared.dylib` and the framework in
/// `wine/lib/external`, and the toolkit's PE DLLs — are both the picked
/// version, re-asserted on every boot. Never cross them: each PE call carries
/// a function index into the dylib, numbered differently per release.
nonisolated enum EngineRenderers {
    /// Asserts the selected renderer in `engine`'s tree and the loader files
    /// in `bottle`; answers what it placed. Idempotent; runs on every boot.
    @discardableResult
    static func stage(
        _ renderer: Renderer, engine: URL, bottle: URL,
    ) -> [String] {
        stage(
            renderer, engine: engine, bottle: bottle,
            toolkit: D3DMetalInstaller.active(inEngine: D3DMetalInstaller.store),
        )
    }

    /// The preference-free entry point for tests.
    @discardableResult
    static func stage(
        _ renderer: Renderer, engine: URL, bottle: URL,
        toolkit: D3DMetalInstaller.Installed?,
    ) -> [String] {
        let manager = FileManager.default
        if isGPTkFlavor(engine) {
            guard renderer == .d3dmetal else { return [] }
            return stageGPTkCompanions(engine: engine, bottle: bottle)
        }
        guard manager.fileExists(atPath: Architecture.x86_64.tree(in: engine).path)
        else { return [] }

        let payloads = payloadFiles(engine: engine)
        if renderer == .d3dmetal, let toolkit {
            // Patch the store's copy: the tree is kept equal to it.
            switch D3DMetalPatches.apply(to: toolkit) {
            case .unchanged: break
            case let .patched(names):
                SetupLog.log("D3DMetal \(toolkit.version) patched: \(names.joined(separator: ", "))")
            case let .failed(reason):
                SetupLog.log(reason)
            }
        }
        if renderer == .d3dmetal, let toolkit,
           !D3DMetalInstaller.isPlaced(toolkit, inEngine: engine) {
            do {
                try D3DMetalInstaller.place(toolkit, inEngine: engine)
            } catch {
                SetupLog.log("D3DMetal \(toolkit.version) could not enter the Wine tree: \(error)")
            }
        }

        var staged: [String] = []
        for architecture in Architecture.all {
            let canonical = architecture.tree(in: engine)
            let originals = architecture.originals(in: engine)
            guard manager.fileExists(atPath: canonical.path) else { continue }

            disownPayloads(in: originals, matching: payloads)
            removeExportAliases(from: canonical, matching: payloads)
            restoreOriginals(into: canonical, from: originals)
            removeStrays(from: canonical, keptIn: originals, matching: payloads)

            let source = libraries(
                for: renderer, engine: engine, toolkit: toolkit,
                architecture: architecture,
            )
            let dlls = source.flatMap {
                try? manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension.lowercased() == "dll" }
            } ?? []

            staged += place(dlls, into: canonical, keepingOriginalsIn: originals, payloads: payloads)
            if renderer == .d3dmetal, architecture.modules == Architecture.x86_64.modules {
                staged += placeExportAliases(in: canonical, engine: engine)
            }
            // Every architecture, payload or not: one that got no DLLs still
            // holds the last renderer's loader files.
            ensureLoaderFiles(
                canonical: canonical, engine: engine, bottle: bottle,
                architecture: architecture,
            )
        }
        writeProvenance(renderer: renderer, toolkit: toolkit, staged: staged, engine: engine)
        return staged
    }

    /// Copies a GPTk-flavored engine's NVIDIA libraries into `system32`.
    private static func stageGPTkCompanions(engine: URL, bottle: URL) -> [String] {
        let manager = FileManager.default
        let source = engine.appendingPathComponent("wine/lib/wine/x86_64-windows")
        let system32 = bottle.appendingPathComponent("drive_c/windows/system32")
        var staged: [String] = []
        for name in ["nvngx.dll", "nvapi64.dll"] {
            let dll = source.appendingPathComponent(name)
            guard manager.fileExists(atPath: dll.path) else { continue }
            let target = system32.appendingPathComponent(name)
            try? manager.removeItem(at: target)
            guard (try? manager.copyItem(at: dll, to: target)) != nil else { continue }
            staged.append(name)
        }
        return staged
    }

    /// Copies a renderer's DLLs over the engine's own, setting each original
    /// aside the first time it is covered.
    private static func place(
        _ dlls: [URL], into canonical: URL, keepingOriginalsIn originals: URL, payloads: [String: [URL]],
    ) -> [String] {
        let manager = FileManager.default
        var staged: [String] = []
        for dll in dlls {
            let name = dll.lastPathComponent
            let target = canonical.appendingPathComponent(name)
            let keep = originals.appendingPathComponent(name)
            if manager.fileExists(atPath: target.path),
               !manager.fileExists(atPath: keep.path),
               !isPayload(target, among: payloads) {
                try? manager.createDirectory(
                    at: originals, withIntermediateDirectories: true,
                )
                try? manager.copyItem(at: target, to: keep)
            }
            try? manager.removeItem(at: target)
            guard (try? manager.copyItem(at: dll, to: target)) != nil else { continue }
            staged.append(name)
        }
        return staged
    }

    /// Apple's NVIDIA stubs export as `nvapi.dll` and `nvngx.dll`, and Wine
    /// binds a builtin's unix half by export name (`find_builtin_dll`'s
    /// `exp_name`). Without a PE and `.so` under that name NvAPI never
    /// initializes and DLSS stays off (Subnautica 2).
    private static let exportAliases: [(file: String, export: String)] = [
        ("nvapi64.dll", "nvapi.dll"),
        ("nvngx-on-metalfx.dll", "nvngx.dll"),
    ]

    /// What every D3DMetal unix half is: a symlink to the bridge, relative to
    /// `x86_64-unix`.
    private static let bridgeLink = "../../external/libd3dshared.dylib"

    /// Copies each stub under its export name, with its unix half beside it.
    private static func placeExportAliases(in canonical: URL, engine: URL) -> [String] {
        let manager = FileManager.default
        let unix = engine.appendingPathComponent("wine/lib/wine/x86_64-unix")
        var staged: [String] = []
        for alias in exportAliases {
            let source = canonical.appendingPathComponent(alias.file)
            guard manager.fileExists(atPath: source.path) else { continue }
            let target = canonical.appendingPathComponent(alias.export)
            try? manager.removeItem(at: target)
            guard (try? manager.copyItem(at: source, to: target)) != nil else { continue }
            let so = unix.appendingPathComponent(
                URL(fileURLWithPath: alias.export).deletingPathExtension().lastPathComponent + ".so",
            )
            if (try? manager.destinationOfSymbolicLink(atPath: so.path)) != bridgeLink {
                try? manager.removeItem(at: so)
                try? manager.createSymbolicLink(atPath: so.path, withDestinationPath: bridgeLink)
            }
            staged.append(alias.export)
        }
        return staged
    }

    /// Clears the last staging's aliases, leaving payload files to the
    /// payload bookkeeping.
    private static func removeExportAliases(from canonical: URL, matching payloads: [String: [URL]]) {
        let manager = FileManager.default
        for alias in exportAliases {
            let file = canonical.appendingPathComponent(alias.export)
            guard manager.fileExists(atPath: file.path), !isPayload(file, among: payloads) else { continue }
            try? manager.removeItem(at: file)
        }
    }

    // MARK: - One game's own renderer

    /// Whether GPTk's DLLs load from a `WINEDLLPATH_PREPEND` directory:
    /// `find_builtin_dll` demands Wine's builtin signature there, and the
    /// toolkit's `d3d12.dll` is untested on that route. The probe is
    /// `dxgiprobe12.exe` under a per-exe D3DMetal env file, judged by the
    /// adapter string.
    static let gptkLoadsFromPrependPath = false

    /// Whether one game can get this renderer through a
    /// ``prependDirectory(for:engine:)``.
    static func supportsPerGame(_ renderer: Renderer) -> Bool {
        switch renderer {
        case .dxmt, .dxvk: true
        case .d3dmetal: gptkLoadsFromPrependPath
        case .auto, .wined3d: false
        }
    }

    /// `<engine>/renderers/<name>`, the directory a game's
    /// `WINEDLLPATH_PREPEND` names, holding `x86_64-windows` and
    /// `i386-windows` symlinks to the payload: the loader appends the machine
    /// directory to each dll path entry (`set_dll_path`). Nil without a
    /// payload.
    static func prependDirectory(for renderer: Renderer, engine: URL) -> URL? {
        prependDirectory(
            for: renderer, engine: engine,
            toolkit: D3DMetalInstaller.active(inEngine: D3DMetalInstaller.store),
        )
    }

    /// The preference-free entry point for tests.
    static func prependDirectory(
        for renderer: Renderer, engine: URL, toolkit: D3DMetalInstaller.Installed?,
    ) -> URL? {
        guard supportsPerGame(renderer) else { return nil }
        let manager = FileManager.default
        let directory = engine.appendingPathComponent("renderers/\(renderer.rawValue)")
        var linked = false
        for architecture in Architecture.all {
            guard let source = libraries(
                for: renderer, engine: engine, toolkit: toolkit, architecture: architecture,
            ) else { continue }
            let link = directory.appendingPathComponent(architecture.modules)
            let destination = source.standardizedFileURL.path
            if (try? manager.destinationOfSymbolicLink(atPath: link.path)) == destination {
                linked = true
                continue
            }
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? manager.removeItem(at: link)
            guard (try? manager.createSymbolicLink(
                atPath: link.path, withDestinationPath: destination,
            )) != nil else { continue }
            linked = true
        }
        guard linked else { return nil }
        linkUnixHalves(in: directory, engine: engine)
        return directory
    }

    /// Links `x86_64-unix` to the engine's unix modules: Wine loads a unix
    /// half from beside the DLL (`load_builtin_unixlib`), and before Dormison
    /// b2 a game dies at load without `winemetal.so` here.
    private static func linkUnixHalves(in directory: URL, engine: URL) {
        let manager = FileManager.default
        let link = directory.appendingPathComponent("x86_64-unix")
        let destination = engine.appendingPathComponent("wine/lib/wine/x86_64-unix").standardizedFileURL.path
        guard (try? manager.destinationOfSymbolicLink(atPath: link.path)) != destination else { return }
        try? manager.removeItem(at: link)
        try? manager.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }

    /// Every DLL `directory` supplies, forced builtin.
    ///
    /// The bottle-wide override asks for the bottle renderer's copies in
    /// `system32` as native, so without this a game with a renderer of its own
    /// would import the bottle's file. Builtin resolution searches the dll
    /// path instead, where the prepend directory sits first.
    static func perGameDLLOverrides(in directory: URL) -> String? {
        // `contentsOfDirectory(at:)` answers nil for a symlink URL.
        let modules = directory
            .appendingPathComponent(Architecture.x86_64.modules)
            .resolvingSymlinksInPath()
        let names = ((try? FileManager.default.contentsOfDirectory(
            at: modules, includingPropertiesForKeys: nil,
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "dll" }
            .map { $0.deletingPathExtension().lastPathComponent.lowercased() }
        guard !names.isEmpty else { return nil }
        return names.sorted().joined(separator: ",") + "=b"
    }

    // MARK: - Provenance

    /// The `key=value` file `winemac.drv` prints at process start: renderer,
    /// payload version and each staged DLL's sha256. Written whole each time,
    /// since a stale line is worse than the `unknown` a missing one prints.
    static let provenanceFile = "renderer-hashes"

    private static func writeProvenance(
        renderer: Renderer, toolkit: D3DMetalInstaller.Installed?, staged: [String], engine: URL,
    ) {
        var lines = [
            "# written by Sevoflurane at renderer staging",
            "renderer=\(renderer.rawValue)",
        ]
        if let version = payloadVersion(of: renderer, engine: engine, toolkit: toolkit) {
            lines.append("toolkit=\(version)")
        }
        let canonical = Architecture.x86_64.tree(in: engine)
        for name in Set(staged).sorted() {
            let file = canonical.appendingPathComponent(name)
            guard let digest = try? FileDigest.sha256(of: file) else { continue }
            lines.append("\(file.deletingPathExtension().lastPathComponent.lowercased())=\(digest)")
        }
        let contents = lines.joined(separator: "\n") + "\n"
        try? contents.write(
            to: engine.appendingPathComponent(provenanceFile),
            atomically: true, encoding: .utf8,
        )
    }

    /// The staged payload's version: the picked or chosen one, else the
    /// engine's own from the asset URL in `engine-info.json`.
    private static func payloadVersion(
        of renderer: Renderer, engine: URL, toolkit: D3DMetalInstaller.Installed?,
    ) -> String? {
        switch renderer {
        case .d3dmetal:
            return toolkit?.version
        case .dxmt, .dxvk:
            let component: RendererVersions.Component = renderer == .dxmt ? .dxmt : .dxvk
            if let chosen = RendererVersions.chosen(component) { return chosen }
            guard let asset = engineInfo(engine)[component.rawValue] as? String,
                  let name = URL(string: asset)?.lastPathComponent
            else { return nil }
            return component.version(from: name)
        case .auto, .wined3d:
            return nil
        }
    }

    /// A module tree and its prefix directory. The 32-bit half is DLLs only:
    /// they reach Metal through wow64 calls into the 64-bit `winemetal.so`.
    private struct Architecture {
        let modules: String
        /// The subdirectory of a payload; `nil` for x86_64.
        let payload: String?
        let system: String

        static let x86_64 = Architecture(
            modules: "x86_64-windows", payload: nil, system: "system32",
        )
        static let i386 = Architecture(
            modules: "i386-windows", payload: "i386-windows", system: "syswow64",
        )
        static let all = [x86_64, i386]

        func tree(in engine: URL) -> URL {
            engine.appendingPathComponent("wine/lib/wine/\(modules)")
        }

        func originals(in engine: URL) -> URL {
            engine.appendingPathComponent("wine/lib/wine/\(modules)-original")
        }

        func libraries(in payloadDirectory: URL) -> URL {
            payload.map(payloadDirectory.appendingPathComponent) ?? payloadDirectory
        }
    }

    /// Every renderer DLL any installed payload could supply, by name; a tree
    /// file matching one is a staging's work, never Wine's own.
    private static func payloadFiles(engine: URL) -> [String: [URL]] {
        var files: [String: [URL]] = [:]
        for architecture in Architecture.all {
            for dll in payloadDLLs(engine: engine, architecture: architecture) {
                files[dll.lastPathComponent, default: []].append(dll)
            }
        }
        return files
    }

    /// Every DLL one architecture's payloads offer; `isPayload` compares
    /// contents, so a name shared across architectures matches its own only.
    private static func payloadDLLs(engine: URL, architecture: Architecture) -> [URL] {
        let manager = FileManager.default
        return payloadDirectories(engine: engine).flatMap { payload in
            (try? manager.contentsOfDirectory(
                at: architecture.libraries(in: payload), includingPropertiesForKeys: nil,
            ))?.filter { $0.pathExtension.lowercased() == "dll" } ?? []
        }
    }

    private static func isPayload(_ file: URL, among payloads: [String: [URL]]) -> Bool {
        let manager = FileManager.default
        return payloads[file.lastPathComponent]?.contains {
            manager.contentsEqual(atPath: file.path, andPath: $0.path)
        } ?? false
    }

    /// Drops a kept "original" that is really a payload, recorded from a tree
    /// that already held one; restoring it would cross releases.
    private static func disownPayloads(in originals: URL, matching payloads: [String: [URL]]) {
        let manager = FileManager.default
        let kept = (try? manager.contentsOfDirectory(
            at: originals, includingPropertiesForKeys: nil,
        )) ?? []
        for original in kept where isPayload(original, among: payloads) {
            try? manager.removeItem(at: original)
            SetupLog.log("\(original.lastPathComponent) was a renderer's own DLL, "
                + "not Wine's — dropped from the kept originals")
        }
    }

    /// Clears a payload file with no kept original, left by the previous
    /// staging. A stock builtin also has no original yet and must stay for
    /// the next staging to capture.
    private static func removeStrays(
        from canonical: URL, keptIn originals: URL, matching payloads: [String: [URL]],
    ) {
        let manager = FileManager.default
        for name in payloads.keys {
            let file = canonical.appendingPathComponent(name)
            guard !manager.fileExists(atPath: originals.appendingPathComponent(name).path),
                  isPayload(file, among: payloads) else { continue }
            try? manager.removeItem(at: file)
        }
    }

    /// Puts Wine's own builtins back, so each activation starts from stock.
    private static func restoreOriginals(into canonical: URL, from originals: URL) {
        let manager = FileManager.default
        let kept = (try? manager.contentsOfDirectory(
            at: originals, includingPropertiesForKeys: nil,
        )) ?? []
        for original in kept {
            let target = canonical.appendingPathComponent(original.lastPathComponent)
            try? manager.removeItem(at: target)
            try? manager.copyItem(at: original, to: target)
        }
    }

    /// The bottle's loader files for another prefix on the same tree (the
    /// companion prefix, ``SteamParent``).
    static func ensureLoaderFiles(engine: URL, prefix: URL) {
        guard !isGPTkFlavor(engine) else { return }
        for architecture in Architecture.all {
            let canonical = architecture.tree(in: engine)
            guard FileManager.default.fileExists(atPath: canonical.path) else { continue }
            ensureLoaderFiles(
                canonical: canonical, engine: engine, bottle: prefix, architecture: architecture,
            )
        }
    }

    /// Gives every renderer DLL a file in `system32` or `syswow64`: Wine
    /// loads a builtin only when a file of that name exists there
    /// (`find_builtin_without_file`), then resolves it to the tree copy.
    /// Without it a game importing dxgi.dll dies with STATUS_DLL_NOT_FOUND
    /// (0xC0000135).
    private static func ensureLoaderFiles(
        canonical: URL, engine: URL, bottle: URL, architecture: Architecture,
    ) {
        let manager = FileManager.default
        let system32 = bottle.appendingPathComponent(
            "drive_c/windows/\(architecture.system)",
        )
        guard manager.fileExists(atPath: system32.path) else { return }
        let payloads = payloadDLLs(engine: engine, architecture: architecture)
        var names = Set(payloads.map(\.lastPathComponent))
        names.formUnion(exportAliases.map(\.export))
        for name in names {
            let target = system32.appendingPathComponent(name)
            let source = canonical.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else {
                if loaderOnlyDLLs.contains(name.lowercased()),
                   let payload = payloads.first(where: { $0.lastPathComponent == name }) {
                    // DXMT's dxgi.dll imports winemetal.dll, which a pinned
                    // game can resolve only through system32.
                    if !manager.contentsEqual(atPath: payload.path, andPath: target.path) {
                        try? manager.removeItem(at: target)
                        try? manager.copyItem(at: payload, to: target)
                    }
                    continue
                }
                // A file the tree lacks is the previous renderer's.
                try? manager.removeItem(at: target)
                continue
            }
            guard !manager.fileExists(atPath: target.path) else { continue }
            try? manager.copyItem(at: source, to: target)
        }
    }

    /// Payload DLLs only other payload DLLs import, lowercased; the tree
    /// lacks them under another renderer, so a pinned game would die with
    /// `winemetal.dll (which is needed by …\system32\dxgi.dll) not found`.
    static let loaderOnlyDLLs: Set<String> = ["winemetal.dll"]

    private static func isGPTkFlavor(_ engine: URL) -> Bool {
        engineInfo(engine)["flavor"] as? String == "gptk"
    }

    /// The engine's own description of itself, empty for a tree without one.
    private static func engineInfo(_ engine: URL) -> [String: Any] {
        let info = engine.appendingPathComponent("engine-info.json")
        guard let data = try? Data(contentsOf: info),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func payloadDirectories(engine: URL) -> [URL] {
        var directories = [
            engine.appendingPathComponent("dxmt"),
            engine.appendingPathComponent("dxvk"),
        ]
        // Every added version, so a file staged from one stays recognized.
        directories += RendererVersions.allDirectories()
        for toolkit in D3DMetalInstaller.installed(inEngine: D3DMetalInstaller.store)
            + D3DMetalInstaller.installed(inEngine: engine) {
            directories.append(D3DMetalInstaller.windowsLibraries(of: toolkit))
        }
        return directories
    }

    /// Where a renderer's Windows DLLs for `architecture` live; nil keeps
    /// Wine's own builtins for that architecture.
    private static func libraries(
        for renderer: Renderer, engine: URL, toolkit: D3DMetalInstaller.Installed?,
        architecture: Architecture,
    ) -> URL? {
        let payload: URL? = switch renderer {
        case .dxmt: RendererVersions.directory(.dxmt, engine: engine)
        case .dxvk: RendererVersions.directory(.dxvk, engine: engine)
        case .d3dmetal: toolkit.map(D3DMetalInstaller.windowsLibraries)
        case .auto, .wined3d: nil
        }
        guard let directory = payload.map({ architecture.libraries(in: $0) }),
              FileManager.default.fileExists(atPath: directory.path)
        else { return nil }
        return directory
    }
}
