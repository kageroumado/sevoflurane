import Foundation
import Testing
@testable import Sevoflurane

/// What the bridge does with the page's messages before they reach the
/// client: every one of them becomes source evaluated in `SharedJSContext` or
/// bytes on the relay.
struct SteamBridgeTests {
    @Test
    func `a dotted SteamClient member path is forwarded`() {
        #expect(SteamBridge.isSteamClientPath("SteamClient.Apps.RunGame"))
        #expect(SteamBridge.isSteamClientPath("SteamClient.Window.SetResizeGrip"))
        #expect(SteamBridge.isSteamClientPath("SteamClient.$x._y9"))
    }

    @Test
    func `a path that is not only identifiers is refused`() {
        #expect(!SteamBridge.isSteamClientPath("SteamClient.x);alert(1)//"))
        #expect(!SteamBridge.isSteamClientPath("SteamClient.a b"))
        #expect(!SteamBridge.isSteamClientPath("SteamClient."))
        #expect(!SteamBridge.isSteamClientPath("SteamClient..a"))
        #expect(!SteamBridge.isSteamClientPath("SteamClient"))
        #expect(!SteamBridge.isSteamClientPath("window.SteamClient.Apps"))
        #expect(!SteamBridge.isSteamClientPath("SteamClient.9a"))
        #expect(!SteamBridge.isSteamClientPath("SteamClient.Apps[\"RunGame\"]"))
    }

    @Test
    func `a relay frame is the id behind its length, then the payload`() {
        let frame = SteamBridge.frame(tid: "p1_t2", payload: Data([0xAA, 0xBB]))
        #expect(frame == Data([5]) + Data("p1_t2".utf8) + Data([0xAA, 0xBB]))
    }

    @Test
    func `a tunnel id longer than 255 bytes makes no frame`() {
        #expect(SteamBridge.frame(tid: String(repeating: "a", count: 255), payload: Data())?.count == 256)
        #expect(SteamBridge.frame(tid: String(repeating: "a", count: 256), payload: Data()) == nil)
        // Bytes, not characters: 128 two-byte characters are 256 bytes.
        #expect(SteamBridge.frame(tid: String(repeating: "é", count: 128), payload: Data()) == nil)
    }
}
