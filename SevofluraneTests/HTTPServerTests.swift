import Foundation
import Testing
@testable import Sevoflurane

/// The request framer behind the UI, art, and control servers. A parse that
/// trapped, or waited forever, took the whole app with it, so every rejection
/// here is a status the connection can answer before it closes.
struct HTTPServerTests {
    private func parse(_ raw: String) -> HTTPServer.ParseResult {
        HTTPServer.parse(Data(raw.utf8))
    }

    private func status(_ raw: String) -> Int? {
        guard case let .malformed(status) = parse(raw) else { return nil }
        return status
    }

    @Test
    func `parses request with body and leftover`() throws {
        let raw = "POST /__eval HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloGET /"
        guard case let .complete(request, rest) = parse(raw) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/__eval")
        #expect(String(data: request.body, encoding: .utf8) == "hello")
        #expect(String(data: rest, encoding: .utf8) == "GET /")
    }

    @Test
    func `pipelined requests come out one at a time`() throws {
        let first = "POST /a HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc"
        let second = "GET /b HTTP/1.1\r\nHost: x\r\n\r\n"
        guard case let .complete(requestA, rest) = parse(first + second) else {
            Issue.record("expected the first request")
            return
        }
        #expect(requestA.path == "/a")
        #expect(String(data: requestA.body, encoding: .utf8) == "abc")
        guard case let .complete(requestB, remainder) = HTTPServer.parse(rest) else {
            Issue.record("expected the second request from the leftover")
            return
        }
        #expect(requestB.method == "GET")
        #expect(requestB.path == "/b")
        #expect(requestB.body.isEmpty)
        #expect(remainder.isEmpty)
    }

    @Test
    func `missing content-length means an empty body`() {
        #expect(parse("GET / HTTP/1.1\r\nHost: x\r\n\r\n") == .complete(
            HTTPRequest(method: "GET", target: "/", headers: ["host": "x"], body: Data()),
            rest: Data(),
        ))
    }

    @Test
    func `truncated input asks for more`() {
        #expect(parse("GET / HTTP/1.1\r\nHost:") == .incomplete)
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc") == .incomplete)
        #expect(parse("") == .incomplete)
    }

    @Test
    func `negative content-length is malformed rather than a trap`() {
        #expect(status("POST /__eval HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == 400)
    }

    @Test
    func `signed, non-numeric, empty and overflowing lengths are malformed`() {
        #expect(status("POST / HTTP/1.1\r\nContent-Length: +5\r\n\r\nhello") == 400)
        #expect(status("POST / HTTP/1.1\r\nContent-Length: five\r\n\r\n") == 400)
        #expect(status("POST / HTTP/1.1\r\nContent-Length: 0x5\r\n\r\nhello") == 400)
        #expect(status("POST / HTTP/1.1\r\nContent-Length:\r\n\r\n") == 400)
        #expect(status("POST / HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n") == 400)
    }

    @Test
    func `a body over the cap is too large`() {
        #expect(status("POST / HTTP/1.1\r\nContent-Length: \(HTTPServer.maxBodyBytes + 1)\r\n\r\n") == 413)
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: \(HTTPServer.maxBodyBytes)\r\n\r\n") == .incomplete)
    }

    @Test
    func `duplicate content-length is malformed even when the values agree`() {
        #expect(status("POST / HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc") == 400)
        #expect(status("POST / HTTP/1.1\r\nContent-Length: 3\r\ncontent-length: 4\r\n\r\nabcd") == 400)
    }

    @Test
    func `transfer-encoding is refused`() {
        #expect(status("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n") == 501)
        #expect(status("POST / HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: identity\r\n\r\n") == 501)
    }

    @Test
    func `an oversized header block is rejected, complete or not`() {
        let filler = String(repeating: "x", count: HTTPServer.maxHeaderBytes)
        #expect(status("GET / HTTP/1.1\r\nX-Pad: \(filler)") == 431)
        #expect(status("GET / HTTP/1.1\r\nX-Pad: \(filler)\r\n\r\n") == 431)
        // A block whose blank line ends exactly at the cap fits. Sized in
        // bytes: "\r\n" is one Character but two of them.
        let prefix = "GET / HTTP/1.1\r\nX-Pad: "
        let padding = HTTPServer.maxHeaderBytes - prefix.utf8.count - "\r\n\r\n".utf8.count
        let exact = prefix + String(repeating: "x", count: padding) + "\r\n\r\n"
        #expect(exact.utf8.count == HTTPServer.maxHeaderBytes)
        guard case .complete = parse(exact) else {
            Issue.record("a header block ending at the cap is a request")
            return
        }
        // One byte more and the blank line straddles the cap.
        let over = prefix + String(repeating: "x", count: padding + 1) + "\r\n\r\n"
        #expect(status(over) == 431)
    }

    @Test
    func `a request line without a target is malformed`() {
        #expect(status("GET\r\n\r\n") == 400)
        #expect(status("\r\n\r\n") == 400)
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
