import Foundation
import Network
import Testing
@testable import Sevoflurane

/// The one check between a web page in the user's browser and the app's
/// loopback ports. Each legitimate caller's request shape is admitted here as
/// it is actually sent, so a gate that grows stricter fails a test before it
/// fails the CLI, the daemon or Steam's relay.
struct LoopbackGateTests {
    private let authHeader = ControlToken.header.lowercased()
    private let token = String(repeating: "5e", count: ControlToken.byteCount)
    private let session = String(repeating: "a1", count: ControlToken.byteCount)
    private var expected: () throws -> String {
        { [token] in token }
    }

    private func signed(_ method: String, _ target: String, body: Data = Data(), with token: String? = nil) -> String {
        ControlToken.signature(token: token ?? self.token, method: method, target: target, body: body)
    }

    private var cookie: String { "\(LoopbackSession.cookieName)=\(session)" }

    @Test
    func `the CLI's request to the control port is admitted`() {
        // URLSession and curl send Host, the signature, and no Origin.
        let body = Data("steam.exe\n-silent".utf8)
        #expect(LoopbackGate.control.admits(
            method: "POST", target: "/bottle/run?timeout=30",
            headers: [
                "host": "127.0.0.1:\(BridgePorts.control)",
                authHeader: signed("POST", "/bottle/run?timeout=30", body: body),
            ],
            body: body, expectedToken: expected,
        ))
        #expect(LoopbackGate.control.admits(
            method: "GET", target: "/status",
            headers: [
                "host": "localhost:\(BridgePorts.control)", "user-agent": "curl/8.7.1",
                authHeader: signed("GET", "/status"),
            ],
            expectedToken: expected,
        ))
    }

    @Test
    func `the control and link ports refuse a request unsigned or signed with another token`() {
        for gate in [LoopbackGate.control, .appLink] {
            let host = "127.0.0.1:\(gate.port)"
            #expect(gate.verdict(
                method: "POST", target: "/bottle/run", headers: ["host": host], expectedToken: expected,
            ) == .unauthorized("no X-Sevo-Auth"))
            let wrong = String(repeating: "5f", count: ControlToken.byteCount)
            #expect(gate.verdict(
                method: "POST", target: "/command",
                headers: ["host": host, authHeader: signed("POST", "/command", with: wrong)],
                expectedToken: expected,
            ) == .unauthorized("wrong or stale X-Sevo-Auth"))
            // The token itself, as the old header carried it, is no signature.
            #expect(!gate.admits(
                method: "POST", target: "/command", headers: ["host": host, authHeader: token],
                expectedToken: expected,
            ))
            #expect(gate.admits(
                method: "POST", target: "/command", headers: ["host": host, authHeader: signed("POST", "/command")],
                expectedToken: expected,
            ))
        }
    }

    @Test
    func `a signature covers one request and nothing else`() {
        let host = "127.0.0.1:\(BridgePorts.control)"
        let body = Data("winecfg.exe".utf8)
        let signature = signed("POST", "/bottle/run", body: body)
        func admits(_ method: String, _ target: String, _ body: Data) -> Bool {
            LoopbackGate.control.admits(
                method: method, target: target, headers: ["host": host, authHeader: signature],
                body: body, expectedToken: expected,
            )
        }
        #expect(admits("POST", "/bottle/run", body))
        // Whoever receives it cannot replay it as another verb, on another
        // path or query, or with another program.
        #expect(!admits("GET", "/bottle/run", body))
        #expect(!admits("POST", "/client/stop", body))
        #expect(!admits("POST", "/bottle/run?timeout=600", body))
        #expect(!admits("POST", "/bottle/run", Data("cmd.exe".utf8)))
    }

    @Test
    func `a signature goes stale`() {
        let old = Date.now.addingTimeInterval(-ControlToken.signatureLife - 5)
        let stale = ControlToken.signature(token: token, method: "GET", target: "/status", body: Data(), at: old)
        #expect(!ControlToken.verifies(stale, token: token, method: "GET", target: "/status", body: Data()))
        let early = ControlToken.signature(
            token: token, method: "GET", target: "/status", body: Data(),
            at: .now.addingTimeInterval(ControlToken.signatureLife + 5),
        )
        #expect(!ControlToken.verifies(early, token: token, method: "GET", target: "/status", body: Data()))
        let fresh = ControlToken.signature(token: token, method: "GET", target: "/status", body: Data())
        #expect(ControlToken.verifies(fresh, token: token, method: "GET", target: "/status", body: Data()))
        #expect(!ControlToken.verifies("v1.x.00", token: token, method: "GET", target: "/status", body: Data()))
        #expect(!ControlToken.verifies(nil, token: token, method: "GET", target: "/status", body: Data()))
    }

    @Test
    func `a request is signed over the target it puts on the wire`() throws {
        let url = try #require(URL(string: "http://127.0.0.1:8764/engine/use?version=dormison-r13&x=a%20b"))
        #expect(ControlToken.target(of: url) == "/engine/use?version=dormison-r13&x=a%20b")
        #expect(try ControlToken.target(of: #require(URL(string: "http://127.0.0.1:8764"))) == "/")
    }

    @Test
    func `a token nobody can read admits nobody`() {
        let unreadable: () throws -> String = { throw ControlToken.Failure.foreignOwner("/token") }
        let verdict = LoopbackGate.control.verdict(
            method: "GET", target: "/status",
            headers: ["host": "127.0.0.1:\(BridgePorts.control)", authHeader: signed("GET", "/status")],
            expectedToken: unreadable,
        )
        #expect(verdict == .unauthorized("no usable token: /token belongs to another account"))
    }

    @Test
    func `the token is read only for a request its port guards`() {
        var reads = 0
        let counting: () throws -> String = {
            reads += 1
            return "unused"
        }
        #expect(LoopbackGate.steamUI.admits(
            method: "GET", target: "/index.html",
            headers: ["host": "127.0.0.1:\(BridgePorts.steamUI)", "cookie": cookie],
            expectedToken: counting, session: session,
        ))
        // A refused Origin is answered before the token is looked at.
        #expect(!LoopbackGate.control.admits(
            method: "POST", target: "/quit",
            headers: ["host": "127.0.0.1:\(BridgePorts.control)", "origin": "https://evil.example"],
            expectedToken: counting,
        ))
        #expect(reads == 0)
    }

    @Test
    func `the comparison answers equal only for the same token`() {
        #expect(ControlToken.matches(token, expected: token))
        #expect(!ControlToken.matches(nil, expected: token))
        #expect(!ControlToken.matches("", expected: token))
        #expect(!ControlToken.matches(token.uppercased(), expected: token))
        #expect(!ControlToken.matches("", expected: ""))
    }

    @Test
    func `a web page's simple POST to the control port is refused`() {
        let verdict = LoopbackGate.control.verdict(
            method: "POST", target: "/bottle/run",
            headers: ["host": "127.0.0.1:\(BridgePorts.control)", "origin": "https://evil.example"],
        )
        #expect(verdict == .refused("Origin https://evil.example"))
        #expect(!LoopbackGate.appLink.admits(
            method: "POST", target: "/command", headers: ["host": "127.0.0.1:\(BridgePorts.appLink)", "origin": "null"],
        ))
    }

    @Test
    func `a rebound host name is refused`() {
        #expect(!LoopbackGate.steamUI.admits(
            method: "GET", target: "/__loopback/config/loginusers.vdf",
            headers: ["host": "rebind.evil.example:\(BridgePorts.steamUI)", "cookie": cookie], session: session,
        ))
        #expect(!LoopbackGate.control.admits(method: "GET", target: "/status", headers: [:]))
        // The right name on another port is someone else's request.
        #expect(!LoopbackGate.control.admits(
            method: "GET", target: "/status", headers: ["host": "127.0.0.1:\(BridgePorts.steamUI)"],
        ))
    }

    @Test
    func `the context page's own requests are admitted`() {
        let host = "127.0.0.1:\(BridgePorts.steamUI)"
        #expect(LoopbackGate.steamUI.admits(
            method: "GET", target: "/__web?u=https%3A%2F%2Fstore.steampowered.com%2F",
            headers: ["host": host, "origin": LoopbackGate.pageOrigin, "cookie": "a=b; \(cookie); c=d"],
            session: session,
        ))
        #expect(LoopbackGate.steamUI.admits(
            method: "GET", target: "/index.html", headers: ["host": host, "cookie": cookie], session: session,
        ))
        #expect(LoopbackGate.art.admits(
            method: "GET", target: "/art/440.jpg",
            headers: ["host": "127.0.0.1:\(BridgePorts.art)", "cookie": cookie], session: session,
        ))
    }

    @Test
    func `the page's origin opens nothing without the session cookie`() {
        // What a browser tab sends after a link to the bridge, and what a
        // script served from this origin sends: the right Host and Origin.
        let host = "127.0.0.1:\(BridgePorts.steamUI)"
        for target in ["/", "/index.html?IN_CLIENT=true", "/__web?u=https%3A%2F%2Fx%2F", "/__loopback/steamapps/a.html"] {
            #expect(LoopbackGate.steamUI.verdict(
                method: "GET", target: target, headers: ["host": host], session: session,
            ) == .unauthorized("no session cookie"))
        }
        #expect(LoopbackGate.steamUI.verdict(
            method: "GET", target: "/__web?u=x",
            headers: ["host": host, "origin": LoopbackGate.pageOrigin, "cookie": "\(LoopbackSession.cookieName)=\(token)"],
            session: session,
        ) == .unauthorized("wrong session cookie"))
        #expect(!LoopbackGate.art.admits(
            method: "GET", target: "/art/440.jpg", headers: ["host": "127.0.0.1:\(BridgePorts.art)"], session: session,
        ))
        let page = [
            (name: "Host", value: "127.0.0.1:\(BridgePorts.pageWS)"), (name: "Origin", value: LoopbackGate.pageOrigin),
        ]
        #expect(WebSocketServer.handshakeStatus(page, gate: .pageWS) == .reject)
    }

    @Test
    func `the session cookie is found among others and only under its own name`() {
        #expect(LoopbackSession.cookie(in: "sevo_session=abc") == "abc")
        #expect(LoopbackSession.cookie(in: "x=1; sevo_session=abc; y=2") == "abc")
        #expect(LoopbackSession.cookie(in: "xsevo_session=abc") == nil)
        #expect(LoopbackSession.cookie(in: "sevo_session2=abc") == nil)
        #expect(LoopbackSession.cookie(in: nil) == nil)
        #expect(LoopbackSession.key != LoopbackSession.relayKey)
    }

    @Test
    func `eval needs the signature, whoever sends it`() {
        let host = "127.0.0.1:\(BridgePorts.steamUI)"
        let body = Data("1+1".utf8)
        let signature = signed("POST", "/__eval", body: body)
        #expect(LoopbackGate.steamUI.verdict(
            method: "POST", target: "/__eval", headers: ["host": host], body: body, expectedToken: expected,
        ) == .unauthorized("no X-Sevo-Auth"))
        #expect(!LoopbackGate.steamUI.admits(
            method: "POST", target: "/__eval",
            headers: ["host": host, "origin": "https://evil.example", authHeader: signature],
            body: body, expectedToken: expected,
        ))
        // The page itself is refused too: its cookie is no token.
        #expect(!LoopbackGate.steamUI.admits(
            method: "POST", target: "/__eval",
            headers: ["host": host, "origin": LoopbackGate.pageOrigin, "cookie": cookie],
            body: body, expectedToken: expected, session: session,
        ))
        // BridgeEval and PageProbe: Host, the signature, no Origin.
        #expect(LoopbackGate.steamUI.admits(
            method: "POST", target: "/__eval", headers: ["host": host, authHeader: signature],
            body: body, expectedToken: expected,
        ))
    }

    @Test
    func `a WebSocket handshake from a web page is refused`() {
        let fields = [(name: "Host", value: "127.0.0.1:\(BridgePorts.pageWS)"), (name: "Origin", value: "https://evil.example")]
        #expect(WebSocketServer.handshakeStatus(fields, gate: .pageWS) == .reject)
        let relay = [(name: "Host", value: "127.0.0.1:\(BridgePorts.relayWS)"), (name: "Origin", value: "https://evil.example")]
        #expect(WebSocketServer.handshakeStatus(relay, gate: .relayWS) == .reject)
    }

    @Test
    func `each socket admits its own peer and only that one`() {
        let own = "\(LoopbackSession.cookieName)=\(LoopbackSession.key)"
        let client = [(name: "Host", value: "127.0.0.1:\(BridgePorts.relayWS)"), (name: "Origin", value: "https://steamloopback.host")]
        #expect(WebSocketServer.handshakeStatus(client, gate: .relayWS) == .accept)
        let page = [
            (name: "Host", value: "127.0.0.1:\(BridgePorts.pageWS)"),
            (name: "Origin", value: "http://127.0.0.1:\(BridgePorts.steamUI)"), (name: "Cookie", value: own),
        ]
        #expect(WebSocketServer.handshakeStatus(page, gate: .pageWS) == .accept)
        // The page may not take the relay's place, nor the client the page's.
        let pageOnRelay = [(name: "Host", value: "127.0.0.1:\(BridgePorts.relayWS)"), (name: "Origin", value: "http://127.0.0.1:\(BridgePorts.steamUI)")]
        #expect(WebSocketServer.handshakeStatus(pageOnRelay, gate: .relayWS) == .reject)
        let clientOnPage = [
            (name: "Host", value: "127.0.0.1:\(BridgePorts.pageWS)"),
            (name: "Origin", value: "https://steamloopback.host"), (name: "Cookie", value: own),
        ]
        #expect(WebSocketServer.handshakeStatus(clientOnPage, gate: .pageWS) == .reject)
    }

    @Test
    func `the first message that makes a socket a peer is the hello`() {
        #expect(SteamBridge.isHello(#"{"type":"hello"}"#))
        #expect(!SteamBridge.isHello(#"{"cmd":"sc","id":1,"path":"SteamClient.Apps.RunGame"}"#))
        #expect(!SteamBridge.isHello("hello"))
    }

    @Test
    func `the relay's hello carries the key the bridge gave its script`() {
        let key = String(repeating: "c3", count: ControlToken.byteCount)
        #expect(SteamBridge.isRelayHello(#"{"type":"hello","key":"\#(key)"}"#, key: key))
        // Any local process can open the socket and say hello.
        #expect(!SteamBridge.isRelayHello(#"{"type":"hello"}"#, key: key))
        #expect(!SteamBridge.isRelayHello(#"{"type":"hello","key":"\#(session)"}"#, key: key))
        #expect(!SteamBridge.isRelayHello(#"{"type":"hello","key":7}"#, key: key))
    }

    @Test
    func `a response is one status line and its own headers, whatever the request said`() throws {
        // The reply to `/__web?u=https://x%0D%0AContent-Type: text/html…/`,
        // whose decoded host once went into the reason.
        let hostile = "Forbidden — x\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nproof is not a Steam host"
        var response = HTTPResponse.error(403, hostile)
        response.headers.append(("X-Echo", "a\r\nSet-Cookie: b=c"))
        let wire = try #require(String(data: HTTPServer.wire(response), encoding: .utf8))
        let head = try #require(wire.components(separatedBy: "\r\n\r\n").first)
        let lines = head.components(separatedBy: "\r\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("HTTP/1.1 403 Forbidden — x"))
        #expect(lines[1] == "Content-Type: text/plain")
        #expect(lines[2] == "X-Echo: aSet-Cookie: b=c")
        #expect(lines[3].hasPrefix("Content-Length: "))
        // The proxy's own refusal says nothing of the request at all.
        guard case let .failure(rejection) = WebProxy.target(
            method: "GET", query: "u=https%3A%2F%2Fx%250D%250AContent-Type%253A%2520text%252Fhtml%2F",
        ) else {
            Issue.record("a host that is no Steam host was accepted")
            return
        }
        #expect(rejection.reason == "Forbidden")
    }

    @Test
    func `a document that is not the page gets no origin`() {
        func policy(_ type: String) -> String? {
            SteamBridge.contained(.ok(Data(), type: type)).headers.first { $0.0 == "Content-Security-Policy" }?.1
        }
        #expect(policy("text/html; charset=utf-8") == "sandbox allow-scripts")
        #expect(policy("image/svg+xml") == "sandbox allow-scripts")
        #expect(policy("application/xhtml+xml") == "sandbox allow-scripts")
        #expect(policy("application/javascript") == nil)
        #expect(policy("image/png") == nil)
        let sniff = SteamBridge.contained(.ok(Data(), type: "image/png")).headers.first { $0.0 == "X-Content-Type-Options" }?.1
        #expect(sniff == "nosniff")
    }

    @Test
    func `a private folder is refused under any name the disk folds onto it`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["config", "userdata", "steamapps"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true,
            )
        }
        // U+FB01 and U+017F: APFS opens `config` and `userdata` for these,
        // and neither lowercases to the name the blocklist holds.
        for path in ["/con\u{FB01}g/loginusers.vdf", "/u\u{17F}erdata/1/config.vdf", "/CONFIG/a", "/config/a"] {
            let encoded = try #require(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
            #expect(LoopbackAssets.opensPrivateDirectory(encoded, under: root), "\(path)")
        }
        #expect(!LoopbackAssets.opensPrivateDirectory("/steamapps/appmanifest_440.acf", under: root))
        #expect(!LoopbackAssets.opensPrivateDirectory("/missing/a", under: root))
    }

    @Test
    func `the DevTools session goes only to the DevTools port`() throws {
        let port = BridgePorts.cdp
        #expect(try CDPClient.isOwnEndpoint(#require(URL(string: "ws://127.0.0.1:\(port)/devtools/page/A1")), port: port))
        #expect(try CDPClient.isOwnEndpoint(#require(URL(string: "ws://localhost:\(port)/devtools/page/A1")), port: port))
        #expect(try !CDPClient.isOwnEndpoint(#require(URL(string: "ws://evil.example:\(port)/devtools/page/A1")), port: port))
        #expect(try !CDPClient.isOwnEndpoint(#require(URL(string: "ws://127.0.0.1:9/devtools/page/A1")), port: port))
        #expect(try !CDPClient.isOwnEndpoint(#require(URL(string: "wss://127.0.0.1:\(port)/x")), port: port))
        #expect(SteamBridge.scriptSafeJSON(#"{"a":"</script><script>alert(1)</script>"}"#)?.contains("</script>") == false)
        #expect(SteamBridge.scriptSafeJSON("alert(1)") == nil)
    }
}
