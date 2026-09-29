import Foundation

/// HoYoPlay's public launcher API and the Sophon download service behind it.
///
/// No account is involved: these are the calls HoYoPlay makes before anyone
/// signs in. `getGameBranches` names each game's current build and the
/// builds it can be patched from; `getBuild` lists every file of a build as
/// zstd chunks; `getPatchBuild` (a POST) lists the diffs from each older
/// build. The manifests these return are protobuf, decoded by
/// ``SophonManifest`` and ``SophonPatchManifest``.
nonisolated struct HoYoAPI: Sendable {
    /// HoYoPlay's own launcher id on the global servers.
    static let launcherID = "VYTpXlbWo8"
    static let branchesURL = "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getGameBranches"
    static let sophonURL = "https://sg-public-api.hoyoverse.com/downloader/sophon_chunk/api"

    var session: URLSession = .shared
    /// Where the two services are reached; a test points them at a stub.
    var branchesEndpoint = Self.branchesURL
    var sophonEndpoint = Self.sophonURL

    /// Why a call to HoYoverse's servers did not give an answer.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Branches

    /// A game's current build: what `getBuild` and `getPatchBuild` are asked
    /// about, and the older tags it has diffs from.
    struct Branch: Decodable, Sendable {
        let packageID: String
        let branch: String
        let password: String
        let tag: String
        let diffTags: [String]

        enum CodingKeys: String, CodingKey {
            case packageID = "package_id"
            case branch
            case password
            case tag
            case diffTags = "diff_tags"
        }
    }

    /// The current build of `game`. A game in pre-download also has a
    /// `pre_download` branch; only `main` is read, which is what is playable.
    func branch(_ game: HoYoGame) async throws -> Branch {
        struct Envelope: Decodable {
            struct Data: Decodable {
                struct Entry: Decodable {
                    struct Game: Decodable { let id: String }
                    let game: Game
                    let main: Branch?
                }
                let gameBranches: [Entry]
                enum CodingKeys: String, CodingKey { case gameBranches = "game_branches" }
            }
            let data: Data?
        }
        let url = "\(branchesEndpoint)?launcher_id=\(Self.launcherID)&game_ids[]=\(game.gameID)"
        let envelope: Envelope = try await get(url)
        guard let branch = envelope.data?.gameBranches.first(where: { $0.game.id == game.gameID })?.main else {
            throw Failure(description: "HoYoPlay's servers list no build of \(game.displayName)")
        }
        return branch
    }

    // MARK: - Builds

    /// Where a manifest or a build's files are downloaded from.
    struct Download: Decodable, Sendable {
        let urlPrefix: String
        let compression: Int

        enum CodingKeys: String, CodingKey { case urlPrefix = "url_prefix", compression }

        func url(_ name: String) -> URL? { URL(string: "\(urlPrefix)/\(name)") }
    }

    /// A manifest file: its name on the server and the md5 of its
    /// decompressed bytes.
    struct ManifestFile: Decodable, Sendable {
        let id: String
        let checksum: String
        let uncompressedSize: Int64

        enum CodingKeys: String, CodingKey { case id, checksum, uncompressedSize = "uncompressed_size" }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            checksum = try container.decode(String.self, forKey: .checksum)
            uncompressedSize = try container.decodeNumberString(forKey: .uncompressedSize)
        }
    }

    /// Sizes the service states for a manifest.
    struct Stats: Decodable, Sendable {
        let compressedSize: Int64
        let uncompressedSize: Int64
        let fileCount: Int64

        enum CodingKeys: String, CodingKey {
            case compressedSize = "compressed_size"
            case uncompressedSize = "uncompressed_size"
            case fileCount = "file_count"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            compressedSize = try container.decodeNumberString(forKey: .compressedSize)
            uncompressedSize = try container.decodeNumberString(forKey: .uncompressedSize)
            fileCount = try container.decodeNumberString(forKey: .fileCount)
        }
    }

    /// One category of a build: the game's own files (`game`) or a voice
    /// pack (`en-us`, `ja-jp`, …).
    struct BuildManifest: Decodable, Sendable {
        let matchingField: String
        let manifest: ManifestFile
        let manifestDownload: Download
        let chunkDownload: Download
        let stats: Stats

        enum CodingKeys: String, CodingKey {
            case matchingField = "matching_field"
            case manifest
            case manifestDownload = "manifest_download"
            case chunkDownload = "chunk_download", stats
        }
    }

    struct Build: Decodable, Sendable {
        let tag: String
        let manifests: [BuildManifest]
    }

    /// Every file of a build. `tag` asks for an older build than the current
    /// one; the service keeps those.
    func build(_ branch: Branch, tag: String? = nil) async throws -> Build {
        var url = "\(sophonEndpoint)/getBuild?\(branch.query)"
        if let tag { url += "&tag=\(tag)" }
        let envelope: Envelope<Build> = try await get(url)
        return try envelope.payload("getBuild")
    }

    // MARK: - Patches

    /// One category of a patch build. `stats` is keyed by the tag a patch
    /// starts from.
    struct PatchManifest: Decodable, Sendable {
        let matchingField: String
        let manifest: ManifestFile
        let manifestDownload: Download
        let diffDownload: Download
        let stats: [String: Stats]

        enum CodingKeys: String, CodingKey {
            case matchingField = "matching_field"
            case manifest
            case manifestDownload = "manifest_download"
            case diffDownload = "diff_download", stats
        }
    }

    struct PatchBuild: Decodable, Sendable {
        let tag: String
        let manifests: [PatchManifest]
    }

    /// The diffs to `branch`'s build from each tag in its `diffTags`.
    func patchBuild(_ branch: Branch) async throws -> PatchBuild {
        let envelope: Envelope<PatchBuild> = try await get(
            "\(sophonEndpoint)/getPatchBuild?\(branch.query)", method: "POST",
        )
        return try envelope.payload("getPatchBuild")
    }

    // MARK: - Manifests

    /// Downloads a manifest, decompresses it and checks it against the md5
    /// the build names.
    @concurrent func manifestData(_ file: ManifestFile, from download: Download) async throws -> Data {
        guard let url = download.url(file.id) else {
            throw Failure(description: "bad manifest URL \(download.urlPrefix)/\(file.id)")
        }
        let (data, response) = try await session.data(from: url)
        try Self.check(response, for: url)
        let bytes = download.compression == 0
            ? data
            : try SophonCodec.decompress(data, expectedSize: Int(file.uncompressedSize))
        guard SophonCodec.md5(bytes) == file.checksum else {
            throw Failure(description: "manifest \(file.id) does not match its checksum")
        }
        return bytes
    }

    // MARK: - Plumbing

    /// The `{retcode, message, data}` envelope every call answers in.
    private struct Envelope<Payload: Decodable>: Decodable {
        let retcode: Int
        let message: String
        let data: Payload?

        func payload(_ call: String) throws -> Payload {
            guard retcode == 0, let data else {
                throw Failure(description: "\(call) answered \(retcode): \(message)")
            }
            return data
        }
    }

    private func get<T: Decodable>(_ address: String, method: String = "GET") async throws -> T {
        guard let url = URL(string: address) else { throw Failure(description: "bad URL \(address)") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        try Self.check(response, for: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func check(_ response: URLResponse, for url: URL) throws {
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw Failure(description: "\(url.lastPathComponent): HTTP \(http.statusCode)")
        }
    }
}

private nonisolated extension HoYoAPI.Branch {
    var query: String { "branch=\(branch)&package_id=\(packageID)&password=\(password)" }
}

private nonisolated extension KeyedDecodingContainer {
    /// The service writes sizes as decimal strings (`"852931"`).
    func decodeNumberString(forKey key: Key) throws -> Int64 {
        if let number = try? decode(Int64.self, forKey: key) { return number }
        let text = try decode(String.self, forKey: key)
        guard let number = Int64(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a number: \(text)")
        }
        return number
    }
}
