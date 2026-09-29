import Foundation
import Testing
@testable import Sevoflurane

/// Installs, updates and repairs against a stub of HoYoPlay's servers: each
/// test serves its own host, with manifests and chunks stored uncompressed
/// (`compression: 0`), which the service's JSON allows.
struct SophonDownloaderTests {
    /// One game build served by a stub host.
    private struct Server {
        let host = "sophon-\(UUID().uuidString.lowercased()).test"
        var tag = "4.6.0"
        var diffTags = ["4.5.0"]
        /// The current build's files, keyed by path.
        var files: [String: Data] = [:]
        /// Patch files: path, new contents, the diff and the older file it
        /// applies to (nil for a new file).
        var patches: [(path: String, new: Data, diff: Data, original: String?, originalSize: Int)] = []
        var deleted: [String] = []

        var downloader: SophonDownloader {
            var api = HoYoAPI(session: StubServer.session)
            api.branchesEndpoint = "https://\(host)/branches"
            api.sophonEndpoint = "https://\(host)/sophon"
            return SophonDownloader(api: api, parallelism: 4, backoff: [])
        }

        /// Registers every route and answers nothing.
        func serve() {
            var routes: [String: Data] = [:]
            let branch: [String: Any] = [
                "package_id": "pkg", "branch": "main", "password": "pw", "tag": tag, "diff_tags": diffTags,
            ]
            routes["/branches"] = json(["retcode": 0, "message": "OK", "data": [
                "game_branches": [["game": ["id": HoYoGame.starRail.gameID], "main": branch]],
            ]])

            // The build: every file as one or two chunks.
            var chunkMessages: [Data] = []
            for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
                var chunks: [Data] = []
                let halves = contents.count > 8
                    ? [contents.prefix(contents.count / 2), contents.suffix(from: contents.count / 2)]
                    : (contents.isEmpty ? [] : [contents[...]])
                for part in halves {
                    let bytes = Data(part)
                    let name = "chunk_\(SophonCodec.md5(bytes))"
                    routes["/chunks/\(name)"] = bytes
                    chunks.append(Proto.field(2, Proto.message([
                        Proto.field(1, name), Proto.field(2, SophonCodec.md5(bytes)),
                        Proto.field(3, Int64(part.startIndex - contents.startIndex)), Proto.field(4, Int64(bytes.count)),
                        Proto.field(5, Int64(bytes.count)), Proto.field(7, SophonCodec.md5(bytes)),
                    ])))
                }
                chunkMessages.append(Proto.field(1, Proto.message(
                    [Proto.field(1, path)] + chunks + [Proto.field(4, Int64(contents.count)), Proto.field(5, SophonCodec.md5(contents))],
                )))
            }
            let buildManifest = Proto.message(chunkMessages)
            routes["/manifests/build"] = buildManifest
            routes["/sophon/getBuild"] = json(["retcode": 0, "message": "OK", "data": [
                "tag": tag, "manifests": [manifestEntry("build", buildManifest, extra: [
                    "chunk_download": ["url_prefix": "https://\(host)/chunks", "compression": 0],
                    "stats": ["compressed_size": "\(files.values.map(\.count).reduce(0, +))", "uncompressed_size": "0", "file_count": "\(files.count)"],
                ])],
            ]])

            routes.merge(patchRoutes()) { _, new in new }
            StubServer.register(host: host, routes: routes)
        }

        /// The patch: every diff in one blob, then the deletions.
        private func patchRoutes() -> [String: Data] {
            var routes: [String: Data] = [:]
            var blob = Data()
            var patchMessages: [Data] = []
            for patch in patches {
                var diff = [Proto.field(1, "blob"), Proto.field(6, Int64(blob.count)), Proto.field(7, Int64(patch.diff.count))]
                if let original = patch.original {
                    diff += [Proto.field(8, original), Proto.field(9, Int64(patch.originalSize))]
                }
                blob += patch.diff
                patchMessages.append(Proto.field(1, Proto.message([
                    Proto.field(1, patch.path), Proto.field(2, Int64(patch.new.count)), Proto.field(3, SophonCodec.md5(patch.new)),
                    Proto.field(4, Proto.message([Proto.field(1, diffTags[0]), Proto.field(2, Proto.message(diff))])),
                ])))
            }
            if !deleted.isEmpty {
                let list = Proto.message(deleted.map { Proto.field(1, Proto.message([Proto.field(1, $0)])) })
                patchMessages.append(Proto.field(2, Proto.message([Proto.field(1, diffTags[0]), Proto.field(2, list)])))
            }
            let patchManifest = Proto.message(patchMessages)
            routes["/manifests/patch"] = patchManifest
            routes["/diffs/blob"] = blob
            routes["/sophon/getPatchBuild"] = json(["retcode": 0, "message": "OK", "data": [
                "tag": tag, "manifests": [manifestEntry("patch", patchManifest, extra: [
                    "diff_download": ["url_prefix": "https://\(host)/diffs", "compression": 0],
                    "stats": [diffTags[0]: ["compressed_size": "\(blob.count)", "uncompressed_size": "0", "file_count": "\(patches.count)"]],
                ])],
            ]])
            return routes
        }

