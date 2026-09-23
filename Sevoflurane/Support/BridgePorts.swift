import Foundation

/// Everything the bridge listens on, and the one port it dials out to — the
/// loopback contract between the app, its pages, and the bottled client.
/// The page cannot open the CDP WebSocket itself (Chromium rejects
/// browser-originated connections by Origin header), so the bridge is the
/// neutral middleman between the app's page and the bottled client.
///
/// Every port sits in one 876x block, and deliberately below 49152: that is
/// where macOS starts handing out ephemeral ports
/// (`net.inet.ip.portrange.first`), so a fixed listener up there races the
/// random ones the OS assigns to outbound sockets. The 808x range is the
/// other trap — it is the default for so many dev servers that a squatter
/// there is normal, and one on the CDP port answers our probes while the
/// client is still down.
nonisolated enum BridgePorts {
    /// The bottled client's `-devtools-port` (outbound).
    static let cdp = 8765
    /// Capsule art for the menu-bar extra.
    static let art: UInt16 = 8760
    /// The page's command socket (dialed by the shim).
    static let pageWS: UInt16 = 8761
    /// Steam's UI bundle with the shim injected, plus `POST /__eval`.
    static let steamUI: UInt16 = 8762
    /// The transport relay (dialed by SharedJSContext itself).
    static let relayWS: UInt16 = 8763
    /// The daemon's control endpoint for the `sevo` CLI: every mutating verb
    /// routes through the supervisor it holds — one owner for the restart
    /// ladder, in the one process that outlives the app.
    static let control: UInt16 = 8764
    /// The app's half of the daemon link: page commands, and the page verbs
    /// the daemon proxies through from the control port.
    static let appLink: UInt16 = 8766

    /// The header every `POST /__eval` carries. A web page can send a custom
    /// header cross-origin only after a CORS preflight the bridge never
    /// answers, so its presence says the caller is a local program.
    static let evalHeader = "X-Sevo-Eval"
}
