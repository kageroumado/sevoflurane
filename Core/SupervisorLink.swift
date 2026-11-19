import Foundation

/// The contract between the app and the daemon that owns the bottle.
///
/// Two loopback HTTP listeners, each pushing to the other: the daemon serves
/// the control port (``BridgePorts/control``) that `sevo` speaks to, and the
/// app serves ``BridgePorts/appLink``. The daemon sends commands and the app
/// sends facts; no message waits on an answer.
///
/// With no app the daemon keeps the client alive and answers `sevo`; with no
/// daemon the app has no supervision and says so.
nonisolated enum SupervisorLink {
    /// Where the daemon's registration and its socket-adjacent state live.
    static let label = "\(AppIdentity.identifierStem).daemon"
    /// The `SMAppService.agent(plistName:)` name, in the app bundle's
    /// `Contents/Library/LaunchAgents`.
    static let launchAgentPlistName = "SevofluraneDaemon.plist"
}

/// Where the app process stands relative to the daemon, as `sevo status` and
/// `sevo doctor` report it.
///
/// The daemon's `/status` says "running" only for an attached app. After a
/// daemon rebuild, a live app answers its own link port before it reattaches,
/// so the CLI probes that port and reports the app as running.
nonisolated enum AppRunState: String, Equatable, Sendable {
    case notRunning = "not running"
    case detached = "running, reattaching"
    case attached = "running"

    /// `daemonReportsAttached` is the daemon `/status` `app` field reading
    /// "running"; `appLinkAlive` is the app answering its own link port.
    static func classify(daemonReportsAttached: Bool, appLinkAlive: Bool) -> AppRunState {
        if daemonReportsAttached { return .attached }
        return appLinkAlive ? .detached : .notRunning
    }

    var isRunning: Bool { self != .notRunning }

    var doctorLabel: String {
        switch self {
        case .attached: "Sevoflurane app: running"
        case .detached: "Sevoflurane app: running, reattaching to the background helper"
        case .notRunning: "Sevoflurane app: not running (the daemon keeps the client up without it)"
        }
    }
}

/// What the app knows and the daemon cannot see for itself: the page's login
/// window and the bridge's socket to the client. Posted whenever either
/// changes, and once on every attach.
///
/// The daemon treats a fact as true until updated: the app is the only
/// writer, and a dead app is detached rather than stale.
nonisolated struct PageFacts: Codable, Equatable, Sendable {
    /// The app process, so the daemon can tell a reconnect from a relaunch.
    var appPID: Int32 = 0
    /// The page holds Steam's login window. Every recovery timer consults it,
    /// because a signed-out client is a steady state and their reloads quit Steam.
    var isAwaitingSignIn = false
    /// The bridge's socket to the client's `SharedJSContext` is open. While it
    /// is, a DevTools server too busy to answer `/json` must not be restarted.
    var isClientConnected = false
    /// The app's short version, for the daemon's log and `sevo status`.
    var appVersion = "0"
}

/// What the daemon asks of the app, which owns the WKWebViews, Steam's popups
/// and the bridge.
nonisolated enum PageCommand: String, Codable, Sendable {
    /// The app answers by posting `isClientConnected`, so a page is never
    /// booted into a bridge that cannot yet reach the client.
    case connectToClient
    /// A new client invalidates CLIENT_SESSION and the transport ports, so
    /// the page must come again through the bridge's 302.
    case reload
    /// Two reloads changed nothing, so the web view itself is what is wedged.
    case rebuild
    /// Take the dead client's frozen windows off screen.
    case dismissWindows
    /// Told as a quit so the popups' teardown is not reported to Steam as
    /// the user closing them.
    case dismissWindowsForQuit
    /// Window requests the stopping client makes are answered with nothing.
    case clientStopBegan
    case clientStopEnded
    /// After sign-in, because ending in silence reads as a crash.
    case showLibrary
}

/// The supervisor's verdict as it crosses the link, and as `sevo status`
/// prints it; `sevo` reads `health` and `detail`, so keep their names.
nonisolated struct SupervisorSnapshot: Codable, Equatable, Sendable {
    var health = "starting"
    var detail = ""
    var needsAttention = false
    /// While set, control verbs that would race the restart ladder refuse.
    var isBusyRestarting = false
    /// The app version the daemon shipped with.
    var version = "0"
    /// The running daemon's build (``MachOIdentity``), which tells a rebuilt
    /// daemon of the same version from the one still in memory.
    var build: String?
    /// Set while the host pressure is elevated.
    var host: HostPressure?
    /// The session the client lost to another sign-in of its account, while
    /// it stays lost; reported beside a healthy verdict.
    var signedInElsewhere: SteamSessionLoss?

    init(
        health: String = "starting",
        detail: String = "",
        needsAttention: Bool = false,
        isBusyRestarting: Bool = false,
        version: String = "0",
        build: String? = nil,
        host: HostPressure? = nil,
        signedInElsewhere: SteamSessionLoss? = nil,
    ) {
        self.health = health
        self.detail = detail
        self.needsAttention = needsAttention
        self.isBusyRestarting = isBusyRestarting
        self.version = version
        self.build = build
        self.host = host
        self.signedInElsewhere = signedInElsewhere
    }

    init(
        _ health: SupervisorHealth, isBusyRestarting: Bool, version: String, build: String? = nil,
        host: HostPressure? = nil, signedInElsewhere: SteamSessionLoss? = nil,
    ) {
        self.init(
            health: health.wireName,
            detail: health.statusText,
            needsAttention: health.needsAttention,
            isBusyRestarting: isBusyRestarting,
            version: version,
            build: build,
            host: host,
            signedInElsewhere: signedInElsewhere,
        )
    }

    var supervisorHealth: SupervisorHealth {
        SupervisorHealth(wireName: health, detail: detail)
    }
}

/// One log line the daemon wrote, mirrored in memory to the app's menu-bar
/// trail and log window; the shared log file already has it.
nonisolated struct RemoteLogLine: Codable, Equatable, Sendable {
    var category: String
    var message: String
    var date: Date
}
