import Foundation

/// Everything the bridge listens on, and the one port it dials out to — the
/// loopback contract between the app, its pages, and the bottled client.
/// The page cannot open the CDP WebSocket itself (Chromium rejects
/// browser-originated connections by Origin header), so the bridge is the
/// neutral middleman between the app's page and the bottled client.
nonisolated enum BridgePorts {
    /// The bottled client's `-devtools-port` (outbound).
    static let cdp = 8081
    /// Capsule art for the menu-bar extra.
    static let art: UInt16 = 8760
    /// The page's command socket (dialed by the shim).
    static let pageWS: UInt16 = 8761
    /// Steam's UI bundle with the shim injected, plus `POST /__eval`.
    static let steamUI: UInt16 = 8762
    /// The transport relay (dialed by SharedJSContext itself).
    static let relayWS: UInt16 = 8763
    /// The app's control endpoint for the `sevo` CLI: when the app is
    /// running, mutating verbs route through its supervisor — one owner for
    /// the restart ladder.
    static let control: UInt16 = 8764
}
