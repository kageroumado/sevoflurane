import Foundation

/// What supervision reports, in the vocabulary every process speaks: the
/// daemon derives it, the app renders it, `sevo` prints it.
///
/// The verdict is a function of ``SupervisorHealthInputs`` and nothing else —
/// health used to be assigned from some twenty sites in three concurrent
/// contexts, last writer wins, which is how a pause could be overwritten by a
/// ladder that had been parked in an await since before it.
nonisolated enum SupervisorHealth: Equatable, Sendable {
    case starting
    case healthy
    /// Signed out with the login window up: Steam's services stay down until
    /// the user signs in, so recovery is held — the machine is waiting on a
    /// human, not wedged.
    case waitingForSignIn
    /// Something is failing; the reason is shown in the menu bar.
    case degraded(String)
    /// Mid-restart; the phase is shown in the menu bar.
    case restarting(String)
    /// A startup in progress. Wine takes tens of seconds to bring the client's
    /// CDP endpoint up and Steam's stores take longer still, and this app is on
    /// screen throughout — a launch that is merely slow must not read as a
    /// fault, and must not be "recovered" from.
    case launching(String)
    /// Repeated restarts failed — the client is crash-looping and another
    /// launch would only stack crash dumps. Manual restarts only.
    case gaveUp(String)
    case paused

    /// The word `sevo` reads out of `/status`, and the app reads back off the
    /// link. Stable: scripts and agents match on these.
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

    /// Whether the menu-bar glyph should carry the attention badge: the states
    /// where nothing is healing itself and the user should look.
    var needsAttention: Bool {
        switch self {
        case .degraded, .gaveUp: true
        default: false
        }
    }

    /// Rebuilds a health from what crossed the link. `detail` carries the
    /// phrase for the cases that hold one; the rest ignore it.
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

    /// `statusText` prefixes a restart's phase; the phrase is what the case
    /// holds, so the prefix comes back off before it is rebuilt.
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
/// restart ladder hands over the moment the launcher is spawned, so every wait
/// past that point runs with the cycle's guards on rather than inside a ladder
/// that switches the cycle off for minutes.
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
    /// A phase the machine is deliberately waiting through, told as a first
    /// launch or as a recovery by `hasBeenHealthy`.
    var progressPhase: String?
    var isPageBooting = false
    var lastProbe: ClientLifecycle.ClientState = .down
    /// Whether the page reports Steam's stores as initialized.
    var pageServicesUp = false
    /// Whether this session has had a healthy client: a client that
    /// answers while Steam's services are still coming up is a launch in
    /// progress.
    var hasBeenHealthy = false
    var isAwaitingSignIn = false
    var fault: SupervisorFault?
}

nonisolated extension SupervisorHealth {
    /// The one place a `SupervisorHealth` comes from.
    ///
    /// A paused supervisor reports the pause whatever the client is doing —
    /// the flag is about supervision, not about Steam. A signed-out client
    /// outranks progress and faults alike: it is a steady state waiting on a
    /// human, and reading it as a fault is what drove the recovery ladder into
    /// the login window.
    static func evaluate(_ inputs: SupervisorHealthInputs) -> SupervisorHealth {
        if inputs.isPaused { return .paused }
        if case let .gaveUp(reason)? = inputs.fault { return .gaveUp(reason) }
        // The ladder is how a client is started as well as restarted: it is a
        // restart only where there was a client to lose.
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
