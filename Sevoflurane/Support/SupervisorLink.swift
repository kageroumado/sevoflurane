import Foundation

/// The contract between the app and the daemon that owns the bottle.
///
/// Two loopback HTTP listeners, each pushing to the other: the daemon serves
/// the control port (``BridgePorts/control``) that `sevo` has always spoken to,
/// and the app serves ``BridgePorts/appLink``. Nothing polls and nothing
/// correlates — the daemon sends commands and the app sends facts, so a
/// message is a statement, never a question waiting on an answer.
///
/// Neither side is required for the other to work. With no app the daemon
/// keeps the client alive and answers `sevo`; with no daemon the app has no
/// supervision at all and says so, because a supervisor inside the app is the
/// thing this split exists to remove.
nonisolated enum SupervisorLink {
    /// Where the daemon's registration and its socket-adjacent state live.
    static let label = "glass.kagerou.sevoflurane.daemon"
    /// The `SMAppService.agent(plistName:)` name — the plist copied into the
    /// app bundle's `Contents/Library/LaunchAgents`.
    static let launchAgentPlistName = "SevofluraneDaemon.plist"
}

/// What the app knows and the daemon cannot see for itself: the page's login
/// window and the bridge's socket to the client. Posted whenever either
/// changes, and once on every attach.
///
/// The daemon treats a fact it has not heard in a while as still true — the
/// app is the only writer, so a missing update means nothing changed, and a
/// dead app is detached rather than stale.
nonisolated struct PageFacts: Codable, Equatable, Sendable {
    /// The app process, so the daemon can tell a reconnect from a relaunch.
    var appPID: Int32 = 0
    /// The page holds Steam's login window. Every recovery timer consults it:
    /// a signed-out client is a steady state, not a failed boot, and the
    /// reloads those timers end in are what quit Steam.
    var isAwaitingSignIn = false
    /// The bridge's socket to the client's `SharedJSContext` is open. A
    /// DevTools server too busy to answer `/json` on a client whose socket is
    /// still live is slow, not gone, and must not be restarted for it.
    var isClientConnected = false
    /// The app's short version, for the daemon's log and `sevo status`.
    var appVersion = "0"
}

/// What the daemon asks of the page. Every one of these is work only the app
/// can do — it owns the WKWebViews, Steam's popups and the bridge.
nonisolated enum PageCommand: String, Codable, Sendable {
    /// Bring the bridge's connection to the client up. The app answers by
    /// posting `isClientConnected`, so a page is never booted into a bridge
    /// that cannot yet reach the client.
    case connectToClient
    /// Reload the UI page — a new client invalidates CLIENT_SESSION and the
    /// transport ports, so the page has to come again through the bridge's 302.
    case reload
    /// Two reloads changed nothing, so the web view itself is what is wedged.
    case rebuild
    /// Take the dead client's frozen windows off screen.
    case dismissWindows
    /// The same, told as a quit so the popups' teardown is not reported to
    /// Steam as the user closing them.
    case dismissWindowsForQuit
    /// The client is coming down; window requests it makes on the way out are
    /// answered with nothing.
    case clientStopBegan
    case clientStopEnded
    /// Sign-in finished — open the library, because ending in silence reads
    /// as a crash.
    case showLibrary
}

/// The supervisor's verdict as it crosses the link, and as `sevo status`
/// prints it. `health` and `detail` are the two fields `sevo` has always read.
nonisolated struct SupervisorSnapshot: Codable, Equatable, Sendable {
    var health = "starting"
    var detail = ""
    var needsAttention = false
    /// Whether the restart ladder is mid-flight — control verbs that would
    /// race it refuse instead of interleaving.
    var isBusyRestarting = false
    /// The daemon's short version, which is the app version it shipped with.
    var version = "0"

    init(
        health: String = "starting",
        detail: String = "",
        needsAttention: Bool = false,
        isBusyRestarting: Bool = false,
        version: String = "0",
    ) {
        self.health = health
        self.detail = detail
        self.needsAttention = needsAttention
        self.isBusyRestarting = isBusyRestarting
        self.version = version
    }

    init(_ health: SupervisorHealth, isBusyRestarting: Bool, version: String) {
        self.init(
            health: health.wireName,
            detail: health.statusText,
            needsAttention: health.needsAttention,
            isBusyRestarting: isBusyRestarting,
            version: version,
        )
    }

    var supervisorHealth: SupervisorHealth {
        SupervisorHealth(wireName: health, detail: detail)
    }
}

/// One log line the daemon wrote, mirrored to the app so the menu-bar trail
/// and the log window show the whole story. The file both processes append to
/// already has it; this is the in-memory half.
nonisolated struct RemoteLogLine: Codable, Equatable, Sendable {
    var category: String
    var message: String
    var date: Date
}
