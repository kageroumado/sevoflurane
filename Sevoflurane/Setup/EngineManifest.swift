import Foundation

/// The managed-engine version manifest (`Docs/onboarding-spec.md` S1,
/// schema 1): a static JSON at a URL we control, pointing at engine tarballs
/// on GitHub Releases. `Tools/package-engine.sh` emits entries; rollback is
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

    let schema: Int
    let channels: [String: Release]

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
        let (data, _) = try await URLSession.shared.data(from: url ?? overrideURL ?? Self.url)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> EngineManifest {
        let manifest = try JSONDecoder().decode(EngineManifest.self, from: data)
        guard manifest.schema == 1 else {
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
