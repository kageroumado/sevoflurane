import Foundation
import Testing
@testable import Sevoflurane

struct HTTPParsingTests {
    @Test
    func `parses request with body and leftover`() throws {
        let raw = "POST /__eval HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloGET /"
        let parsed = HTTPServer.parse(Data(raw.utf8))
        let request = try #require(parsed).0
        #expect(request.method == "POST")
        #expect(request.path == "/__eval")
        #expect(String(data: request.body, encoding: .utf8) == "hello")
        #expect(try String(data: #require(parsed?.1), encoding: .utf8) == "GET /")
    }

    @Test
    func `incomplete request returns nil`() {
        #expect(HTTPServer.parse(Data("GET / HTTP/1.1\r\nHost:".utf8)) == nil)
        #expect(HTTPServer.parse(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)) == nil)
    }

    @Test
    func `path and query split`() {
        let request = HTTPRequest(
            method: "GET",
            target: "/index.html?IN_CLIENT=true&A=1",
            headers: [:],
            body: Data(),
        )
        #expect(request.path == "/index.html")
        #expect(request.query == "IN_CLIENT=true&A=1")
        let bare = HTTPRequest(method: "GET", target: "/", headers: [:], body: Data())
        #expect(bare.query.isEmpty)
    }

    @Test
    func `content types`() {
        #expect(ContentType.forExtension("js") == "text/javascript")
        #expect(ContentType.forExtension("PNG") == "image/png")
        #expect(ContentType.forExtension("weird") == "application/octet-stream")
    }
}

struct LicenseParsingTests {
    private let future = "[crossmac]\ncustomer=user\nexpires=2099/01/01\n[license]\nid=abc123\n"
    private let past = "[crossmac]\ncustomer=user\nexpires=2020/01/01\n[license]\nid=abc123\n"

    @Test
    func `valid license`() {
        let result = SetupProbe.parseLicense(future)
        #expect(result.licensed)
        #expect(result.expires == "2099/01/01")
    }

    @Test
    func `expired license`() {
        #expect(!SetupProbe.parseLicense(past).licensed)
    }

    @Test
    func `missing or partial license`() {
        #expect(!SetupProbe.parseLicense("").licensed)
        #expect(!SetupProbe.parseLicense("[crossmac]\nexpires=2099/01/01\n").licensed)
    }

    @Test
    func `no expiry still licensed`() {
        #expect(SetupProbe.parseLicense("[license]\nid=abc123\n").licensed)
    }
}
