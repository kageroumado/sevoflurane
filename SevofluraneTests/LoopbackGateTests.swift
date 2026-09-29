import Foundation
import Network
import Testing
@testable import Sevoflurane

/// The one check between a web page in the user's browser and the app's
/// loopback ports. Each legitimate caller's request shape is admitted here as
/// it is actually sent, so a gate that grows stricter fails a test before it
/// fails the CLI, the daemon or Steam's relay.
struct LoopbackGateTests {
    private let tokenHeader = ControlToken.header.lowercased()
    private let token = String(repeating: "5e", count: ControlToken.byteCount)
    private var expected: () throws -> String {
        { [token] in token }
    }

    @Test
    func `the CLI's request to the control port is admitted`() {
        // URLSession and curl send Host, the token, and no Origin.
        #expect(LoopbackGate.control.admits(
            method: "POST", path: "/bottle/run",
            headers: ["host": "127.0.0.1:\(BridgePorts.control)", tokenHeader: token],
            expectedToken: expected,
        ))
        #expect(LoopbackGate.control.admits(
            method: "GET", path: "/status",
            headers: ["host": "localhost:\(BridgePorts.control)", "user-agent": "curl/8.7.1", tokenHeader: token],
            expectedToken: expected,
        ))
    }

    @Test
    func `the control and link ports refuse a request without the token or with the wrong one`() {
        for gate in [LoopbackGate.control, .appLink] {
            let host = "127.0.0.1:\(gate.port)"
            #expect(gate.verdict(
                method: "POST", path: "/bottle/run", headers: ["host": host], expectedToken: expected,
            ) == .unauthorized("no X-Sevo-Token"))
            #expect(gate.verdict(
                method: "GET", path: "/status", headers: ["host": host], expectedToken: expected,
            ) == .unauthorized("no X-Sevo-Token"))
            let wrong = String(repeating: "5f", count: ControlToken.byteCount)
            #expect(gate.verdict(
                method: "POST", path: "/command", headers: ["host": host, tokenHeader: wrong],
                expectedToken: expected,
            ) == .unauthorized("wrong X-Sevo-Token"))
            // A prefix of the token, or the token with more after it, is a
            // different token.
            #expect(!gate.admits(
                method: "POST", path: "/command", headers: ["host": host, tokenHeader: String(token.dropLast())],
                expectedToken: expected,
            ))
            #expect(!gate.admits(
                method: "POST", path: "/command", headers: ["host": host, tokenHeader: token + "0"],
                expectedToken: expected,
            ))
            #expect(gate.admits(
                method: "POST", path: "/command", headers: ["host": host, tokenHeader: token],
                expectedToken: expected,
            ))
        }
    }

    @Test
    func `a token nobody can read admits nobody`() {
        let unreadable: () throws -> String = { throw ControlToken.Failure.foreignOwner("/token") }
        let verdict = LoopbackGate.control.verdict(
            method: "GET", path: "/status",
            headers: ["host": "127.0.0.1:\(BridgePorts.control)", tokenHeader: token],
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
            method: "GET", path: "/index.html", headers: ["host": "127.0.0.1:\(BridgePorts.steamUI)"],
            expectedToken: counting,
        ))
        // A refused Origin is answered before the token is looked at.
        #expect(!LoopbackGate.control.admits(
            method: "POST", path: "/quit",
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
            method: "POST", path: "/bottle/run",
            headers: ["host": "127.0.0.1:\(BridgePorts.control)", "origin": "https://evil.example"],
        )
        #expect(verdict == .refused("Origin https://evil.example"))
        #expect(!LoopbackGate.appLink.admits(
            method: "POST", path: "/command", headers: ["host": "127.0.0.1:\(BridgePorts.appLink)", "origin": "null"],
        ))
    }

    @Test
    func `a rebound host name is refused`() {
        #expect(!LoopbackGate.steamUI.admits(
            method: "GET", path: "/__loopback/config/loginusers.vdf",
            headers: ["host": "rebind.evil.example:\(BridgePorts.steamUI)"],
        ))
        #expect(!LoopbackGate.control.admits(method: "GET", path: "/status", headers: [:]))
        // The right name on another port is someone else's request.
        #expect(!LoopbackGate.control.admits(
            method: "GET", path: "/status", headers: ["host": "127.0.0.1:\(BridgePorts.steamUI)"],
        ))
    }

    @Test
    func `the context page's own requests are admitted`() {
        #expect(LoopbackGate.steamUI.admits(
            method: "GET", path: "/__web",
            headers: ["host": "127.0.0.1:\(BridgePorts.steamUI)", "origin": "http://127.0.0.1:\(BridgePorts.steamUI)"],
        ))
        #expect(LoopbackGate.steamUI.admits(
            method: "GET", path: "/index.html", headers: ["host": "127.0.0.1:\(BridgePorts.steamUI)"],
        ))
    }

    @Test
    func `eval needs the token, whoever sends it`() {
        let host = "127.0.0.1:\(BridgePorts.steamUI)"
        #expect(LoopbackGate.steamUI.verdict(
            method: "POST", path: "/__eval", headers: ["host": host], expectedToken: expected,
        ) == .unauthorized("no X-Sevo-Token"))
        #expect(!LoopbackGate.steamUI.admits(
            method: "GET", path: "/__eval", headers: ["host": host], expectedToken: expected,
        ))
        #expect(!LoopbackGate.steamUI.admits(
            method: "POST", path: "/__eval",
            headers: ["host": host, "origin": "https://evil.example", tokenHeader: token],
            expectedToken: expected,
        ))
        // The page itself is refused too: it can never hold the token.
        #expect(!LoopbackGate.steamUI.admits(
            method: "POST", path: "/__eval", headers: ["host": host, "origin": LoopbackGate.pageOrigin],
            expectedToken: expected,
        ))
        // BridgeEval and PageProbe: Host, the token, no Origin.
        #expect(LoopbackGate.steamUI.admits(
            method: "POST", path: "/__eval", headers: ["host": host, tokenHeader: token],
            expectedToken: expected,
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
        let client = [(name: "Host", value: "127.0.0.1:\(BridgePorts.relayWS)"), (name: "Origin", value: "https://steamloopback.host")]
        #expect(WebSocketServer.handshakeStatus(client, gate: .relayWS) == .accept)
        let page = [(name: "Host", value: "127.0.0.1:\(BridgePorts.pageWS)"), (name: "Origin", value: "http://127.0.0.1:\(BridgePorts.steamUI)")]
        #expect(WebSocketServer.handshakeStatus(page, gate: .pageWS) == .accept)
        // The page may not take the relay's place, nor the client the page's.
        let pageOnRelay = [(name: "Host", value: "127.0.0.1:\(BridgePorts.relayWS)"), (name: "Origin", value: "http://127.0.0.1:\(BridgePorts.steamUI)")]
        #expect(WebSocketServer.handshakeStatus(pageOnRelay, gate: .relayWS) == .reject)
        let clientOnPage = [(name: "Host", value: "127.0.0.1:\(BridgePorts.pageWS)"), (name: "Origin", value: "https://steamloopback.host")]
        #expect(WebSocketServer.handshakeStatus(clientOnPage, gate: .pageWS) == .reject)
    }

    @Test
    func `the first message that makes a socket a peer is the hello`() {
        #expect(SteamBridge.isHello(#"{"type":"hello"}"#))
        #expect(!SteamBridge.isHello(#"{"cmd":"sc","id":1,"path":"SteamClient.Apps.RunGame"}"#))
        #expect(!SteamBridge.isHello("hello"))
    }
}
