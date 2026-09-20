import Foundation
import Testing
@testable import Sevoflurane

/// What leaves the machine when a report is sent, and what the answer means.
struct ReportUploadTests {
    private static func zip(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportUploadTests-\(UUID().uuidString).zip")
        try Data(repeating: 0x50, count: bytes).write(to: url)
        return url
    }

    /// An upload against an endpoint of its own, so tests that run at the same
    /// time cannot read each other's answers.
    private static func upload(status: Int) -> ReportUpload {
        let endpoint = URL(string: "https://reports.example/\(UUID().uuidString)/v1/sevoflurane")!
        UploadStub.expect(status: status, at: endpoint)
        return ReportUpload(
            endpoint: endpoint,
            installToken: "0123456789abcdef0123456789abcdef",
            version: "1.9+12",
            session: UploadStub.session(),
        )
    }

    @Test
    func `the zip is the body, and the headers name the install and the version`() async throws {
        let zip = try Self.zip(bytes: 1234)
        defer { try? FileManager.default.removeItem(at: zip) }
        let upload = Self.upload(status: 204)
        #expect(try await upload.send(zip) == .accepted)
        let seen = try #require(UploadStub.exchange(at: upload.endpoint))
        let request = try #require(seen.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url == upload.endpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/zip")
        #expect(request.value(forHTTPHeaderField: "X-Sevoflurane-Install") == "0123456789abcdef0123456789abcdef")
        #expect(request.value(forHTTPHeaderField: "X-Sevoflurane-Version") == "1.9+12")
        #expect(seen.body?.count == 1234)
    }

    @Test
    func `a zip over the cap never leaves the machine`() async throws {
        let zip = try Self.zip(bytes: ReportUpload.maximumBytes + 1)
        defer { try? FileManager.default.removeItem(at: zip) }
        let upload = Self.upload(status: 204)
        await #expect(throws: ReportUpload.Failure.tooLarge(bytes: ReportUpload.maximumBytes + 1)) {
            try await upload.send(zip)
        }
        #expect(UploadStub.exchange(at: upload.endpoint)?.request == nil)
    }

    @Test(arguments: [413, 429, 500])
    func `a refusal is reported as one, with its status`(status: Int) async throws {
        let zip = try Self.zip(bytes: 10)
        defer { try? FileManager.default.removeItem(at: zip) }
        #expect(try await Self.upload(status: status).send(zip) == .refused(status: status))
    }
}

/// A transport that answers a status per endpoint and remembers what was
/// asked of it there. One protocol class serves every test in the suite, and
/// they run at the same time, so everything it holds is keyed by the URL.
private final class UploadStub: URLProtocol, @unchecked Sendable {
    struct Exchange {
        var status = 204
        var request: URLRequest?
        var body: Data?
    }

    private nonisolated(unsafe) static var exchanges: [URL: Exchange] = [:]
    private static let lock = NSLock()

    static func expect(status: Int, at url: URL) {
        lock.withLock { exchanges[url] = Exchange(status: status) }
    }

    static func exchange(at url: URL) -> Exchange? {
        lock.withLock { exchanges[url] }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadStub.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url!
        let status = Self.lock.withLock {
            var exchange = Self.exchanges[url] ?? Exchange()
            exchange.request = request
            // An upload task hands the body to the protocol as a stream.
            exchange.body = request.httpBody ?? request.httpBodyStream.map(Self.drain)
            Self.exchanges[url] = exchange
            return exchange.status
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil,
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
