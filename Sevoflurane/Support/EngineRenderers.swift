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
nonisolated enum EngineRenderers {
    /// Asserts the selected renderer in `engine`'s Wine tree and clears the
    /// old system32 staging out of `bottle`. Answers what it placed.
    /// Idempotent; runs on every boot.
    @discardableResult
    static func stage(
        _ renderer: Renderer, engine: URL, bottle: URL,
    ) -> [String] {
        let manager = FileManager.default
        if isGPTkFlavor(engine) {
            // The GPTk engine's canonical tree is already D3DMetal (the
            // overlay is part of its install); the bottle only needs the
            // MetalFX bridge pair, which Apple's Read Me puts in system32.
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
        sweepStagedCopies(engine: engine, bottle: bottle)

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

    /// Removes the copies an earlier build staged into the bottle's
    /// system32 — Wine ignored them, but they'd shadow the truth in any
    /// audit. Only a byte-identical match to a payload file is removed;
    /// anything else in system32 is someone's own.
    private static func sweepStagedCopies(engine: URL, bottle: URL) {
        let manager = FileManager.default
        let system32 = bottle.appendingPathComponent("drive_c/windows/system32")
        for payload in payloadDirectories(engine: engine) {
            let dlls = (try? manager.contentsOfDirectory(
                at: payload, includingPropertiesForKeys: nil,
            ))?.filter { $0.pathExtension.lowercased() == "dll" } ?? []
            for dll in dlls {
                let staged = system32.appendingPathComponent(dll.lastPathComponent)
                guard manager.contentsEqual(atPath: staged.path, andPath: dll.path)
                else { continue }
                try? manager.removeItem(at: staged)
            }
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
    /// `Tools/package-engine.sh` builds `dxmt/` and `dxvk/`; D3DMetal is the
    /// user's own copy of Apple's toolkit, one directory per version.
    private static func libraries(for renderer: Renderer, engine: URL) -> URL? {
        switch renderer {
        case .dxmt: engine.appendingPathComponent("dxmt")
        case .dxvk: engine.appendingPathComponent("dxvk")
        case .d3dmetal:
            D3DMetalInstaller.active(inEngine: engine).map(D3DMetalInstaller.windowsLibraries)
        case .auto, .wined3d: nil
        }
    }
}
