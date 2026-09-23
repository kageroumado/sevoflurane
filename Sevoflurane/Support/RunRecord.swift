import Foundation

/// One game launch: what it ran on, how long it lasted, and how it ended.
///
/// The record is the spine of the diagnostics (`Docs/diagnostics-plan.md`):
/// the summary a report window shows, the body of an issue, and the only
/// thing that survives a game that dies in two seconds with nothing on
/// screen. It names no one — see ``Redaction`` for what is kept out.
nonisolated struct RunRecord: Codable, Equatable, Sendable {
    /// When the launch began, UTC, seconds.
    var t: String
    var appid: Int
    /// The game's title, as the library spells it.
    var name: String? = nil
    /// The executable the launch's own processes ran, from the dock shim's
    /// chronicle. Absent for a launch whose process never reached the Mac
    /// driver.
    var exe: String? = nil
    /// The engine directory's version (`dormison-r4`), or the CodeWeavers app.
    var engine: String
    /// What the client booted with, which is what the game inherited — never
    /// the stored selection, which may already name the next restart's.
    var renderer: String
    /// `wine` or `nwjs` (``GameRunner``).
    var runner: String
    /// The executable's address width, 32 or 64, from its COFF header
    /// (``PEResources/machine(of:)``). Absent until the launch's executable
    /// is known and found on disk.
    var arch: Int? = nil
    /// The driver's window treatment for this game (``WindowTreatment``).
    var windows: String
    /// The performance tuning in force (``PerformanceTuning``): what makes two
    /// runs of one game comparable, or not.
    var tuning: String? = nil
    /// The upscaler in force, an ``UpscalerChoice`` raw value or a shader
    /// package's name; its cost is part of any frame rate read beside it.
    var upscaler: String? = nil
    var msync: Bool
    /// The D3DMetal toolkit version in force, when there is one.
    var d3dmetal: String? = nil
    /// What the game is built on, told by the processes Steam tracked for it:
    /// `unity`, `unreal`, or absent when nothing said.
    var runtime: String? = nil
    var macos: String
    var chip: String? = nil
    /// How long after the launch began the game's first window appeared.
    /// Absent for a run that never drew.
    var windowAfterSeconds: Double? = nil
    var durationSeconds: Double? = nil
    /// Present once the driver's present counter lands (`Docs/diagnostics-plan.md`).
    var fps: FrameRate? = nil
    /// Present once the stall watchdog lands.
    var stalls: [Stall]? = nil
    var exit: Exit? = nil
    var crash: Crash? = nil
    /// The renderer's own complaints during the run, deduplicated with counts.
    var notes: [String]? = nil
    /// Whether macOS ran a Game Mode session at any point during the run
    /// (``GameModeSignal``). Absent until the run has been observed at all.
    var gameMode: Bool? = nil
    /// What the game's own process cost, as the kernel billed it
    /// (``ProcessUsage``), from the last sample taken while it was alive.
    /// Absent for a run whose process was never named.
    var energy: Energy? = nil
    var host: Host

    enum CodingKeys: String, CodingKey {
        case t
        case appid
        case name
        case exe
        case engine
        case renderer
        case runner
        case arch
        case windows
        case tuning
        case upscaler
        case msync
        case d3dmetal
        case runtime
        case macos
        case chip
        case windowAfterSeconds = "window_after_s"
        case durationSeconds = "duration_s"
        case fps
        case stalls
        case exit
        case crash
        case notes
        case gameMode = "game_mode"
        case energy
        case host
    }

    struct FrameRate: Codable, Equatable, Sendable {
        var avg: Double
        /// The slowest one per cent of the per-second samples.
        var low1: Double
        var samples: Int
        /// Every frame's time summarized (``FrameStats/Summary``), on an engine whose stats
        /// page carries the frame-time ring.
        var frameTimes: FrameStats.Summary? = nil
        /// Frames the ring turned over before they were read, which the trace skips.
        var dropped: Int? = nil
        /// The trace file in `Runs/traces` (``FrameTrace``).
        var trace: String? = nil

        enum CodingKeys: String, CodingKey {
            case avg, low1, samples
            case frameTimes = "frame_times"
            case dropped, trace
        }
    }

    struct Stall: Codable, Equatable, Sendable {
        var at: Double
        var duration: Double
        /// What got it moving again, when something did.
        var unwedged: String?

        enum CodingKeys: String, CodingKey {
            case at = "at_s"
            case duration = "for_s"
            case unwedged
        }
    }

    struct Exit: Codable, Equatable, Sendable {
        var kind: Kind
        /// The process's status as Steam recorded it, absent when Steam never
        /// tracked an exit.
        var code: Int?

        /// How a run ended, decided from what the client and Steam's own log
        /// say — never from a window disappearing.
        enum Kind: String, Codable, Sendable {
            /// The game's process exited with status 0.
            case user
            /// The client raised an error for the game action and no process
            /// exit followed: Steam ended the run itself.
            case steamTerminate = "steam-terminate"
            /// An unhandled exception in the Wine log during the run. A crash
            /// leaves one; being ended from outside does not.
            case crash
            /// The game was asked to stop, through Sevoflurane or `sevo`, and
            /// went. Steam ends a game with `TerminateProcess`, which reads as
            /// exit status 1 with no exception behind it.
            case stopped
            /// A non-zero exit status with no exception behind it and no stop
            /// on record: the game gave up by itself, or Steam's own Stop
            /// button ended it — the two read the same from here.
            case exitError = "exit-error"
            /// The app killed the game (the stall watchdog).
            case watchdog
            /// The game left a close or a Quit unanswered, the engine asked, and the user chose
            /// End Game (`sevo:exit … ended by the user while not responding`).
            case endedNotResponding = "ended-not-responding"
            /// Sevoflurane quit, and the teardown that follows took the
            /// bottle — and the game in it — down.
            case appQuit = "app-quit"
            /// The run closed without the app learning an exit — the client
            /// went away before it recorded one.
            case unknown
        }
    }

    /// Wine's unhandled-exception record for the run (`err:seh`, always on).
    struct Crash: Codable, Equatable, Sendable {
        /// The NT status, `0xc0000005` and friends.
        var code: String
        var flags: String?
        var address: String?
        /// The faulting module, when the trail names one.
        var module: String?
    }

    struct Host: Codable, Equatable, Sendable {
        var thermal: String
        var load: Double
    }

    /// The game process's bill from the kernel: energy in nanojoules, retired
    /// instructions, and the share of its CPU time that ran on performance
    /// cores. The three together say whether a slow run was starved,
    /// throttled, or scheduled onto efficiency cores.
    struct Energy: Codable, Equatable, Sendable {
        var nanojoules: UInt64
        var instructions: UInt64
        /// 0 to 1, two decimals.
        var pCoreShare: Double

        enum CodingKeys: String, CodingKey {
            case nanojoules = "nj"
            case instructions
            case pCoreShare = "p_core_share"
        }

        init(nanojoules: UInt64, instructions: UInt64, pCoreShare: Double) {
            self.nanojoules = nanojoules
            self.instructions = instructions
            self.pCoreShare = pCoreShare
        }

        init(_ usage: ProcessUsage) {
            self.init(
                nanojoules: usage.energyNanojoules,
                instructions: usage.instructions,
                pCoreShare: (usage.pCoreShare * 100).rounded() / 100,
            )
        }
    }

    /// The level-0 summary: one line naming the game, what it ran on, how
    /// long it lasted and how it ended.
    var summary: String {
        ([name.map { "\($0) (\(appid))" } ?? "app \(appid)"] + outcomeParts).joined(separator: " · ")
    }

    /// The summary without the game's name, for a list whose rows are titled with it.
    var outcome: String {
        outcomeParts.joined(separator: " · ")
    }

    private var outcomeParts: [String] {
        var parts = [engine, renderer]
        if let tuning, tuning != PerformanceTuning.standard.rawValue { parts.append("\(tuning) tuning") }
        if let upscaler, upscaler != UpscalerChoice.off.rawValue { parts.append("upscaler \(upscaler)") }
        if let durationSeconds { parts.append(Self.duration(durationSeconds)) }
        parts.append(exitSummary)
        return parts
    }

    private var exitSummary: String {
        guard let exit else { return "still running" }
        let code = exit.code.map { " \($0)" } ?? ""
        return switch exit.kind {
        case .user: "exited normally"
        case .crash: "crashed — exit\(code)"
        case .stopped: "stopped on request"
        case .endedNotResponding: "ended by the user while it was not responding"
        case .exitError: "exited with an error — exit\(code)"
        case .steamTerminate: "stopped by Steam"
        case .watchdog: "killed after a stall"
        case .appQuit: "ended when Sevoflurane quit"
        case .unknown: "ended, exit unknown"
        }
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 90
            ? "ran \(Int(seconds.rounded())) s"
            : "ran \(Int((seconds / 60).rounded())) min"
    }
}
