import Foundation

/// Puts a managed engine's renderer DLLs where Wine will actually load them:
/// over the canonical builtins in `lib/wine/x86_64-windows`, and over the
/// 32-bit ones in `lib/wine/i386-windows` for a payload that carries them.
///
/// The payloads (DXMT's "builtin" release, DXVK-macOS "builtin", GPTk's
/// D3DMetal) are winelib builds carrying Wine's builtin signature — and Wine
/// resolves a builtin DLL to its canonical tree copy no matter what sits in
/// `system32`, so a payload staged only there loses to Wine's own (vkd3d's
/// d3d12 answers "DirectX 12 is not supported" with D3DMetal present). So
/// activation swaps the canonical copies instead, keeping
/// each displaced original beside the tree for the swap back.
///
/// D3DMetal is two halves and both are the picked version. The macOS half —
/// `libd3dshared.dylib` and the framework — goes into `wine/lib/external`
/// where the `.so` stubs resolve; the Windows half is that same toolkit's PE
/// DLLs. Both are re-asserted on every boot, because the picker only records
/// a choice and a tree holding another version runs that version whatever
/// was picked.
///
/// The halves are one release and are never crossed. A PE DLL is a thin
/// bridge whose calls carry a function index into the unix-side dylib, and
/// the releases do not number those alike, so a crossed pair of D3DMetal
/// halves calls the wrong functions.
nonisolated enum EngineRenderers {
    /// Asserts the selected renderer in `engine`'s Wine tree and makes sure
    /// `bottle`'s system32 holds a file for each renderer DLL. Answers what
    /// it placed. Idempotent; runs on every boot.
    @discardableResult
    static func stage(
        _ renderer: Renderer, engine: URL, bottle: URL,
    ) -> [String] {
        stage(
            renderer, engine: engine, bottle: bottle,
            toolkit: D3DMetalInstaller.active(inEngine: D3DMetalInstaller.store),
        )
    }

    /// `toolkit` is the D3DMetal version to hold in the tree; the
    /// preference-free entry point for tests.
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
            // Every architecture, whether this renderer has a payload for it
            // or not: an architecture that gets no DLLs is exactly the one
            // whose prefix still holds the last renderer's loader files, and
            // `auto` and `wined3d` have no payload for either.
            ensureLoaderFiles(
                canonical: canonical, engine: engine, bottle: bottle,
                architecture: architecture,
            )
        }
        writeProvenance(renderer: renderer, toolkit: toolkit, staged: staged, engine: engine)
        return staged
    }

    /// Copies the NVIDIA libraries a GPTk-flavored engine ships into the
    /// bottle's `system32`, and names the ones that landed.
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

    /// Copies a renderer's DLLs over the engine's own in `canonical`, setting
    /// each engine DLL aside in `originals` the first time it is covered, and
    /// names the ones that landed.
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

    // MARK: - One game's own renderer

    /// Whether GPTk's DLLs load from a `WINEDLLPATH_PREPEND` directory the way
    /// DXMT's and DXVK's builtin-flavored ones do — `find_builtin_dll` demands
    /// Wine's builtin signature of anything it takes off the dll path
    /// (`ntdll/unix/loader.c`), and the toolkit's `d3d12.dll` has not been put
    /// through that route yet. The probe is `dxgiprobe12.exe` under a per-exe
    /// D3DMetal env file while the bottle runs another renderer, judged by the
    /// adapter string.
    static let gptkLoadsFromPrependPath = false

    /// Whether this renderer can answer one game alone, through a
    /// ``prependDirectory(for:engine:)`` in that game's env file, rather than
    /// the whole bottle through the staged tree.
    static func supportsPerGame(_ renderer: Renderer) -> Bool {
        switch renderer {
        case .dxmt, .dxvk: true
        case .d3dmetal: gptkLoadsFromPrependPath
        case .auto, .wined3d: false
        }
    }

    /// The directory a game's `WINEDLLPATH_PREPEND` names to load `renderer`
    /// while the rest of the bottle loads the staged one:
    /// `<engine>/renderers/<name>`, holding a `x86_64-windows` symlink — and
    /// an `i386-windows` one where the payload has 32-bit builds — to the
    /// payload directory.
    ///
    /// The loader appends the machine directory to every dll path entry and
    /// searches the prepend entries ahead of the tree (`set_dll_path`), so the
    /// link's name is what makes the payload reachable under its own path.
    /// Answers nil for a renderer this engine has no payload for.
    static func prependDirectory(for renderer: Renderer, engine: URL) -> URL? {
        prependDirectory(
            for: renderer, engine: engine,
            toolkit: D3DMetalInstaller.active(inEngine: D3DMetalInstaller.store),
        )
    }

    /// `toolkit` is the D3DMetal version to link; the preference-free entry
    /// point for tests.
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
        return linked ? directory : nil
    }

    /// The `WINEDLLOVERRIDES` a game loading a renderer from `directory`
    /// carries: every DLL that directory supplies, forced builtin.
    ///
    /// The bottle's own renderer has a copy of its DLLs in the prefix's
    /// `system32`, and the bottle-wide override asks for those as native — so
    /// without this a game with a renderer of its own would import the
    /// bottle's file under its own name. Builtin resolution searches the dll
    /// path instead, where the prepend directory sits first.
    static func perGameDLLOverrides(in directory: URL) -> String? {
        // Resolved, because the machine directory is a symlink to the payload
        // and `contentsOfDirectory(at:)` answers nil for a symlink URL rather
        // than following it.
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

    /// The file `winemac.drv` reads at every process start to print which
    /// renderer answered and which build of it: `key=value` lines carrying
    /// the renderer, the payload version, and the sha256 of each DLL this
    /// staging put in the tree.
    ///
    /// Written here because this is the only place that knows what was
    /// staged, and written whole each time — an engine that finds no file, or
    /// no key, prints `unknown`, so a stale line would be worse than none.
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

    /// The version of the payload this renderer is staged from: the picked
    /// toolkit for D3DMetal, the chosen version for DXMT and DXVK, and
    /// otherwise the one the engine shipped, read from the asset URL in its
    /// own `engine-info.json`.
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

    /// A module tree in the engine and the prefix directory whose files let it
    /// load. A 32-bit game's `d3d11` is its own PE, found in `i386-windows`
    /// and `syswow64`, and reaches Metal through wow64 unix calls into the
    /// same 64-bit `winemetal.so` — so the 32-bit half is DLLs only.
    private struct Architecture {
        let modules: String
        /// Where inside a payload directory this architecture's DLLs sit;
        /// `nil` for the x86_64 set, which is the payload directory itself.
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

    /// Every renderer DLL any installed payload could supply, by name.
    ///
    /// A file is "stock" only if it is not one of these: the tree is the
    /// place renderers overwrite, so a payload copy sitting there is the
    /// last activation's work, never Wine's own.
    private static func payloadFiles(engine: URL) -> [String: [URL]] {
        var files: [String: [URL]] = [:]
        for architecture in Architecture.all {
            for dll in payloadDLLs(engine: engine, architecture: architecture) {
                files[dll.lastPathComponent, default: []].append(dll)
            }
        }
        return files
    }

    /// Every DLL one architecture's payloads offer. The two architectures
    /// share names, and a file only ever matches its own: `isPayload`
    /// compares contents, so `d3d11.dll` in the 32-bit tree can equal the
    /// 32-bit payload alone.
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

    /// Drops a kept "original" that is really a renderer's own DLL.
    ///
    /// The tree is only read for an original the first time a name is
    /// staged, and a payload that reached it before that — an activation
    /// under an older build, a hand-swapped tree — was recorded as Wine's.
    /// Restoring it puts one release's DLL under another's, which is the
    /// thing versions are kept apart to prevent.
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

    /// Clears a renderer DLL that Wine never shipped and this activation
    /// does not supply — a name the previous renderer or toolkit version
    /// staged, which has no original to restore over it.
    ///
    /// Only a file that is itself a payload goes: a stock builtin no name
    /// has been staged over yet has no kept original either, and it is the
    /// very thing the next staging must capture.
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

    /// Puts Wine's own builtins back, so each activation starts from the
    /// stock tree rather than the previous renderer's leftovers.
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

    /// Guarantees every renderer DLL has a file in the bottle's system
    /// directory for `architecture` — `system32` for x86_64, `syswow64` for
    /// i386, which is what a 32-bit process sees as its own `system32`.
    ///
    /// Wine loads a builtin only when a file of that name exists there
    /// (`find_builtin_without_file` refuses outside prefix bootstrap), and
    /// resolves any Wine-signed file it finds to the canonical tree copy — so
    /// the file's job is purely to exist, and the tree's own copy fills it.
    /// Without this, a game importing dxgi.dll dies at load with
    /// STATUS_DLL_NOT_FOUND (0xC0000135) before drawing anything.
    private static func ensureLoaderFiles(
        canonical: URL, engine: URL, bottle: URL, architecture: Architecture,
    ) {
        let manager = FileManager.default
        let system32 = bottle.appendingPathComponent(
            "drive_c/windows/\(architecture.system)",
        )
        guard manager.fileExists(atPath: system32.path) else { return }
        let payloads = payloadDLLs(engine: engine, architecture: architecture)
        let names = Set(payloads.map(\.lastPathComponent))
        for name in names {
            let target = system32.appendingPathComponent(name)
            let source = canonical.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else {
                if loaderOnlyDLLs.contains(name.lowercased()),
                   let payload = payloads.first(where: { $0.lastPathComponent == name }) {
                    // Only another payload DLL imports this one, so a copy
                    // here cannot be mistaken for anything the bottle's own
                    // renderer loads, and a game pinned to that payload
                    // needs it: Wine resolves an import only through a file
                    // in system32, and DXMT's dxgi.dll imports winemetal.dll.
                    if !manager.contentsEqual(atPath: payload.path, andPath: target.path) {
                        try? manager.removeItem(at: target)
                        try? manager.copyItem(at: payload, to: target)
                    }
                    continue
                }
                // The tree no longer carries this one, so neither may the
                // prefix: a file left here is the previous renderer's, and
                // Wine would load it as the real thing.
                try? manager.removeItem(at: target)
                continue
            }
            guard !manager.fileExists(atPath: target.path) else { continue }
            try? manager.copyItem(at: source, to: target)
        }
    }

    /// Payload DLLs that only other payload DLLs import, lowercased. A
    /// per-game pin (`WINEDLLPATH_PREPEND`) reaches a payload's DLLs through
    /// the loader files in system32, and these have no counterpart in Wine
    /// or D3DMetal, so the tree never carries them while the bottle runs
    /// another renderer. Without a file the pinned game dies at load:
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
        // Every added version too, so a file staged from one of them is
        // still recognized as a payload after the choice moves on.
        directories += RendererVersions.allDirectories()
        // The store's versions, and any an engine still carries in its own d3dmetal/.
        for toolkit in D3DMetalInstaller.installed(inEngine: D3DMetalInstaller.store)
            + D3DMetalInstaller.installed(inEngine: engine) {
            directories.append(D3DMetalInstaller.windowsLibraries(of: toolkit))
        }
        return directories
    }

    /// Where a renderer's Windows DLLs for `architecture` live inside a
    /// managed engine. The engine's `package-engine.sh` places `dxmt/` and
    /// `dxvk/`; D3DMetal's are the picked toolkit's own, the pair to the
    /// `libd3dshared` its macOS half put in the tree. A renderer with no
    /// build for an architecture has no subdirectory there, and that
    /// architecture keeps Wine's own builtins.
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
