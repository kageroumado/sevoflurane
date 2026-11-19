import os

/// Signpost probes for Instruments (`os_signpost`, filtered to this subsystem).
/// Milestones go to Points of Interest; the named categories carry intervals.
/// They cost nothing measurable unless recording, so they ship in Release.
nonisolated enum PerfProbe {
    static let subsystem = "glass.kagerou.sevoflurane"

    /// Milestones: Launch, PageBoot, DesktopAdopted, Healthy, ClientBack.
    static let poi = OSSignposter(logHandle: OSLog(
        subsystem: subsystem, category: .pointsOfInterest,
    ))

    /// Every ``EventLog`` line, mirrored as a signpost event.
    static let events = OSSignposter(subsystem: subsystem, category: "events")

    /// Probe cycles and the restart ladder (`ProbeCycle`, `ClientProbe`,
    /// `PopupHide`, `ClientRestart`, `CrashLoopHygiene`).
    static let supervisor = OSSignposter(subsystem: subsystem, category: "supervisor")

    /// CDP connect, every CDP round-trip, `/__eval` round-trips, SteamClient
    /// forwards, WebKit evaluations, cookie mirroring, browser-view loads,
    /// asset serving (`CDPConnect`, `CDPCall`, `PageEval`, `SteamClientCall`,
    /// `WebKitEval`, `CookieMirror`, `BrowserViewLoad`, `ServeAsset`).
    static let bridge = OSSignposter(subsystem: subsystem, category: "bridge")

    /// Subprocesses and the window-server scan (`Subprocess`, `WineWindowScan`).
    static let system = OSSignposter(subsystem: subsystem, category: "system")

    /// Profile scenarios (`SmokeScenario`, `ScenarioStep`) and main-thread
    /// stalls during them (`MainThreadStall`).
    static let benchmark = OSSignposter(logHandle: OSLog(
        subsystem: subsystem, category: .pointsOfInterest,
    ))

    /// The provisioning run, live or dry (`Provision`).
    static let setup = OSSignposter(subsystem: subsystem, category: "setup")
}
