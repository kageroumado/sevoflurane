import Foundation

/// What a sweep of the client's own popup windows is allowed to put away.
enum PopupSweepScope: String, Sendable {
    /// Every visible popup the client has, for the stop path and the
    /// supervisor's cycle.
    case everything
    /// Only the client's copies of what this app shows itself
    /// (``SteamWindowRole/twinRoles``), for a notification's sweep, which must
    /// leave an install dialog or a game's own popup alone.
    case twins
}

/// What one sweep hid, and the scope it was allowed to hide.
struct PopupSweep: Sendable {
    let scope: PopupSweepScope
    let names: [String]
}

/// The one place a sweep of the bottled client's own popup windows is
/// scheduled from.
///
/// Never run overlapping sweeps: eight overlapping schedules left CEF
/// answering nothing on `/json` for thirty-two seconds. A request during a
/// sweep joins it, sweeps are ``minimumInterval`` apart, and a notification
/// mid-schedule extends the schedule.
actor PopupSweeper {
    static let shared = PopupSweeper()

    static let minimumInterval: Duration = .seconds(1)

    /// The client's twin toast is on screen within half a second, so a full
    /// interval would let the user see it.
    static let firstSweepDelay: Duration = .milliseconds(500)

    /// How long a notification's schedule keeps sweeping: the toast is up
    /// within a second, and a chat window opened behind it takes several more.
    static let scheduleLength: Duration = .seconds(6)

    private let interval: Duration
    private let length: Duration
    private let hide: @Sendable (PopupSweepScope) async -> [String]
    private var lastSweep: ContinuousClock.Instant?
    private var inFlight: Task<PopupSweep, Never>?
    private var scheduleEnd: ContinuousClock.Instant?
    private var schedule: Task<Void, Never>?
    private var report: (@Sendable (PopupSweep) -> Void)?

    /// `hide` reads the hook at each sweep rather than capturing it, because
    /// the app installs the bridge's sweep after the shared sweeper exists.
    init(
        minimumInterval: Duration = PopupSweeper.minimumInterval,
        scheduleLength: Duration = PopupSweeper.scheduleLength,
        hide: @escaping @Sendable (PopupSweepScope) async -> [String] = { scope in
            await ClientLifecycle.hidePopupsOverBridge(scope)
        },
    ) {
        interval = minimumInterval
        length = scheduleLength
        self.hide = hide
    }

    /// Hides what the client has on screen now, joining a sweep already in
    /// flight and otherwise waiting out the minimum interval first. The result
    /// carries the scope of the sweep that ran, which may differ from `scope`
    /// when this call joined one in flight.
    @discardableResult
    func sweep(_ scope: PopupSweepScope = .everything) async -> PopupSweep {
        if let inFlight { return await inFlight.value }
        let since = lastSweep?.duration(to: .now)
        let sweep = Task(name: "Hide the client's popups") { [interval, hide] () -> PopupSweep in
            if let since, since < interval {
                try? await Task.sleep(for: interval - since)
            }
            return await PopupSweep(scope: scope, names: hide(scope))
        }
        inFlight = sweep
        let hidden = await sweep.value
        lastSweep = .now
        inFlight = nil
        return hidden
    }

    /// Runs a client notification's schedule of sweeps, handing each run's
    /// names to `report`. A notification during a running schedule extends it
    /// and replaces its reporter.
    func sweepAfterNotification(report: @escaping @Sendable (PopupSweep) -> Void) {
        let end = ContinuousClock.now + length
        scheduleEnd = max(scheduleEnd ?? end, end)
        self.report = report
        guard schedule == nil else { return }
        schedule = Task(name: "Sweep the client's popups after a notification") {
            await self.runSchedule()
        }
    }

    private func runSchedule() async {
        try? await Task.sleep(for: Self.firstSweepDelay)
        while scheduleEnd != nil {
            let hidden = await sweep(.twins)
            if !hidden.names.isEmpty { report?(hidden) }
            // Read after the sweep: a notification during it pushed the end out.
            guard let end = scheduleEnd, ContinuousClock.now < end else { break }
        }
        scheduleEnd = nil
        report = nil
        schedule = nil
    }
}
