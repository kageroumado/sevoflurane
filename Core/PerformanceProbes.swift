import os

/// Signpost probes for Instruments: profile the app, add the `os_signpost`
/// instrument, and filter to this subsystem. Boot and recovery milestones ride
/// the Points of Interest track Instruments shows by default; the named
/// categories carry intervals (probe cycles, restart ladders, page evals,
/// asset serving) whose durations Instruments aggregates per name.
///
/// Signposts cost nothing measurable unless something is recording, so the
/// probes ship in every configuration — a Release profile sees the same
/// timeline a Debug one does.
nonisolated enum PerfProbe {
    static let subsystem = "glass.kagerou.sevoflurane"

    /// Milestones: Launch, PageBoot, DesktopAdopted, Healthy, ClientBack.
    static let poi = OSSignposter(logHandle: OSLog(
        subsystem: subsystem, category: .pointsOfInterest,
    ))

    /// Every ``EventLog`` line, mirrored as a signpost event so the app's own
    /// trail lines up against CPU and I/O in the Instruments timeline.
    static let events = OSSignposter(subsystem: subsystem, category: "events")

    /// Probe cycles and the restart ladder (`ProbeCycle`, `ClientProbe`,
    /// `PopupHide`, `ClientRestart`, `CrashLoopHygiene`).
    static let supervisor = OSSignposter(subsystem: subsystem, category: "supervisor")

    /// CDP connect, every CDP round-trip, `/__eval` round-trips, SteamClient
    /// forwards, WebKit evaluations, cookie mirroring, browser-view loads,
    /// asset serving (`CDPConnect`, `CDPCall`, `PageEval`, `SteamClientCall`,
    /// `WebKitEval`, `CookieMirror`, `BrowserViewLoad`, `ServeAsset`).
    static let bridge = OSSignposter(subsystem: subsystem, category: "bridge")

    /// Calls out of the process that a busy host slows down: subprocesses
    /// and the window-server scan (`Subprocess`, `WineWindowScan`).
    static let system = OSSignposter(subsystem: subsystem, category: "system")

    /// End-to-end profile scenarios (`SmokeScenario`, `ScenarioStep`) and the
    /// main-thread stalls seen while they run (`MainThreadStall`). Each step
    /// covers the command, the app-owned readiness signal, and its timeout,
    /// so the interval lines up with scheduling and process activity.
    static let benchmark = OSSignposter(logHandle: OSLog(
        subsystem: subsystem, category: .pointsOfInterest,
    ))

    /// The provisioning run, live or dry (`Provision`).
    static let setup = OSSignposter(subsystem: subsystem, category: "setup")
}
