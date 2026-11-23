import Foundation

/// One run of consecutive client-probe failures, and the grace it earns.
///
/// The supervisor tells a busy client from a wedged one by the silence against
/// its mute window, stretched by the Mac's pressure. The stretch is the
/// outage's maximum and never shrinks: read at the current pressure, the grace
/// shrank as load eased and restarted a client that was catching up (146 s of
/// silence, healthy 103 s after the decision).
nonisolated struct ClientOutage: Sendable, Equatable {
    let began: Date
    /// The largest patience during the outage, 1 on an idle Mac.
    private(set) var patience: Double
    /// Whether the mute client of this outage has been sampled
    /// (``StuckClientSample``): once per outage, however many probes decide
    /// on a restart before one takes.
    private(set) var isSampled = false

    init(began: Date = .now, patience: Double) {
        self.began = began
        self.patience = max(1, patience)
    }

    /// Answers whether this outage's sample is still to take, and marks it taken.
    mutating func takeSample() -> Bool {
        defer { isSampled = true }
        return !isSampled
    }

    /// Keeps the larger patience.
    mutating func meet(patience: Double) {
        self.patience = max(self.patience, patience)
    }

    func elapsed(at now: Date = .now) -> TimeInterval {
        now.timeIntervalSince(began)
    }

    /// How long a mute client counts as busy: four mute windows.
    func busyGrace(muteWindow: Int) -> TimeInterval {
        Double(muteWindow) * patience * 4
    }

    /// Whether a busy client is still within ``busyGrace(muteWindow:)``.
    func busyGraceHolds(muteWindow: Int, at now: Date = .now) -> Bool {
        elapsed(at: now) < busyGrace(muteWindow: muteWindow)
    }

    /// Mute for a whole window, the least a restart needs.
    func muteLongEnough(muteWindow: Int, at now: Date = .now) -> Bool {
        elapsed(at: now) >= Double(muteWindow) * patience
    }

    /// Whether a run was armed within `window`; a launch without a window yet
    /// protects the client too. Bounded so an unclosed run cannot protect a
    /// wedged client forever.
    static func gameInFlight(armedAt starts: [Date], within window: TimeInterval, at now: Date = .now) -> Bool {
        starts.contains { now.timeIntervalSince($0) < window }
    }

    static let launchWindow: TimeInterval = 180
}
