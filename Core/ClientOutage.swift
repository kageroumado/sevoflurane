import Foundation

/// One run of consecutive client-probe failures, and the grace it earns.
///
/// A mute DevTools server on a live client is either a client that is busy
/// or one that is wedged, and the supervisor tells them apart by how long
/// the silence lasts against its mute window, stretched by the Mac's
/// pressure. The stretch is remembered per outage and never shrinks: a
/// client that fell silent under a build is slow because of the build, and
/// the build easing before the client has caught up is no evidence that it
/// is wedged. Read against the pressure of the moment instead, the grace
/// shrank under the silence as the load eased, and a client that was
/// catching up was restarted (2026-11-01: 146 s of silence, 103 s from the
/// decision to healthy again).
nonisolated struct ClientOutage: Sendable, Equatable {
    /// When the first failed probe of this run was.
    let began: Date
    /// The largest patience the Mac showed during the outage, 1 on an idle Mac.
    private(set) var patience: Double

    init(began: Date = .now, patience: Double) {
        self.began = began
        self.patience = max(1, patience)
    }

    /// Another probe failed under this much patience: the outage keeps the
    /// larger.
    mutating func meet(patience: Double) {
        self.patience = max(self.patience, patience)
    }

    func elapsed(at now: Date = .now) -> TimeInterval {
        now.timeIntervalSince(began)
    }

    /// How long a client with its socket open and its DevTools server mute
    /// is taken at its word: four mute windows at the outage's patience.
    func busyGrace(muteWindow: Int) -> TimeInterval {
        Double(muteWindow) * patience * 4
    }

    /// Whether a busy client is still within ``busyGrace(muteWindow:)``.
    func busyGraceHolds(muteWindow: Int, at now: Date = .now) -> Bool {
        elapsed(at: now) < busyGrace(muteWindow: muteWindow)
    }

    /// Whether the client has been mute for a whole window at the outage's
    /// patience, which is the least a restart needs.
    func muteLongEnough(muteWindow: Int, at now: Date = .now) -> Bool {
        elapsed(at: now) >= Double(muteWindow) * patience
    }

    /// Whether a game is in its first minutes, from when its runs were armed:
    /// a launch that has no window yet is as much a reason to leave the
    /// client alone as a game on screen, and a restart would take Steam from
    /// under it. Bounded, because an armed run the app never closed would
    /// otherwise protect a wedged client forever.
    static func gameInFlight(armedAt starts: [Date], within window: TimeInterval, at now: Date = .now) -> Bool {
        starts.contains { now.timeIntervalSince($0) < window }
    }

    /// How long after a run is armed its launch counts as in flight.
    static let launchWindow: TimeInterval = 180
}
