import Foundation

/// One game launch: what it ran on, how long it lasted, and how it ended. It is the report window's
/// summary, an issue's body, and all that survives a game that dies in two seconds; it names no one
/// (``Redaction``).
nonisolated struct RunRecord: Codable, Equatable, Identifiable, Sendable {
    /// When the launch began, UTC, seconds.
    var t: String
    var appid: Int
    /// The game's title, as the library spells it.
    var name: String? = nil
    /// The executable the launch's processes ran, from the dock shim's chronicle; absent when none
    /// reached the Mac driver.
    var exe: String? = nil
    /// The engine directory's version (`dormison-r4`), or the CodeWeavers app.
    var engine: String
    /// What the client booted with, which the game inherited; never the stored selection, which may
    /// name the next restart's.
    var renderer: String
    /// Whether the engine's `sevo:gfx` line named ``renderer`` (``WineProvenance``). `false` when
    /// no process reported one (a process that never presented prints it only from its exit
    /// handler, which `TerminateProcess` skips), so ``renderer`` is the booted selection, wrong for
    /// a D3D9 or OpenGL title. Absent on the native runner and on older records.
    var rendererConfirmed: Bool? = nil
    /// The renderer the settings asked for (the game's pin, else the bottle's). It differs from
    /// ``renderer`` when a pin did not take or a title drew through wined3d anyway. Absent on the
    /// native runners and on older records.
    var rendererRequested: String? = nil
    /// `wine` or `nwjs` (``GameRunner``).
    var runner: String
    /// The executable's address width, 32 or 64, from its COFF header
    /// (``PEResources/machine(of:)``).
    var arch: Int? = nil
    /// The driver's window treatment for this game (``WindowTreatment``).
    var windows: String
    /// The performance tuning in force (``PerformanceTuning``), which decides whether two runs of
    /// one game compare.
    var tuning: String? = nil
    /// The upscaler in force, an ``UpscalerChoice`` raw value or a shader package's name.
    var upscaler: String? = nil
    var msync: Bool
    /// The D3DMetal toolkit version in force, when there is one.
    var d3dmetal: String? = nil
    /// The engine the game is built on, from the processes Steam tracked: `unity` or `unreal`.
    var runtime: String? = nil
    var macos: String
    var chip: String? = nil
    /// The model identifier (``MacHardware/model``).
    var mac: String? = nil
    var gpuCores: Int? = nil
    /// Installed memory, as the tier Apple sells (``MacHardware/memoryGB``).
    var memoryGB: Int? = nil
    /// The executable's `ProductName`, else its `FileDescription`, which matches a program Steam
    /// has no id for to a title.
    var product: String? = nil
    /// Seconds from the launch to the game's first window; absent for a run that never drew.
    var windowAfterSeconds: Double? = nil
    var durationSeconds: Double? = nil
    /// Present once the driver's present counter lands.
    var fps: FrameRate? = nil
    /// The pixels the game drew into, once a window was seen on screen.
    var resolution: Resolution? = nil
    /// The display the game's window was on while it was played.
    var display: Display? = nil
    /// Present once the stall watchdog lands.
    var stalls: [Stall]? = nil
    var exit: Exit? = nil
    var crash: Crash? = nil
    /// The renderer's own complaints during the run, deduplicated with counts.
    var notes: [String]? = nil
    /// Whether macOS ran a Game Mode session at any point during the run (``GameModeSignal``).
    var gameMode: Bool? = nil
    /// What the game's process cost, as the kernel billed it (``ProcessUsage``) at the last sample.
    var energy: Energy? = nil
    /// Busy threads while the game had focus (``ThreadActivity``); stays on this Mac, ``SharedRun``
    /// omits it. Absent with too few focused samples.
    var threads: Threads? = nil
    /// A video decoder the game fed and got nothing from, when the run had one.
    var video: Video? = nil
    var host: Host

    enum CodingKeys: String, CodingKey {
        case t
        case appid
        case name
        case exe
        case engine
        case renderer
        case rendererConfirmed = "renderer_confirmed"
        case rendererRequested = "renderer_requested"
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
        case threads
        case video
        case host
    }

    struct FrameRate: Codable, Equatable, Sendable {
        var avg: Double
        /// The slowest one per cent of the per-second samples.
        var low1: Double
        var samples: Int
        /// Every frame's time summarized (``FrameStats/Summary``), on an engine with the frame-time
        /// ring.
        var frameTimes: FrameStats.Summary? = nil
        /// Frames the ring turned over before they were read, which the trace skips.
        var dropped: Int? = nil
        /// The trace file in `Runs/traces` (``FrameTrace``).
        var trace: String? = nil
        /// The gameplay stretch of the trace (``GameplayWindow``), summarized; absent without the
        /// frame-time ring.
        var gameplay: Gameplay? = nil

        enum CodingKeys: String, CodingKey {
            case avg
            case low1
            case samples
            case frameTimes = "frame_times"
            case dropped, trace, gameplay
        }
    }

    /// What ``GameplayWindow`` kept of a run's frames.
    struct Gameplay: Codable, Equatable, Sendable {
        /// Seconds after the trace's first frame that gameplay began.
        var from: Double
        /// Seconds of frames kept, which the frame rate is measured over.
        var seconds: Double
        /// Seconds after ``from`` left out: the game in the background or hidden, the display
        /// asleep, or a virtual display.
        var away: Double
        /// Frames after ``from`` slower than ``GameplayWindow/Rules/gapFrame``, left out as pauses
        /// and loads.
        var gaps: Int
        /// The kept frames summarized; nil for a window shorter than
        /// ``GameplayWindow/Rules/minimumSeconds``.
        var frameTimes: FrameStats.Summary?
        /// The rate the game held its frames to, if any (``GameplayWindow/steadyRate(_:)``): its
        /// own cap or the display's refresh.
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

    /// A display as a frame rate needs it described.
    struct Display: Codable, Equatable, Sendable {
        /// The current mode's refresh rate, Hz; the ceiling on a variable-rate display.
        var refreshHz: Double
        /// ProMotion or adaptive sync: it refreshes when a frame arrives, down to its lowest rate.
        var variable: Bool
        /// No display hardware behind it (a `CGVirtualDisplay`, a headless session, a streamed
        /// screen): nothing paces presents, so its frame rate says nothing about a player's.
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
        /// The swapchain's present size, from the engine's stats page; smaller than the window
        /// under an upscaler.
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
        /// The process's status as Steam recorded it.
        var code: Int?

        /// How a run ended, from what the client and Steam's log say, never from a window
        /// disappearing.
        enum Kind: String, Codable, Sendable {
            /// Exit status 0 with no stop requested.
            case user
            /// The client raised an error for the game action and no process exit followed.
            case steamTerminate = "steam-terminate"
            /// An unhandled exception in the Wine log (`sevo:crash`, `err:seh`, `wine: Unhandled
            /// …`), or an error-severity NT exit status (`0xC…`).
            case crash
            /// An unhandled exception after the game's last window closed (the last `sevo:exit …
            /// windows` line says `closed`). Collected like a crash, never offered as one, and left
            /// out of compatibility verdicts.
            case crashAtExit = "crash-at-exit"
            /// A person stopped the game (Steam's Stop button, Sevoflurane's menu). The stop ends
            /// its processes whole (``GameEnding``), which Steam reads as status 0; Steam's own
            /// `TerminateProcess` reads as 1.
            case stopped
            /// `sevo` stopped the game (`sevo app terminate`, an agent), so its length and frame
            /// rate say nothing about the game.
            case stoppedByTool = "stopped-by-tool"
            /// A non-zero exit status with no exception behind it and no stop on record.
            case exitError = "exit-error"
            /// The app killed the game (the stall watchdog).
            case watchdog
            /// The game ignored a close or Quit and the user chose End Game (`sevo:exit … ended by
            /// the user while not responding`).
            case endedNotResponding = "ended-not-responding"
            /// Sevoflurane quit, and its teardown took the bottle and the game down.
            case appQuit = "app-quit"
            /// The run closed with no exit learned.
            case unknown
        }
    }

    /// The unhandled exception that ended the run, from the Wine log's crash lines or only the exit
    /// status.
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

    /// The kernel's bill for the game process. Energy, instructions and P-core share together say
    /// whether a slow run was starved, throttled, or on efficiency cores.
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

    /// The game's busy threads while it had focus: the median sample, and the processors it was
    /// told of.
    struct Threads: Codable, Equatable, Sendable {
        /// The median count of threads at or above ``ThreadActivity/busyThreshold``.
        var busy: Int
        /// The processors the game saw: the Mac's, or the game's cap.
        var processors: Int
        var samples: Int

        /// Samples needed before a record says anything: ten seconds of focus.
        static let minimumSamples = 5

        /// The busy count at which ``summary`` names it.
        static let summaryThreshold = 3

        /// `samples` summarized, or nil when there are fewer than ``minimumSamples``.
        init?(samples: [Int], processors: Int) {
            guard samples.count >= Self.minimumSamples else { return nil }
            let sorted = samples.sorted()
            let middle = sorted.count / 2
            busy = sorted.count.isMultiple(of: 2)
                ? (sorted[middle - 1] + sorted[middle] + 1) / 2
                : sorted[middle]
            self.processors = processors
            self.samples = samples.count
        }

        init(busy: Int, processors: Int, samples: Int) {
            self.busy = busy
            self.processors = processors
            self.samples = samples
        }

        /// `15 busy threads`, for a count of at least ``summaryThreshold``.
        var summary: String? {
            busy >= Self.summaryThreshold ? "\(busy) busy threads" : nil
        }
    }

    /// A decoder the game fed ``buffers`` buffers that produced no sample, per the engine's
    /// `decoded none of` line (``VideoStarvation``).
    struct Video: Codable, Equatable, Sendable {
        var buffers: Int
        /// The stream's type as GStreamer names it, `video/x-h264`.
        var stream: String
        /// Which decoders were in force, ``VideoDecoding``'s raw value.
        var decoding: String

        var summary: String {
            "video decoded nothing (\(stream), \(buffers) buffers, \(decoding))"
        }
    }

    /// The record's identity, app and start moment, which no two runs share; reports and `sevo
    /// report` name a run by it.
    var id: String {
        "\(appid)-\(t)"
    }

    /// The run `target` names among `records`, oldest first: an appid picks its newest run,
    /// anything else is a run id.
    static func matching(_ target: String, in records: [RunRecord]) -> RunRecord? {
        if let appid = Int(target) {
            return records.last { $0.appid == appid }
        }
        return records.first { $0.id == target }
    }

    /// One line naming the game, what it ran on, how long it lasted and how it ended.
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
        if video != nil { parts.append(String(localized: "video decoded nothing")) }
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

    /// ``renderer``, marked when no process of the run confirmed it.
    var rendererLabel: String {
        rendererConfirmed == false ? "\(renderer) (unconfirmed)" : renderer
    }

    private var outcomeParts: [String] {
        var parts = [engine, rendererLabel]
        if let tuning, tuning != PerformanceTuning.standard.rawValue { parts.append("\(tuning) tuning") }
        if let upscaler, upscaler != UpscalerChoice.off.rawValue { parts.append("upscaler \(upscaler)") }
        if let video { parts.append(video.summary) }
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
