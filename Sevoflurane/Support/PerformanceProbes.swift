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

    /// Probe cycles and the restart ladder (`ProbeCycle`, `ClientRestart`,
    /// `CrashLoopHygiene`).
    static let supervisor = OSSignposter(subsystem: subsystem, category: "supervisor")

    /// CDP connect, `/__eval` round-trips, SteamClient forwards, asset serving
    /// (`CDPConnect`, `PageEval`, `SteamClientCall`, `ServeAsset`).
    static let bridge = OSSignposter(subsystem: subsystem, category: "bridge")

    /// The provisioning run, live or dry (`Provision`).
    static let setup = OSSignposter(subsystem: subsystem, category: "setup")
}
