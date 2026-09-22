import Foundation

/// The managed-engine version manifest: a static JSON at a URL we control,
/// pointing at engine tarballs on GitHub Releases.
/// `dormison/build-macos/publish-engine.sh` writes it, signs it
/// (`engine.json.sig`, ``EngineSignature``) and uploads both; rollback is
/// pointing the manifest at the previous entry.
nonisolated struct EngineManifest: Decodable, Sendable {
    struct Release: Decodable, Sendable, Equatable {
        let version: String
        let minAppVersion: String
        let url: URL
        let sha256: String
        let sizeBytes: Int64
        let notes: String?
        /// The manifest this came from carried a valid signature from the
        /// engine key, so the installer holds the tarball to the same key
        /// and to the release-asset URL policy. An override manifest (a test
        /// rig's `file://` one, `sevo engine install --manifest`) is trusted
        /// as the operator's own and checked by hash alone.
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

    static let url = URL(string: "https://github.com/kageroumado/sevoflurane/releases/download/engine/engine.json")!

    /// Points the installer at another manifest — a `file://` one is how a
    /// clean machine is validated without publishing anything. Set once at
    /// process start, same contract as ``ClientLifecycle/log`` — by
    /// `sevo setup --manifest`, or `SEVO_ENGINE_MANIFEST` in the app.
    nonisolated(unsafe) static var overrideURL: URL?

    var stable: Release? {
        channels["stable"]
    }

    /// The release a Mac on `channel` takes: the channel's own, or stable
    /// when the channel is empty, which is how beta reads between betas.
    func release(for channel: EngineChannel = Preferences.engineChannel) -> Release? {
        channels[channel.rawValue] ?? stable
    }

    /// The release manifest, verified against ``EngineSignature``'s key
    /// before it is decoded; a manifest without a valid `engine.json.sig`
    /// is refused. An explicit or override URL is the operator's own and is
    /// decoded unverified.
    static func fetch(from url: URL? = nil) async throws -> EngineManifest {
        if let url {
            let data = try await fetchBytes(url)
            return try decode(data)
        }
        if let overrideURL {
            // The override is test-rig plumbing (a defaults key or env var),
            // and a rig's stale file:// target must not brick Repair on a
            // machine that could reach the real manifest fine.
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

    /// The manifest's bytes, or the HTTP status that stood in for them — a
    /// private release feed answers 404 to anyone not signed in, and the
    /// status names the problem where a JSON error would not.
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

    /// What `publish-engine.sh` checks before it uploads: every problem the
    /// app would hit installing from this manifest. Empty means publishable.
    func problems() -> [String] {
        var problems: [String] = []
        if channels["stable"] == nil {
            problems.append("no stable channel")
        }
        for (name, release) in channels.sorted(by: { $0.key < $1.key }) {
            let label = "channels.\(name)"
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
                // A component payload comes from someone else's release feed,
                // so its digest is the only thing tying the download to what
                // was tested — and ``RendererVersions/install(_:from:version:sha256:)``
                // skips the check entirely when the manifest does not carry one.
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
