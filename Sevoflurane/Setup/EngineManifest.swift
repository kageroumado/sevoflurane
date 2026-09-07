import Foundation

/// The managed-engine version manifest: a static JSON at a URL we control,
/// pointing at engine tarballs on GitHub Releases.
/// `dormison/build-macos/package-engine.sh` emits entries; rollback is
/// pointing the manifest at the previous entry.
nonisolated struct EngineManifest: Decodable, Sendable {
    struct Release: Decodable, Sendable, Equatable {
        let version: String
        let minAppVersion: String
        let url: URL
        let sha256: String
        let sizeBytes: Int64
        let notes: String?
    }

    /// One downloadable version of a renderer (schema 2): named here because
    /// it was run with the engine the manifest points at.
    struct ComponentRelease: Decodable, Sendable, Equatable {
        let version: String
        let url: URL
        let sha256: String?
        let notes: String?
    }

    /// One downloadable shader package for the presenter's upscaler
    /// (schema 2, ``ShaderPackages``): what the package's own `package.json`
    /// says, plus where its tarball is.
    struct ShaderRelease: Decodable, Sendable, Equatable {
        let name: String
        let title: String
        let description: String
        let content: String
        let license: String
        let version: String
        let source: URL?
        let url: URL
        let sha256: String?
        let size: Int64?
    }

    let schema: Int
    let channels: [String: Release]
    /// Keyed by component (`dxmt`, `dxvk`); absent in schema 1.
    let components: [String: [ComponentRelease]]?
    /// Shader packages the presenter can fetch; absent in schema 1.
    let shaders: [ShaderRelease]?

    static let url = URL(string: "https://github.com/kageroumado/sevoflurane/releases/download/engine/engine.json")!

    /// Points the installer at another manifest — a `file://` one is how a
    /// clean machine is validated without publishing anything. Set once at
    /// process start, same contract as ``ClientLifecycle/log`` — by
    /// `sevo setup --manifest`, or `SEVO_ENGINE_MANIFEST` in the app.
    nonisolated(unsafe) static var overrideURL: URL?

    var stable: Release? {
        channels["stable"]
    }

    static func fetch(from url: URL? = nil) async throws -> EngineManifest {
        if let url {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try decode(data)
        }
        if let overrideURL {
            // The override is test-rig plumbing (a defaults key or env var),
            // and a rig's stale file:// target must not brick Repair on a
            // machine that could reach the real manifest fine.
            do {
                let (data, _) = try await URLSession.shared.data(from: overrideURL)
                return try decode(data)
            } catch {
                SetupLog.log("engine manifest override unreachable (\(error)) — using the release manifest")
            }
        }
        let (data, _) = try await URLSession.shared.data(from: Self.url)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> EngineManifest {
        let manifest = try JSONDecoder().decode(EngineManifest.self, from: data)
        guard (1 ... 2).contains(manifest.schema) else {
            throw ManifestError("unsupported engine manifest schema \(manifest.schema)")
        }
        return manifest
    }

    private struct ManifestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
