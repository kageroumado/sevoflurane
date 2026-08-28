import Foundation

/// Puts a managed engine's renderer DLLs where Wine can load them.
///
/// `WINEDLLOVERRIDES=d3d11=n,b` asks for the *native* DLL first, and native
/// means a real Windows DLL inside the prefix. CrossOver stages its own; a
/// managed engine keeps them in the engine directory, so they are copied into
/// the prefix whenever the renderer is asserted — which is every boot, since
/// the pass is idempotent.
nonisolated enum EngineRenderers {
    /// Copies the selected renderer's DLLs into `bottle`'s system32, and
    /// answers what it staged. Wine's own translation needs nothing staged.
    @discardableResult
    static func stage(
        _ renderer: Renderer, engine: URL, bottle: URL,
    ) -> [String] {
        guard let source = libraries(for: renderer, engine: engine) else { return [] }
        let system32 = bottle.appendingPathComponent("drive_c/windows/system32")
        let manager = FileManager.default
        guard let dlls = try? manager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil,
        ).filter({ $0.pathExtension.lowercased() == "dll" }) else { return [] }
        var staged: [String] = []
        for dll in dlls {
            let target = system32.appendingPathComponent(dll.lastPathComponent)
            try? manager.removeItem(at: target)
            guard (try? manager.copyItem(at: dll, to: target)) != nil else { continue }
            staged.append(dll.lastPathComponent)
        }
        return staged
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
