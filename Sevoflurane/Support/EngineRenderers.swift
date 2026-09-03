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
/// D3DMetal always stages **3.0's** PE DLLs regardless of which libd3dshared
/// version is active. 4.0b2's PE DLLs crash Wine processes during early
/// init (SEH frame corruption from D3DMetal's thread creation). The 3.0
/// stubs are compatible with both 3.0 and 4.0b2 libd3dshared because the
/// PE side is a thin bridge into the unix-side dylib; the Win32DispatchInit
/// and other 4.0b2 features live entirely in libd3dshared.
nonisolated enum EngineRenderers {
    /// Asserts the selected renderer in `engine`'s Wine tree and makes sure
    /// `bottle`'s system32 holds a file for each renderer DLL. Answers what
    /// it placed. Idempotent; runs on every boot.
    @discardableResult
    static func stage(
        _ renderer: Renderer, engine: URL, bottle: URL,
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

        restoreOriginals(into: canonical, from: originals)

        guard let source = libraries(for: renderer, engine: engine),
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
               !manager.fileExists(atPath: keep.path) {
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
            guard !manager.fileExists(atPath: target.path),
                  manager.fileExists(atPath: source.path) else { continue }
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
    /// `Tools/package-engine.sh` builds `dxmt/` and `dxvk/`; D3DMetal uses
    /// 3.0's PE DLLs regardless of the active toolkit version (4.0b2's PE
    /// stubs crash Wine processes during early init).
    private static func libraries(for renderer: Renderer, engine: URL) -> URL? {
        switch renderer {
        case .dxmt: engine.appendingPathComponent("dxmt")
        case .dxvk: engine.appendingPathComponent("dxvk")
        case .d3dmetal:
            d3dmetalPELibraries(engine: engine)
        case .auto, .wined3d: nil
        }
    }

    /// Returns the 3.0 PE DLL directory when available, falling back to
    /// whatever the active toolkit provides.
    private static func d3dmetalPELibraries(engine: URL) -> URL? {
        let v3 = engine.appendingPathComponent("d3dmetal/3.0/lib/wine/x86_64-windows")
        if FileManager.default.fileExists(atPath: v3.path) { return v3 }
        return D3DMetalInstaller.active(inEngine: engine)
            .map(D3DMetalInstaller.windowsLibraries)
    }
}
