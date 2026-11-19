import Foundation

/// What supervision reports: the daemon derives it, the app renders it,
/// `sevo` prints it.
///
/// The verdict is a function of ``SupervisorHealthInputs`` alone. Never assign
/// it from several sites: last writer wins, and a ladder parked in an await
/// can overwrite a pause.
nonisolated enum SupervisorHealth: Equatable, Sendable {
    case starting
    case healthy
    /// Signed out with the login window up; recovery is held until the user
    /// signs in.
    case waitingForSignIn
    /// Something is failing; the reason is shown in the menu bar.
    case degraded(String)
    /// Mid-restart; the phase is shown in the menu bar.
    case restarting(String)
    /// A startup in progress, which takes tens of seconds; a slow launch must
    /// not read as a fault or be "recovered" from.
    case launching(String)
    /// Repeated restarts failed, so only manual restarts remain.
    case gaveUp(String)
    case paused

    /// The word in `/status` and on the link. Stable: scripts and agents
    /// match on these.
    var wireName: String {
        switch self {
        case .starting: "starting"
        case .healthy: "healthy"
        case .waitingForSignIn: "waitingForSignIn"
        case .degraded: "degraded"
        case .restarting: "restarting"
        case .launching: "launching"
        case .gaveUp: "gaveUp"
        case .paused: "paused"
        }
    }

    /// The phrase the menu bar, the footer and `sevo status` show.
    var statusText: String {
        switch self {
        case .starting: "checking the client…"
        case .healthy: "client healthy"
        case .waitingForSignIn: "waiting for sign-in"
        case let .degraded(reason): reason
        case let .restarting(phase): "restarting: \(phase)"
        case let .launching(phase): phase
        case let .gaveUp(reason): reason
        case .paused: "auto-restart paused"
        }
    }

    var displayStatusText: String {
        switch self {
        case .starting: InterfaceCopy.localized("checking the client…")
        case .healthy: InterfaceCopy.localized("client healthy")
        case .waitingForSignIn: InterfaceCopy.localized("waiting for sign-in")
        case let .degraded(reason): InterfaceCopy.localized(reason)
        case let .restarting(phase): String(localized: "restarting: \(InterfaceCopy.localized(phase))")
        case let .launching(phase): InterfaceCopy.localized(phase)
        case let .gaveUp(reason): InterfaceCopy.localized(reason)
        case .paused: InterfaceCopy.localized("auto-restart paused")
        }
    }

    /// Whether the menu-bar glyph carries the attention badge.
    var needsAttention: Bool {
        switch self {
        case .degraded, .gaveUp: true
        default: false
        }
    }

    /// Rebuilds a health from what crossed the link.
    init(wireName: String, detail: String) {
        self = switch wireName {
        case "healthy": .healthy
        case "waitingForSignIn": .waitingForSignIn
        case "degraded": .degraded(detail)
        case "restarting": .restarting(Self.restartPhase(from: detail))
        case "launching": .launching(detail)
        case "gaveUp": .gaveUp(detail)
        case "paused": .paused
        default: .starting
        }
    }

    /// Strips the prefix `statusText` adds to a restart's phase.
    private static func restartPhase(from detail: String) -> String {
        let prefix = "restarting: "
        return detail.hasPrefix(prefix) ? String(detail.dropFirst(prefix.count)) : detail
    }
}

/// What a `.degraded` or `.gaveUp` health says, kept apart from the health it
/// produces so a good probe can clear it by name.
nonisolated enum SupervisorFault: Equatable, Sendable {
    case degraded(String)
    case gaveUp(String)
}

/// Where the client's own boot has got to, as the probe cycle sees it. The
/// restart ladder hands over once the launcher is spawned, so later waits run
/// with the cycle's guards on.
nonisolated enum SupervisorBootPhase: Equatable, Sendable {
    case idle
    /// Launched; CDP has not answered yet.
    case awaitingClient
    /// CDP answers; Steam's own services have not initialized.
    case awaitingServices
    /// The page has been sent to the client and is converging.
    case pageBooting

    func progressText(elapsedSeconds: Int) -> String? {
        let phase: String
        switch self {
        case .idle: return nil
        case .awaitingClient: phase = "Starting Windows and Steam"
        case .awaitingServices: phase = "Waiting for Steam’s services"
        case .pageBooting: phase = "Opening your library"
        }
        return "\(phase)… (\(max(0, elapsedSeconds))s)"
    }
}

/// Everything the health verdict is a function of.
nonisolated struct SupervisorHealthInputs: Equatable, Sendable {
    var isPaused = false
    var isRestarting = false
    /// The rung the restart ladder is on.
    var restartPhase = ""
    /// A phase deliberately waited through; `hasBeenHealthy` decides whether
    /// it reads as a launch or a recovery.
    var progressPhase: String?
    var isPageBooting = false
    var lastProbe: ClientLifecycle.ClientState = .down
    /// Whether the page reports Steam's stores as initialized.
    var pageServicesUp = false
    /// Whether this session has had a healthy client.
    var hasBeenHealthy = false
    var isAwaitingSignIn = false
    var fault: SupervisorFault?
}

nonisolated extension SupervisorHealth {
    /// The one place a `SupervisorHealth` comes from.
    ///
    /// A pause outranks everything. A signed-out client outranks progress and
    /// faults: read as a fault, it drives the recovery ladder into the login window.
    static func evaluate(_ inputs: SupervisorHealthInputs) -> SupervisorHealth {
        if inputs.isPaused { return .paused }
        if case let .gaveUp(reason)? = inputs.fault { return .gaveUp(reason) }
        // The ladder also starts a client; it is a restart only after a healthy one.
        if inputs.isRestarting {
            return inputs.hasBeenHealthy
                ? .restarting(inputs.restartPhase) : .launching(inputs.restartPhase)
        }
        if inputs.isAwaitingSignIn { return .waitingForSignIn }
        if let phase = inputs.progressPhase {
            return inputs.hasBeenHealthy ? .restarting(phase) : .launching(phase)
        }
        if case let .degraded(reason)? = inputs.fault { return .degraded(reason) }
        if inputs.isPageBooting { return .starting }
        if inputs.lastProbe != .up, !inputs.hasBeenHealthy {
            return .launching("Steam is starting. A first launch takes a minute.")
        }
        return inputs.lastProbe == .up && inputs.pageServicesUp ? .healthy : .starting
    }
}
