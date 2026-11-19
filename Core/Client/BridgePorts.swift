import Foundation

/// The loopback ports between the app, its pages and the bottled client; the
/// bridge sits in the middle because Chromium rejects the page's own CDP
/// WebSocket by Origin. All sit in the 876x block (877x for Debug,
/// ``AppIdentity``): never at or above 49152, where macOS's ephemeral ports
/// start, and never 808x, where dev servers squat and would answer CDP probes.
nonisolated enum BridgePorts {
    /// The bottled client's `-devtools-port` (outbound).
    static let cdp = 8765 + AppIdentity.portOffset
    /// Capsule art for the menu-bar extra.
    static let art: UInt16 = 8760 + UInt16(AppIdentity.portOffset)
    /// The page's command socket (dialed by the shim).
    static let pageWS: UInt16 = 8761 + UInt16(AppIdentity.portOffset)
    /// Steam's UI bundle with the shim injected, plus `POST /__eval`.
    static let steamUI: UInt16 = 8762 + UInt16(AppIdentity.portOffset)
    /// The transport relay (dialed by SharedJSContext itself).
    static let relayWS: UInt16 = 8763 + UInt16(AppIdentity.portOffset)
    /// The daemon's control endpoint for `sevo`'s mutating verbs.
    static let control: UInt16 = 8764 + UInt16(AppIdentity.portOffset)
    /// The app's half of the daemon link.
    static let appLink: UInt16 = 8766 + UInt16(AppIdentity.portOffset)
}
