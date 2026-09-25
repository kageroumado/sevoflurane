import Foundation

/// One run as the community database receives it: the ``RunRecord`` minus
/// everything that could name the player or the machine. No title (the appid
/// is enough), no path, no notes, no crash addresses, no exact memory size,
/// no launch time finer than the hour.
///
/// The keys are the wire format, version ``version``; changing one is a
/// version bump on both ends.
nonisolated struct SharedRun: Codable, Equatable, Sendable {
    static let version = 1

    var v: Int
    /// The launch's hour, UTC.
    var t: String
    var app: String
    /// The Steam app id, absent for a program Steam does not know.
    var appid: Int?
    /// The executable's file name.
    var exe: String?
    /// For a program without an appid, its own name for itself.
    var product: String?
    var engine: String
    var renderer: String
    var runner: String
    var arch: Int?
    var runtime: String?
    var settings: Settings
    var macos: String
    var chip: String?
    var mac: String?
    var gpuCores: Int?
    var memoryGB: Int?
    var resolution: RunRecord.Resolution?
    var windowAfterSeconds: Double?
    var durationSeconds: Double?
    var fps: FrameRate?
    var stalls: Int
    var exit: String
    var crashed: Bool
    var gameMode: Bool?
    var hostLoad: String

    struct Settings: Codable, Equatable, Sendable {
        var windows: String
        var tuning: String?
        var upscaler: String?
        var msync: Bool
        var d3dmetal: String?
    }

    struct FrameRate: Codable, Equatable, Sendable {
        var avg: Double
        var low1: Double
        var low01: Double?
        var p99Milliseconds: Double?
        var hitches: Int?
        var samples: Int

        enum CodingKeys: String, CodingKey {
            case avg
            case low1
            case low01
            case p99Milliseconds = "p99_ms"
            case hitches, samples
        }
    }

    enum CodingKeys: String, CodingKey {
        case v
        case t
        case app
        case appid
        case exe
        case product
        case engine
        case renderer
        case runner
        case arch
        case runtime
        case settings
        case macos
        case chip
        case mac
        case gpuCores = "gpu_cores"
        case memoryGB = "memory_gb"
        case resolution
        case windowAfterSeconds = "window_after_s"
        case durationSeconds = "duration_s"
        case fps, stalls, exit, crashed
        case gameMode = "game_mode"
        case hostLoad = "host_load"
    }

    /// Runs shorter than this that never drew are launchers and cancelled
    /// sign-ins, which say nothing about the game.
    static let minimumUndrawnSeconds: Double = 20

    /// The run as shared, or `nil` for one that says nothing about the game.
    init?(record: RunRecord, appVersion: String) {
        let drew = record.windowAfterSeconds != nil || (record.fps?.samples ?? 0) > 0
        guard drew || (record.durationSeconds ?? 0) >= Self.minimumUndrawnSeconds else { return nil }
        let adopted = AdoptedPrograms.isAdopted(record.appid)
        v = Self.version
        t = Self.hour(of: record.t)
        app = appVersion
        appid = adopted ? nil : record.appid
        exe = record.exe.map { ($0 as NSString).lastPathComponent }
        product = adopted ? record.product : nil
        engine = record.engine
        renderer = record.renderer
        runner = record.runner
        arch = record.arch
        runtime = record.runtime
        settings = Settings(
            windows: record.windows, tuning: record.tuning, upscaler: record.upscaler,
            msync: record.msync, d3dmetal: record.d3dmetal,
        )
        macos = record.macos
        chip = record.chip
        mac = record.mac
        gpuCores = record.gpuCores
        memoryGB = record.memoryGB
        resolution = record.resolution
        windowAfterSeconds = record.windowAfterSeconds
        durationSeconds = record.durationSeconds
        fps = record.fps.map {
            FrameRate(
                avg: $0.avg, low1: $0.low1, low01: $0.frameTimes?.low01, p99Milliseconds: $0.frameTimes?.p99,
                hitches: $0.frameTimes?.hitches, samples: $0.samples,
            )
        }
        stalls = record.stalls?.count ?? 0
        exit = record.exit?.kind.rawValue ?? RunRecord.Exit.Kind.unknown.rawValue
        crashed = record.crash != nil
        gameMode = record.gameMode
        hostLoad = Self.loadTier(record.host.load, thermal: record.host.thermal)
    }

    /// A run as this Mac would share it, for showing exactly what goes out
    /// before anything has: a real record's shape with the machine's own
    /// hardware and made-up game figures.
    static func example(appVersion: String) -> SharedRun {
        let record = RunRecord(
            t: "2026-09-25T14:12:06Z", appid: 1_962_700, exe: "Subnautica2-Win64-Shipping.exe",
            engine: "dormison-r16", renderer: "d3dmetal", runner: "wine", arch: 64, windows: "fixed",
            tuning: "standard", upscaler: "off", msync: true, d3dmetal: "4.0 beta 2", runtime: "unreal",
            macos: "27.0.0", chip: nil, mac: MacHardware.model, gpuCores: MacHardware.gpuCores,
            memoryGB: MacHardware.memoryGB, windowAfterSeconds: 6.2, durationSeconds: 1843,
            fps: RunRecord.FrameRate(avg: 58.4, low1: 41.0, samples: 1830),
            resolution: RunRecord.Resolution(window: RunRecord.Pixels(width: 3024, height: 1964)),
            exit: RunRecord.Exit(kind: .user, code: 0), gameMode: true,
            host: RunRecord.Host(thermal: "nominal", load: 1.2),
        )
        var run = SharedRun(record: record, appVersion: appVersion)!
        run.chip = MacHardware.chip
        return run
    }

    /// The JSON exactly as it is sent.
    var json: String {
        let encoder = JSONEncoder.stats
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// `2026-09-25T14:12:06Z` → `2026-09-25T14:00:00Z`.
    static func hour(of stamp: String) -> String {
        guard stamp.count >= 13 else { return stamp }
        return String(stamp.prefix(13)) + ":00:00Z"
    }

    /// The host's state at launch as one of four words: a throttled or busy
    /// Mac explains a slow run without saying anything else about it.
    static func loadTier(_ load: Double, thermal: String) -> String {
        if thermal == "serious" || thermal == "critical" { return "hot" }
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        return load > cores * 0.5 ? "busy" : "quiet"
    }
}
