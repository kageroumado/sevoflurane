import CryptoKit
import Foundation

/// Builds the DX12 managed engine: Gcenx's game-porting-toolkit Wine — the
/// build Apple's own evaluation-environment Read Me points at — laid out as
/// an `Engines/` entry, with the user's D3DMetal libraries overlaid per
/// Apple's instructions (`ditto redist/lib/ .`, then the nvngx renames that
/// turn on the DLSS→MetalFX bridge).
///
/// GPTk's libraries are winelib builds against this Wine lineage; the
/// wine-staging engine refuses to load them (measured 2026-09-01), which is
/// why D3DMetal gets its own engine instead of a payload directory.
nonisolated enum GPTkEngineInstaller {
    /// The engine directory's name — also what the Engine pane shows.
    static let version = "gptk-3.0-3"

    private static let wineURL = URL(
        string: "https://github.com/Gcenx/game-porting-toolkit/releases/download/"
            + "Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz")!
    private static let sha256 = "d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e"
    private static let sizeBytes: Int64 = 239_200_808
    /// The wine tree inside Gcenx's tarball.
    private static let wineInArchive = "Game Porting Toolkit.app/Contents/Resources/wine"

    static var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: Engine.managedRoot.appendingPathComponent(version).path)
    }

    /// Download → verify → extract → overlay the toolkit → move into place.
    /// A version directory either exists complete or not at all, same
    /// contract as `EngineInstaller`.
    static func install(
        overlaying toolkit: D3DMetalInstaller.Installed,
        progress: @escaping @Sendable (String, Double?) -> Void = { _, _ in },
    ) async throws {
        guard !isInstalled else {
            try overlay(toolkit, ontoEngineAt: Engine.managedRoot.appendingPathComponent(version))
            return
        }
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("sevo-gptk-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let tarball = staging.appendingPathComponent("gptk.tar.xz")
        progress("Downloading the DX12 engine (~\(sizeBytes / 1_000_000) MB)…", 0)
        try await download(to: tarball, progress: progress)

        progress("Verifying…", nil)
        let digest = try EngineInstaller.sha256(of: tarball)
        guard digest == sha256 else {
            throw InstallError("GPTk engine hash mismatch: \(digest)")
        }

        progress("Installing…", nil)
        let extracted = staging.appendingPathComponent("extracted")
        try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
        let untar = await Subprocess.run(
            "/usr/bin/tar", ["-xJf", tarball.path, "-C", extracted.path],
            capture: .combined, timeout: .seconds(600),
        )
        guard untar.status == 0 else {
            throw InstallError("GPTk engine extraction failed: \(untar.output.suffix(200))")
        }
        let wineTree = extracted.appendingPathComponent(wineInArchive)
        guard manager.fileExists(atPath: wineTree.path) else {
            throw InstallError("GPTk tarball layout unexpected — no wine tree at \(wineInArchive)")
        }

        // Assemble the engine directory in staging, then move it whole.
        let assembled = staging.appendingPathComponent(version)
        try manager.createDirectory(at: assembled, withIntermediateDirectories: true)
        try manager.moveItem(at: wineTree, to: assembled.appendingPathComponent("wine"))
        let info: [String: Any] = [
            "version": version,
            "wine": wineURL.absoluteString,
            "renderers": [Renderer.d3dmetal.rawValue, Renderer.wined3d.rawValue],
            "flavor": "gptk",
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            .write(to: assembled.appendingPathComponent("engine-info.json"))

        progress("Adding D3DMetal \(toolkit.version)…", nil)
        try overlay(toolkit, ontoEngineAt: assembled)

        // The Dock shim rides along from a sibling engine when one has it;
        // an engine without it just gets the Wine Dock icon back.
        for sibling in SetupProbe.managedEngineVersions() {
            let shim = Engine.managedRoot
                .appendingPathComponent("\(sibling)/libsevodockshim.dylib")
            guard manager.fileExists(atPath: shim.path) else { continue }
            try? manager.copyItem(
                at: shim, to: assembled.appendingPathComponent("libsevodockshim.dylib"))
            break
        }

        try manager.createDirectory(at: Engine.managedRoot, withIntermediateDirectories: true)
        try manager.moveItem(
            at: assembled, to: Engine.managedRoot.appendingPathComponent(version))
        Engine.refreshResolution()
    }

    /// Apple's own steps: the toolkit's `lib/` over the wine tree's `lib/`,
    /// then the nvngx renames that route DLSS to MetalFX. Re-runnable when
    /// a newer toolkit lands.
    static func overlay(
        _ toolkit: D3DMetalInstaller.Installed, ontoEngineAt engine: URL,
    ) throws {
        let manager = FileManager.default
        let wineLib = engine.appendingPathComponent("wine/lib")
        for half in ["external", "wine/x86_64-unix", "wine/x86_64-windows"] {
            let source = toolkit.root.appendingPathComponent("lib/\(half)")
            let target = wineLib.appendingPathComponent(half)
            guard manager.fileExists(atPath: source.path) else { continue }
            try manager.createDirectory(
                at: target, withIntermediateDirectories: true)
            for item in try manager.contentsOfDirectory(
                at: source, includingPropertiesForKeys: nil,
            ) {
                let destination = target.appendingPathComponent(item.lastPathComponent)
                try? manager.removeItem(at: destination)
                try manager.copyItem(at: item, to: destination)
            }
        }
        for (bridge, name) in [
            ("wine/x86_64-unix/nvngx-on-metalfx.so", "wine/x86_64-unix/nvngx.so"),
            ("wine/x86_64-windows/nvngx-on-metalfx.dll", "wine/x86_64-windows/nvngx.dll"),
        ] {
            let source = wineLib.appendingPathComponent(bridge)
            let target = wineLib.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.removeItem(at: target)
            try manager.copyItem(at: source, to: target)
        }
    }

    private static func download(
        to tarball: URL, progress: @escaping @Sendable (String, Double?) -> Void,
    ) async throws {
        let label = "Downloading the DX12 engine (~\(sizeBytes / 1_000_000) MB)…"
        let declared = sizeBytes
        final class ObservationBox: @unchecked Sendable {
            var observation: NSKeyValueObservation?
        }
        let box = ObservationBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let task = URLSession.shared.downloadTask(with: wineURL) { temp, _, error in
                box.observation?.invalidate()
                box.observation = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let temp else {
                    continuation.resume(throwing: InstallError("engine download produced no file"))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: temp, to: tarball)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            nonisolated(unsafe) var lastReported = 0.0
            box.observation = task.progress.observe(\.fractionCompleted) { taskProgress, _ in
                let fraction = taskProgress.totalUnitCount > 0
                    ? taskProgress.fractionCompleted
                    : Double(taskProgress.completedUnitCount) / Double(declared)
                guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
                lastReported = fraction
                progress(label, min(1, fraction))
            }
            task.resume()
        }
    }

    private struct InstallError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
