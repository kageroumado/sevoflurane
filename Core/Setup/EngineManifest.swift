import Foundation

/// The managed-engine manifest: static JSON pointing at engine tarballs on
/// GitHub Releases, written and signed (`engine.json.sig`) by
/// `dormison/build-macos/publish-engine.sh`. Rollback is pointing it at the
/// previous entry.
nonisolated struct EngineManifest: Decodable, Sendable {
    struct Release: Decodable, Sendable, Equatable {
        let version: String
        let minAppVersion: String
        let url: URL
        let sha256: String
        let sizeBytes: Int64
        let notes: String?
        /// Whether the manifest verified, which holds the tarball to the same
        /// key and URL policy. An override manifest (`file://`,
        /// `sevo engine install --manifest`) is checked by hash alone.
        var fromVerifiedManifest = false

        private enum CodingKeys: String, CodingKey {
            case version
            case minAppVersion
            case url
            case sha256
            case sizeBytes
            case notes
        }
    }

    /// A renderer version tested with this engine (schema 2).
    struct ComponentRelease: Decodable, Sendable, Equatable {
        let version: String
        let url: URL
        let sha256: String?
        let notes: String?
    }

    /// A shader package's `package.json` fields plus its tarball (schema 2,
    /// ``ShaderPackages``).
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
    private(set) var channels: [String: Release]
    /// Keyed by component (`dxmt`, `dxvk`); absent in schema 1.
    let components: [String: [ComponentRelease]]?
    /// Shader packages the presenter can fetch; absent in schema 1.
    let shaders: [ShaderRelease]?
    /// Set by ``fetch(from:)`` when the bytes verified against the pinned key.
    private(set) var verified = false

    private enum CodingKeys: String, CodingKey {
        case schema
        case channels
        case components
        case shaders
    }

    static let url = URL(string: "https://github.com/kageroumado/dormison/releases/download/manifest/engine.json")!

    /// Another manifest to install from, such as a `file://` one for testing
    /// a clean machine. Set once at process start (`sevo setup --manifest`,
    /// or `SEVO_ENGINE_MANIFEST` in the app), like ``ClientLifecycle/log``.
    nonisolated(unsafe) static var overrideURL: URL?

    /// The manifest's `stable` entry, or ``NoRelease``.
    func release() throws -> Release {
        guard let release = channels[Self.releaseKey] else { throw NoRelease() }
        return release
    }

    /// The manifest key the app reads its engine from.
    static let releaseKey = "stable"

    /// Keys `publish-engine.sh` writes: `stable`, and `beta` carrying the
    /// same release for the 1.1 betas that read it until they update.
    static let publishedKeys: Set<String> = [releaseKey, "beta"]

    /// The feed names no engine.
    struct NoRelease: Error, CustomStringConvertible, Equatable {
        var description: String {
            "The engine manifest names no engine."
        }
    }

    /// The release manifest, refused without a valid `engine.json.sig`. An
    /// explicit or override URL is decoded unverified.
    static func fetch(from url: URL? = nil) async throws -> EngineManifest {
        if let url {
            let data = try await fetchBytes(url)
            return try decode(data)
        }
        if let overrideURL {
            // A stale test-rig override must not break Repair, so its
            // failure falls back to the real manifest.
            do {
                let data = try await fetchBytes(overrideURL)
                return try decode(data)
            } catch {
                SetupLog.log("engine manifest override unreachable (\(error)) — using the release manifest")
            }
        }
        let data = try await fetchBytes(Self.url)
        let signatureFile = try await EngineSignature.fetchSignature(EngineSignature.signatureURL(for: Self.url))
        try EngineSignature.verify(data, signatureFile: signatureFile, subject: Self.url.lastPathComponent)
        return try decode(data, verified: true)
    }

    /// The manifest's bytes, or an error naming the HTTP status: a private
    /// feed answers 404, which a JSON error would hide.
    private static func fetchBytes(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ManifestError("the engine manifest at \(url.absoluteString) answered HTTP \(http.statusCode)")
        }
        return data
    }

    static func decode(_ data: Data, verified: Bool = false) throws -> EngineManifest {
        var manifest = try JSONDecoder().decode(EngineManifest.self, from: data)
        guard (1 ... 2).contains(manifest.schema) else {
            throw ManifestError("unsupported engine manifest schema \(manifest.schema)")
        }
        manifest.verified = verified
        manifest.channels = manifest.channels.mapValues { release in
            var release = release
            release.fromVerifiedManifest = verified
            return release
        }
        return manifest
    }

    /// Every problem the app would hit installing from this manifest, which
    /// `publish-engine.sh` checks before uploading. Empty means publishable.
    func problems() -> [String] {
        var problems: [String] = []
        if channels[Self.releaseKey] == nil {
            problems.append("no engine: the manifest has no channels.\(Self.releaseKey)")
        }
        for (name, release) in channels.sorted(by: { $0.key < $1.key }) {
            let label = "channels.\(name)"
            if !Self.publishedKeys.contains(name) {
                problems.append("\(label) is not a key the app reads (stable | beta)")
            }
            if !EngineSignature.isAllowedAssetURL(release.url) {
                problems.append("\(label).url is not a kageroumado release asset: \(release.url.absoluteString)")
            }
            if !release.url.lastPathComponent.contains(release.version) {
                problems.append("\(label).url does not carry the version \(release.version)")
            }
            if !Self.isSHA256(release.sha256) {
                problems.append("\(label).sha256 is not 64 hex digits")
            }
            if release.sizeBytes <= 0 {
                problems.append("\(label).sizeBytes must be positive")
            }
            if release.minAppVersion.isEmpty {
                problems.append("\(label).minAppVersion is empty")
            }
        }
        for (component, releases) in components ?? [:] {
            for release in releases {
                if release.url.scheme?.lowercased() != "https" {
                    problems.append("components.\(component) \(release.version): url is not https")
                }
                // A third-party payload is tied to what was tested only by its
                // digest, and ``RendererVersions/install(_:from:version:sha256:)``
                // skips the check when there is none.
                if release.sha256.map({ !Self.isSHA256($0) }) ?? true {
                    problems.append("components.\(component) \(release.version): sha256 is missing or not 64 hex digits")
                }
            }
        }
        for shader in shaders ?? [] {
            if shader.url.scheme?.lowercased() != "https" {
                problems.append("shaders \(shader.name): url is not https")
            }
            if let sha = shader.sha256, !Self.isSHA256(sha) {
                problems.append("shaders \(shader.name): sha256 is not 64 hex digits")
            }
        }
        return problems
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }

    private struct ManifestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
