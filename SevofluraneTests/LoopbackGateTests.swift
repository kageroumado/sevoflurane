import Foundation
import Network
import Testing
@testable import Sevoflurane

/// The one check between a web page in the user's browser and the app's
/// loopback ports. Each legitimate caller's request shape is admitted here as
/// it is actually sent, so a gate that grows stricter fails a test before it
/// fails the CLI, the daemon or Steam's relay.
struct LoopbackGateTests {
    private let evalHeader = BridgePorts.evalHeader.lowercased()

    @Test
    func `the CLI's request to the control port is admitted`() {
        // URLSession and curl send Host and no Origin.
        #expect(LoopbackGate.control.admits(
            method: "POST", path: "/bottle/run", headers: ["host": "127.0.0.1:8764"],
        ))
        #expect(LoopbackGate.control.admits(
            method: "GET", path: "/status", headers: ["host": "localhost:8764", "user-agent": "curl/8.7.1"],
        ))
    }

    @Test
    func `a web page's simple POST to the control port is refused`() {
        let verdict = LoopbackGate.control.verdict(
            method: "POST", path: "/bottle/run",
            headers: ["host": "127.0.0.1:8764", "origin": "https://evil.example"],
        )
        #expect(verdict == .refused("Origin https://evil.example"))
        #expect(!LoopbackGate.appLink.admits(
            method: "POST", path: "/command", headers: ["host": "127.0.0.1:8766", "origin": "null"],
        ))
    }

    @Test
    func `a rebound host name is refused`() {
        #expect(!LoopbackGate.steamUI.admits(
            method: "GET", path: "/__loopback/config/loginusers.vdf",
            headers: ["host": "rebind.evil.example:8762"],
        ))
        #expect(!LoopbackGate.control.admits(method: "GET", path: "/status", headers: [:]))
        // The right name on another port is someone else's request.
        #expect(!LoopbackGate.control.admits(
            method: "GET", path: "/status", headers: ["host": "127.0.0.1:8762"],
        ))
    }

    @Test
    func `the context page's own requests are admitted`() {
        #expect(LoopbackGate.steamUI.admits(
            method: "GET", path: "/__web",
            headers: ["host": "127.0.0.1:8762", "origin": "http://127.0.0.1:8762"],
        ))
        #expect(LoopbackGate.steamUI.admits(
            method: "GET", path: "/index.html", headers: ["host": "127.0.0.1:8762"],
        ))
    }

    @Test
    func `eval needs its header, whoever sends it`() {
        #expect(!LoopbackGate.steamUI.admits(
            method: "POST", path: "/__eval", headers: ["host": "127.0.0.1:8762"],
        ))
        #expect(!LoopbackGate.steamUI.admits(
            method: "POST", path: "/__eval",
            headers: ["host": "127.0.0.1:8762", "origin": "https://evil.example", evalHeader: "1"],
        ))
        // BridgeEval and PageProbe: Host, the header, no Origin.
        #expect(LoopbackGate.steamUI.admits(
            method: "POST", path: "/__eval", headers: ["host": "127.0.0.1:8762", evalHeader: "1"],
        ))
    }

    @Test
    func `a WebSocket handshake from a web page is refused`() {
        let fields = [(name: "Host", value: "127.0.0.1:8761"), (name: "Origin", value: "https://evil.example")]
        #expect(WebSocketServer.handshakeStatus(fields, gate: .pageWS) == .reject)
        let relay = [(name: "Host", value: "127.0.0.1:8763"), (name: "Origin", value: "https://evil.example")]
        #expect(WebSocketServer.handshakeStatus(relay, gate: .relayWS) == .reject)
    }

    @Test
    func `each socket admits its own peer and only that one`() {
        let client = [(name: "Host", value: "127.0.0.1:8763"), (name: "Origin", value: "https://steamloopback.host")]
        #expect(WebSocketServer.handshakeStatus(client, gate: .relayWS) == .accept)
        let page = [(name: "Host", value: "127.0.0.1:8761"), (name: "Origin", value: "http://127.0.0.1:8762")]
        #expect(WebSocketServer.handshakeStatus(page, gate: .pageWS) == .accept)
        // The page may not take the relay's place, nor the client the page's.
        let pageOnRelay = [(name: "Host", value: "127.0.0.1:8763"), (name: "Origin", value: "http://127.0.0.1:8762")]
        #expect(WebSocketServer.handshakeStatus(pageOnRelay, gate: .relayWS) == .reject)
        let clientOnPage = [(name: "Host", value: "127.0.0.1:8761"), (name: "Origin", value: "https://steamloopback.host")]
        #expect(WebSocketServer.handshakeStatus(clientOnPage, gate: .pageWS) == .reject)
    }

    @Test
    func `the first message that makes a socket a peer is the hello`() {
        #expect(SteamBridge.isHello(#"{"type":"hello"}"#))
        #expect(!SteamBridge.isHello(#"{"cmd":"sc","id":1,"path":"SteamClient.Apps.RunGame"}"#))
        #expect(!SteamBridge.isHello("hello"))
    }
}
