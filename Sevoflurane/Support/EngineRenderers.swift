import Foundation

/// Puts a managed engine's renderer DLLs where Wine will actually load them:
/// over the canonical builtins in `lib/wine/x86_64-windows`.
///
/// The payloads (DXMT's "builtin" release, DXVK-macOS "builtin", GPTk's
/// D3DMetal) are winelib builds carrying Wine's builtin signature — and Wine
/// resolves a builtin DLL to its canonical tree copy no matter what sits in
/// `system32`. Staging them there was measured to load Wine's own vkd3d
/// d3d12 with D3DMetal fully installed ("DirectX 12 is not supported",
/// 2026-09-01). So activation swaps the canonical copies instead, keeping
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
/// the two releases do not number those alike: 4.0b2's dylib under 3.0's
/// DLLs took Steam's client down 14 s into every boot, silently, where each
/// version whole boots healthy (measured 2026-09-03).
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
            toolkit: D3DMetalInstaller.active(inEngine: engine),
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
        let canonical = engine.appendingPathComponent("wine/lib/wine/x86_64-windows")
        let originals = engine.appendingPathComponent("wine/lib/wine/x86_64-windows-original")
        guard manager.fileExists(atPath: canonical.path) else { return [] }

        let payloads = payloadFiles(engine: engine)
        disownPayloads(in: originals, matching: payloads)
        restoreOriginals(into: canonical, from: originals)
        removeStrays(from: canonical, keptIn: originals, matching: payloads)

        if renderer == .d3dmetal, let toolkit,
           !D3DMetalInstaller.isPlaced(toolkit, inEngine: engine) {
            do {
                try D3DMetalInstaller.place(toolkit, inEngine: engine)
            } catch {
                SetupLog.log("D3DMetal \(toolkit.version) could not enter the Wine tree: \(error)")
            }
        }

        guard let source = libraries(for: renderer, engine: engine, toolkit: toolkit),
              let dlls = try? manager.contentsOfDirectory(
                  at: source, includingPropertiesForKeys: nil,
              ).filter({ $0.pathExtension.lowercased() == "dll" })
        else { return [] }

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
        ensureLoaderFiles(canonical: canonical, engine: engine, bottle: bottle)
        return staged
    }

    /// Every renderer DLL any installed payload could supply, by name.
    ///
    /// A file is "stock" only if it is not one of these: the tree is the
    /// place renderers overwrite, so a payload copy sitting there is the
    /// last activation's work, never Wine's own.
    private static func payloadFiles(engine: URL) -> [String: [URL]] {
        let manager = FileManager.default
        var files: [String: [URL]] = [:]
        for payload in payloadDirectories(engine: engine) {
            let dlls = (try? manager.contentsOfDirectory(
                at: payload, includingPropertiesForKeys: nil,
            ))?.filter { $0.pathExtension.lowercased() == "dll" } ?? []
            for dll in dlls { files[dll.lastPathComponent, default: []].append(dll) }
        }
        return files
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

    /// Guarantees every renderer DLL has a file in the bottle's `system32`.
    ///
    /// Wine loads a builtin only when a file of that name exists there
    /// (`find_builtin_without_file` refuses outside prefix bootstrap), and
    /// resolves any Wine-signed file it finds to the canonical tree copy — so
    /// the file's job is purely to exist, and the tree's own copy fills it.
    /// Without this, a game importing dxgi.dll dies at load with
    /// STATUS_DLL_NOT_FOUND (0xC0000135) before drawing anything.
    private static func ensureLoaderFiles(canonical: URL, engine: URL, bottle: URL) {
        let manager = FileManager.default
        let system32 = bottle.appendingPathComponent("drive_c/windows/system32")
        guard manager.fileExists(atPath: system32.path) else { return }
        var names = Set<String>()
        for payload in payloadDirectories(engine: engine) {
            let dlls = (try? manager.contentsOfDirectory(
                at: payload, includingPropertiesForKeys: nil,
            ))?.filter { $0.pathExtension.lowercased() == "dll" } ?? []
            names.formUnion(dlls.map(\.lastPathComponent))
        }
        for name in names {
            let target = system32.appendingPathComponent(name)
            let source = canonical.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else {
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

    private static func isGPTkFlavor(_ engine: URL) -> Bool {
        let info = engine.appendingPathComponent("engine-info.json")
        guard let data = try? Data(contentsOf: info),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return object["flavor"] as? String == "gptk"
    }

    private static func payloadDirectories(engine: URL) -> [URL] {
        var directories = [
            engine.appendingPathComponent("dxmt"),
            engine.appendingPathComponent("dxvk"),
        ]
        for toolkit in D3DMetalInstaller.installed(inEngine: engine) {
            directories.append(D3DMetalInstaller.windowsLibraries(of: toolkit))
        }
        return directories
    }

    /// Where a renderer's Windows DLLs live inside a managed engine.
    /// `Tools/package-engine.sh` builds `dxmt/` and `dxvk/`; D3DMetal's are
    /// the picked toolkit's own, the pair to the `libd3dshared` its macOS
    /// half put in the tree.
    private static func libraries(
        for renderer: Renderer, engine: URL, toolkit: D3DMetalInstaller.Installed?,
    ) -> URL? {
        switch renderer {
        case .dxmt: engine.appendingPathComponent("dxmt")
        case .dxvk: engine.appendingPathComponent("dxvk")
        case .d3dmetal: toolkit.map(D3DMetalInstaller.windowsLibraries)
        case .auto, .wined3d: nil
        }
    }
}
