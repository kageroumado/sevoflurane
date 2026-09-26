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
    /// Whether the engine's own `sevo:gfx` line named ``renderer``
    /// (``WineProvenance``). `false` for a Wine run no process of which
    /// reported one — a process that never presented prints the line only
    /// from its exit handler, which `TerminateProcess` skips — so
    /// ``renderer`` is the booted selection, a guess that is wrong for a D3D9
    /// or OpenGL title. Absent on the native runner, and on records older
    /// than the field.
    var rendererConfirmed: Bool? = nil
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
    /// The model identifier (``MacHardware/model``).
    var mac: String? = nil
    var gpuCores: Int? = nil
    /// Installed memory, as the tier Apple sells (``MacHardware/memoryGB``).
    var memoryGB: Int? = nil
    /// The executable's own name for itself, its `ProductName` or else its
    /// `FileDescription`: for a program Steam has no id for, what matches it
    /// to a title.
    var product: String? = nil
    /// How long after the launch began the game's first window appeared.
    /// Absent for a run that never drew.
    var windowAfterSeconds: Double? = nil
    var durationSeconds: Double? = nil
    /// Present once the driver's present counter lands (`Docs/diagnostics-plan.md`).
    var fps: FrameRate? = nil
    /// The pixels the game drew into. Absent until one of its windows was
    /// seen on screen.
    var resolution: Resolution? = nil
    /// The display the game's window was on while it was played. Absent until
    /// the window was seen on screen.
    var display: Display? = nil
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
        case rendererConfirmed = "renderer_confirmed"
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
        case mac
        case gpuCores = "gpu_cores"
        case memoryGB = "memory_gb"
        case product
        case windowAfterSeconds = "window_after_s"
        case durationSeconds = "duration_s"
        case fps
        case resolution
        case display
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
        /// The stretch of the trace that was gameplay (``GameplayWindow``), and its frames
        /// summarized. Absent on an engine without the frame-time ring.
        var gameplay: Gameplay? = nil

        enum CodingKeys: String, CodingKey {
            case avg
            case low1
            case samples
            case frameTimes = "frame_times"
            case dropped, trace, gameplay
        }
    }

    /// What ``GameplayWindow`` kept of a run's frames: where gameplay began, how long it
    /// lasted, what it left out, and the kept frames summarized.
    struct Gameplay: Codable, Equatable, Sendable {
        /// Seconds after the trace's first frame that gameplay began.
        var from: Double
        /// Seconds of frames kept: the gameplay duration the frame rate is measured over.
        var seconds: Double
        /// Seconds after ``from`` left out because the game was in the background, hidden,
        /// the display slept, or it was on a virtual display.
        var away: Double
        /// Frames after ``from`` slower than ``GameplayWindow/Rules/gapFrame``, left out as
        /// pauses and loads.
        var gaps: Int
        /// The kept frames summarized; nil for a gameplay window shorter than
        /// ``GameplayWindow/Rules/minimumSeconds``, which carries no frame rate.
        var frameTimes: FrameStats.Summary?
        /// The rate the game held its frames to, when it held them to one
        /// (``GameplayWindow/steadyRate(_:)``): its own cap, or the display's refresh.
        var steadyFPS: Double?

        enum CodingKeys: String, CodingKey {
            case from = "from_s"
            case seconds
            case away = "away_s"
            case gaps
            case frameTimes = "frame_times"
            case steadyFPS = "steady_fps"
        }
    }

    /// A display as a frame rate needs it described: how often it refreshes, whether it
    /// varies that, and whether any screen is behind it.
    struct Display: Codable, Equatable, Sendable {
        /// The current mode's refresh rate, Hz; the ceiling for a ProMotion or adaptive-sync
        /// display.
        var refreshHz: Double
        /// ProMotion or adaptive sync: the display refreshes when a frame arrives, down to
        /// its lowest rate.
        var variable: Bool
        /// No display hardware is behind it (a `CGVirtualDisplay`, a headless session, a
        /// streamed screen). Nothing paces presents on one, so a frame rate measured there
        /// says nothing about a player's.
        var virtual: Bool

        enum CodingKeys: String, CodingKey {
            case refreshHz = "refresh_hz"
            case variable
            case virtual
        }
    }

    struct Pixels: Codable, Equatable, Sendable {
        var width: Int
        var height: Int

        var area: Int {
            width * height
        }
    }

    struct Resolution: Codable, Equatable, Sendable {
        /// The largest window the game's process put on screen, in pixels.
        var window: Pixels?
        /// The size the game's swapchain presents at, from the engine's
        /// stats page; with an upscaler it is smaller than the window.
        var render: Pixels? = nil
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
            /// An unhandled exception while the game had no window left (the
            /// last `sevo:exit … windows` line before it says `closed`): the
            /// user had left it, and it fell over on the way out. Collected like a crash, never
            /// offered as one, and a compatibility verdict leaves it out.
            case crashAtExit = "crash-at-exit"
            /// A person asked the game to stop, through Steam's Stop button or
            /// Sevoflurane's menu, and it went. Steam ends a game with
            /// `TerminateProcess`, which reads as exit status 1 with no exception
            /// behind it.
            case stopped
            /// `sevo` asked the game to stop (`sevo app terminate`, an agent), and it
            /// went: the run lasted as long as a script wanted it to, so its length
            /// and its frame rate say nothing about the game.
            case stoppedByTool = "stopped-by-tool"
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

    var displaySummary: String {
        ([name.map { "\($0) (\(appid))" } ?? String(localized: "App \(String(appid))")]
            + displayOutcomeParts).joined(separator: " · ")
    }

    var displayOutcome: String {
        displayOutcomeParts.joined(separator: " · ")
    }

    var displayRendererLabel: String {
        rendererConfirmed == false
            ? String(localized: "\(renderer) (unconfirmed)") : renderer
    }

    private var displayOutcomeParts: [String] {
        var parts = [engine, displayRendererLabel]
        if let tuning, tuning != PerformanceTuning.standard.rawValue {
            parts.append(String(localized: "\(tuning) tuning"))
        }
        if let upscaler, upscaler != UpscalerChoice.off.rawValue {
            parts.append(String(localized: "upscaler \(upscaler)"))
        }
        if let durationSeconds {
            let seconds = Int(durationSeconds.rounded())
            let minutes = Int((durationSeconds / 60).rounded())
            parts.append(durationSeconds < 90
                ? String(localized: "ran \(seconds) s")
                : String(localized: "ran \(minutes) min"))
        }
        parts.append(displayExitSummary)
        return parts
    }

    private var displayExitSummary: String {
        guard let exit else { return String(localized: "still running") }
        return switch exit.kind {
        case .user: String(localized: "exited normally")
        case .crash: exit.code.map { String(localized: "crashed — exit \($0)") }
            ?? String(localized: "crashed")
        case .crashAtExit: exit.code.map { String(localized: "crashed while exiting — exit \($0)") }
            ?? String(localized: "crashed while exiting")
        case .stopped: String(localized: "stopped on request")
        case .stoppedByTool: String(localized: "stopped by sevo")
        case .endedNotResponding: String(localized: "ended by the user while it was not responding")
        case .exitError: exit.code.map { String(localized: "exited with an error — exit \($0)") }
            ?? String(localized: "exited with an error")
        case .steamTerminate: String(localized: "stopped by Steam")
        case .watchdog: String(localized: "killed after a stall")
        case .appQuit: String(localized: "ended when Sevoflurane quit")
        case .unknown: String(localized: "ended, exit unknown")
        }
    }

    /// ``renderer`` as a reader should take it: marked when no process of the
    /// run confirmed it.
    var rendererLabel: String {
        rendererConfirmed == false ? "\(renderer) (unconfirmed)" : renderer
    }

    private var outcomeParts: [String] {
        var parts = [engine, rendererLabel]
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
        case .crashAtExit: "crashed while exiting — exit\(code)"
        case .stopped: "stopped on request"
        case .stoppedByTool: "stopped by sevo"
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
