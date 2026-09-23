import Foundation

/// What a sweep of the client's own popup windows is allowed to put away.
enum PopupSweepScope: String, Sendable {
    /// Every visible popup the client has. The stop path and the supervisor's
    /// cycle ask for this: the client is coming down, or every window it has
    /// on the Wine desktop is one this app already renders natively.
    case everything
    /// Only the client's copies of what this app puts on screen itself
    /// (``SteamWindowRole/twinRoles``). A notification's sweep asks for this:
    /// the window it came for is the toast twin, and an install dialog or a
    /// game's own popup that happens to be up is not its to take away.
    case twins
}

/// One sweep's result: what it hid, and what it was allowed to hide, so a
/// caller can say which in its log rather than guess from the names.
struct PopupSweep: Sendable {
    let scope: PopupSweepScope
    let names: [String]
}

/// The one place a sweep of the bottled client's own popup windows is
/// scheduled from.
///
/// A sweep used to be a task per notification, four delays deep, each delay
/// opening a DevTools session per popup target. Two notifications a second
/// apart put eight overlapping schedules on a CEF that then answered nothing
/// on `/json` for thirty-two seconds while its process sat idle. One actor
/// holds the schedule instead: a request that arrives while a sweep is in
/// flight joins it, consecutive sweeps are ``minimumInterval`` apart, and a
/// notification arriving mid-schedule extends the schedule rather than
/// starting a second one.
actor PopupSweeper {
    static let shared = PopupSweeper()

    /// Sweeps happen no closer together than this, whoever asks.
    static let minimumInterval: Duration = .seconds(1)

    /// How soon after a notification the first sweep runs. The client's twin
    /// toast is on screen within half a second, and a sweep that waits a full
    /// interval lets the user see it.
    static let firstSweepDelay: Duration = .milliseconds(500)

    /// How long a notification's schedule keeps sweeping. One notification
    /// raises more than one window and they do not arrive together: the toast
    /// is up within a second, and a chat window the twin opens behind it takes
    /// several more.
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
    /// flight and otherwise waiting out the minimum interval first.
    ///
    /// Answers what was hidden and what the sweep that hid it was allowed to
    /// hide, so a caller can name them in the log, the supervisor can spot the
    /// sign-in window among them, and a narrow ask that joined a wider sweep
    /// already in flight says so rather than claiming those windows.
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
    /// names to `report`. A notification arriving while a schedule is running
    /// pushes its end out and leaves its own reporter behind, rather than
    /// starting a schedule of its own.
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
            // Read after the sweep: a notification that arrived during it
            // pushed the end out, and this schedule is the one that serves it.
            guard let end = scheduleEnd, ContinuousClock.now < end else { break }
        }
        scheduleEnd = nil
        report = nil
        schedule = nil
    }
}