        private func manifestEntry(_ id: String, _ bytes: Data, extra: [String: Any]) -> [String: Any] {
            [
                "matching_field": "game",
                "manifest": ["id": id, "checksum": SophonCodec.md5(bytes), "compressed_size": "\(bytes.count)", "uncompressed_size": "\(bytes.count)"],
                "manifest_download": ["url_prefix": "https://\(host)/manifests", "compression": 0],
            ].merging(extra) { first, _ in first }
        }

        private func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data() }
    }

    private static let old = Data(SophonCodecTests.oldText.utf8)
    private static let new = Data(SophonCodecTests.newText.utf8)

    @Test
    func `an install writes every file from its chunks and records the build`() async throws {
        let folder = try SophonCodecTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var server = Server()
        server.files = ["StarRail.exe": Data("MZ exe".utf8), "StarRail_Data/a.block": Self.new, "empty.txt": Data()]
        server.serve()
        let tag = try await server.downloader.install(game: .starRail, into: folder, voices: [])
        #expect(tag == "4.6.0")
        #expect(try Data(contentsOf: folder.appending(path: "StarRail_Data/a.block")) == Self.new)
        #expect(try Data(contentsOf: folder.appending(path: "empty.txt")).isEmpty)
        #expect(HoYoInstallation(folder: folder)?.version == "4.6.0")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "StarRail_Data/a.block.sophon").path))
    }

    @Test
    func `an install keeps the files already in place`() async throws {
        let folder = try SophonCodecTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var server = Server()
        server.files = ["StarRail.exe": Data("MZ exe".utf8), "a.block": Self.new]
        server.serve()
        try Self.new.write(to: folder.appending(path: "a.block"))
        try await server.downloader.install(game: .starRail, into: folder, voices: [])
        let chunkRequests = StubServer.requests(host: server.host).filter { $0.hasPrefix("/chunks/") }
        #expect(chunkRequests.count == 1)
    }

    @Test
    func `an update applies each diff, creates new files and deletes dropped ones`() async throws {
        let folder = try SophonCodecTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("MZ exe".utf8).write(to: folder.appending(path: "StarRail.exe"))
        try Self.old.write(to: folder.appending(path: "b.txt"))
        try Data("dropped".utf8).write(to: folder.appending(path: "gone.txt"))
        try "[General]\r\ngame_version=4.5.0\r\n".write(to: folder.appending(path: "config.ini"), atomically: true, encoding: .utf8)
        var server = Server()
        server.patches = [
            ("b.txt", Self.new, SophonCodecTests.diff, "b.txt", Self.old.count),
            ("sub/c.txt", Self.new, SophonCodecTests.diffFromNothing, nil, 0),
        ]
        server.deleted = ["gone.txt"]
        server.serve()
        let installation = try #require(HoYoInstallation(folder: folder))
        let outcome = try await server.downloader.update(installation)
        #expect(outcome == .patched(from: "4.5.0", to: "4.6.0", files: 2, current: 0, downloadedWhole: 0))
        #expect(try Data(contentsOf: folder.appending(path: "b.txt")) == Self.new)
        #expect(try Data(contentsOf: folder.appending(path: "sub/c.txt")) == Self.new)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "gone.txt").path))
        #expect(installation.version == "4.6.0")
        #expect(StubServer.requests(host: server.host).allSatisfy { !$0.hasPrefix("/chunks/") })
    }

    @Test
    func `a diff from a differently named file replaces it`() async throws {
        let folder = try SophonCodecTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("MZ exe".utf8).write(to: folder.appending(path: "StarRail.exe"))
        try FileManager.default.createDirectory(at: folder.appending(path: "Asb"), withIntermediateDirectories: true)
        try Self.old.write(to: folder.appending(path: "Asb/815017d2.block"))
        try "[General]\ngame_version=4.5.0\n".write(to: folder.appending(path: "config.ini"), atomically: true, encoding: .utf8)
        var server = Server()
        // As in Star Rail 4.6.0, the renamed file's older copy is on no
        // deletion list.
        server.patches = [("Asb/b38e0067.block", Self.new, SophonCodecTests.diff, "Asb/815017d2.block", Self.old.count)]
        server.serve()
        let installation = try #require(HoYoInstallation(folder: folder))
        let outcome = try await server.downloader.update(installation)
        #expect(outcome == .patched(from: "4.5.0", to: "4.6.0", files: 1, current: 0, downloadedWhole: 0))
        #expect(try Data(contentsOf: folder.appending(path: "Asb/b38e0067.block")) == Self.new)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Asb/815017d2.block").path))
    }

    @Test
    func `a diff that does not apply is replaced by the whole file`() async throws {
        let folder = try SophonCodecTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("MZ exe".utf8).write(to: folder.appending(path: "StarRail.exe"))
        // The older file has the right size and the wrong bytes.
        try Data(repeating: 0x41, count: Self.old.count).write(to: folder.appending(path: "b.txt"))
        try "[General]\ngame_version=4.5.0\n".write(to: folder.appending(path: "config.ini"), atomically: true, encoding: .utf8)
        var server = Server()
        server.files = ["StarRail.exe": Data("MZ exe".utf8), "b.txt": Self.new]
        server.patches = [("b.txt", Self.new, SophonCodecTests.diff, "b.txt", Self.old.count)]
        server.serve()
        let installation = try #require(HoYoInstallation(folder: folder))
        let outcome = try await server.downloader.update(installation)
        #expect(outcome == .patched(from: "4.5.0", to: "4.6.0", files: 0, current: 0, downloadedWhole: 1))
        #expect(try Data(contentsOf: folder.appending(path: "b.txt")) == Self.new)
    }

    @Test
    func `a build too old for diffs updates by downloading what differs`() async throws {
        let folder = try SophonCodecTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("MZ exe".utf8).write(to: folder.appending(path: "StarRail.exe"))
        try Self.old.write(to: folder.appending(path: "b.txt"))
        try "[General]\ngame_version=4.3.0\n".write(to: folder.appending(path: "config.ini"), atomically: true, encoding: .utf8)
        var server = Server()
        server.files = ["StarRail.exe": Data("MZ exe".utf8), "b.txt": Self.new]
        server.serve()
        let installation = try #require(HoYoInstallation(folder: folder))
        let plan = try await server.downloader.plan(game: .starRail, folder: folder)
        #expect(plan.kind == .download)
        #expect(try await server.downloader.update(installation) == .downloaded(to: "4.6.0"))
        #expect(try Data(contentsOf: folder.appending(path: "b.txt")) == Self.new)
        #expect(installation.version == "4.6.0")
    }

    @Test
    func `the plan names a patch with its size and an up-to-date folder as such`() async throws {
        let folder = try SophonCodecTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("MZ exe".utf8).write(to: folder.appending(path: "StarRail.exe"))
        try "[General]\ngame_version=4.5.0\n".write(to: folder.appending(path: "config.ini"), atomically: true, encoding: .utf8)
        var server = Server()
        server.patches = [("b.txt", Self.new, SophonCodecTests.diff, "b.txt", Self.old.count)]
        server.serve()
        let plan = try await server.downloader.plan(game: .starRail, folder: folder)
        #expect(plan.kind == .patch(from: "4.5.0"))
        #expect(plan.downloadSize == Int64(SophonCodecTests.diff.count))
        try HoYoInstallation(game: .starRail, folder: folder).recordVersion("4.6.0")
        #expect(try await server.downloader.plan(game: .starRail, folder: folder).kind == .upToDate)
    }
}

/// Serves each test's routes by host, honoring a byte range, and records
/// the paths each host was asked for.
private final class StubServer: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var routes: [String: [String: Data]] = [:]
    private nonisolated(unsafe) static var log: [String: [String]] = [:]
    private static let lock = NSLock()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }()

    static func register(host: String, routes: [String: Data]) {
        lock.withLock { self.routes[host] = routes }
    }

    static func requests(host: String) -> [String] {
        lock.withLock { log[host] ?? [] }
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let path = url.path()
        let body = Self.lock.withLock { () -> Data? in
            Self.log[host, default: []].append(path)
            return Self.routes[host]?[path]
        }
        guard var body else {
            respond(url, status: 404, body: Data())
            return
        }
        var status = 200
        if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            if bounds.count == 2 {
                body = body.subdata(in: bounds[0] ..< min(bounds[1] + 1, body.count))
                status = 206
            }
        }
        respond(url, status: status, body: body)
    }

    private func respond(_ url: URL, status: Int, body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
