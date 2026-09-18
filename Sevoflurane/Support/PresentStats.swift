import Darwin
import Foundation

/// The frame rate of a running game, read out of the driver rather than out
/// of the game.
///
/// Every renderer presents through `winemac.drv`, which counts its presents
/// into a 4 KB page per process at `<prefix>/.sevo/run/<pid>.stats`
/// (`dlls/winemac.drv/sevo_stats.c`). Reading that page costs one `read` of
/// 96 bytes a second and needs no hook, no overlay and no cooperation from
/// the game, which is the whole point: a title that ships with its own
/// anti-tamper still gets an fps number and a stall signal.
///
/// What is measured: `Docs/diagnostics-plan.md` § "Frame rate and stalls
/// without a hook in the game"; what it costs:
/// `bispectral/present-stats/RESULTS.md`.
final nonisolated class PresentStats: @unchecked Sendable {
    /// How often the pages are read. The per-second sample is also the
    /// histogram the 1 % low comes out of, so this is the resolution of both.
    static let interval: TimeInterval = 1

    /// How many per-second samples one run keeps. Four hours; a run longer
    /// than that drops its oldest samples, and the average keeps counting
    /// from the totals, which are not sampled.
    static let samplesKept = 4 * 60 * 60

    private let runDirectory: URL
    private let lock = NSLock()
    private var armed: [Int: Run] = [:]
    private var timer: DispatchSourceTimer?

    /// - Parameter prefix: the bottle the games run in. Its `.sevo/run` is
    ///   where the driver writes the pages.
    init(prefix: URL = SteamBottle.root) {
        self.runDirectory = prefix.appendingPathComponent(".sevo/run")
    }

    // MARK: - What a caller sees

    /// One armed run's counter as it stands right now.
    struct Reading: Equatable, Sendable {
        /// The process whose page answered — the busiest presenter of the
        /// app id's processes.
        var pid: pid_t
        /// The Cocoa window number the frames go into, 0 when no present
        /// path has named one.
        var windowID: UInt64
        /// The last per-second sample, or 0 before the first one.
        var fps: Double
        /// How long the process has gone without a present. The stall
        /// watchdog's "no present for N seconds while alive": this is a
        /// number only while the process is still there.
        var silentFor: TimeInterval
        /// The run has a page and the process that wrote it is alive.
        var presenting: Bool
    }

    /// A launch of `appID` has begun: its pages are sampled from now on.
    func arm(appID: Int) {
        lock.lock()
        armed[appID] = Run()
        let needsTimer = timer == nil
        lock.unlock()
        if needsTimer { startTimer() }
    }

    /// The launch is over. Returns what to put in the run record, or nil for
    /// a run that never presented a frame — a game with no Metal layer at
    /// all, and the record's `fps: null`.
    @discardableResult
    func disarm(appID: Int) -> RunRecord.FrameRate? {
        lock.lock()
        let run = armed.removeValue(forKey: appID)
        let idle = armed.isEmpty
        lock.unlock()
        if idle { stopTimer() }
        return run?.frameRate
    }

    /// What the counter says about an armed run right now, or nil when the
    /// run is not armed or has no page yet.
    func reading(forApp appID: Int) -> Reading? {
        lock.lock()
        defer { lock.unlock() }
        return armed[appID]?.reading
    }

    /// Reads every page once and folds it into the armed runs. Called by the
    /// timer; a test calls it directly.
    func sample() {
        let pages = Self.pages(in: runDirectory)
        let now = Self.uptime
        lock.lock()
        for appID in Array(armed.keys) {
            armed[appID]?.absorb(pages.filter { $0.appid == appID }, at: now)
        }
        lock.unlock()
    }

    deinit { timer?.cancel() }

    // MARK: - One run's samples

    /// The counters of one launch: the page it is following, the per-second
    /// rates, and the totals the average comes from.
    private struct Run {
        private var lastCount: UInt64?
        private var lastSampledAt: TimeInterval?
        private var countedFrames: UInt64 = 0
        private var countedSeconds: TimeInterval = 0
        private var rates: [Double] = []
        var reading: Reading?

        /// Folds this second's pages in. The run's rate is its busiest
        /// page's: a launch is often several processes — a launcher, the
        /// game, a crash handler — and only one of them draws.
        mutating func absorb(_ pages: [PresentStats.Page], at now: TimeInterval) {
            guard let page = pages.max(by: { $0.count < $1.count }) else {
                reading = nil
                return
            }
            // A page that went backwards is a new process under the same app
            // id — the count starts again, and so does the interval.
            if let previous = lastCount, let then = lastSampledAt,
               page.count >= previous, now > then
            {
                let seconds = now - then
                let frames = page.count - previous
                countedFrames += frames
                countedSeconds += seconds
                rates.append(Double(frames) / seconds)
                if rates.count > PresentStats.samplesKept { rates.removeFirst() }
            }
            lastCount = page.count
            lastSampledAt = now
            reading = Reading(
                pid: page.pid, windowID: page.windowID, fps: rates.last ?? 0,
                silentFor: max(0, now - page.lastPresentUptime),
                presenting: page.alive,
            )
        }

        /// The record's frame rate: the average over the whole run, and the
        /// mean of the slowest one per cent of the per-second samples.
        var frameRate: RunRecord.FrameRate? {
            guard countedSeconds > 0, countedFrames > 0, !rates.isEmpty else { return nil }
            let slowest = rates.sorted().prefix(max(1, rates.count / 100))
            return RunRecord.FrameRate(
                avg: rounded(Double(countedFrames) / countedSeconds),
                low1: rounded(slowest.reduce(0, +) / Double(slowest.count)),
                samples: rates.count,
            )
        }
    }

    // MARK: - The pages on disk

    /// One process's counter page, as the driver left it.
    struct Page: Equatable, Sendable {
        var pid: pid_t
        var appid: Int
        var exe: String
        /// Presents that reached the screen. The D3DMetal path coalesces
        /// these, so `drawables` is the frame rate wherever it is non-zero
        /// (`bispectral/present-stats/RESULTS.md`).
        var frames: UInt64
        /// Frames the renderer produced, one per Metal drawable.
        var drawables: UInt64
        var windowID: UInt64
        var source: Source
        var lastPresentUptime: TimeInterval
        var startedUptime: TimeInterval
        /// The process that wrote the page is still running. A killed
        /// process cannot unlink its own page.
        var alive: Bool

        /// Which path counted `frames`.
        enum Source: UInt32, Sendable {
            case none = 0
            case clientSurface = 1
            case presenter = 2
        }

        /// The frames to measure a rate from: the presenter counts one per
        /// frame and owns the screen where it runs; otherwise the renderer's
        /// own drawables when there are any, and the driver's presents when
        /// there are not (Vulkan, OpenGL, a GDI window).
        var count: UInt64 {
            if source == .presenter { return frames }
            return drawables > 0 ? drawables : frames
        }
    }

    /// Every page in a bottle's run directory, stale ones dropped.
    static func pages(in directory: URL) -> [Page] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".stats"),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name))
            else { return nil }
            return page(from: data)
        }
    }

    /// Decodes one page. Fields are little-endian and naturally aligned, in
    /// the order `struct sevo_stats_page` declares them; the magic is written
    /// last, so a page without it is one being made right now.
    static func page(from data: Data) -> Page? {
        guard data.count >= 96 else { return nil }
        let word = { (offset: Int) in
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
        }
        let half = { (offset: Int) in
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard word(0) == magic, half(48) == version else { return nil }
        let pid = pid_t(half(52))
        let exe = data[64..<96]
        return Page(
            pid: pid,
            appid: Int(half(60)),
            exe: String(decoding: exe.prefix { $0 != 0 }, as: UTF8.self),
            frames: word(8),
            drawables: word(16),
            windowID: word(40),
            source: Page.Source(rawValue: half(56)) ?? .none,
            lastPresentUptime: seconds(word(24)),
            startedUptime: seconds(word(32)),
            alive: kill(pid, 0) == 0 || errno != ESRCH,
        )
    }

    /// `SEVOSTS1`.
    private static let magic: UInt64 = 0x5345_564F_5354_5331
    private static let version: UInt32 = 1

    /// The clock both sides share. The page is written by an x86_64 process
    /// under Rosetta and read by this arm64 one, and a raw mach tick is a
    /// different unit on each side; `CLOCK_UPTIME_RAW` is nanoseconds on
    /// both.
    static var uptime: TimeInterval {
        seconds(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    private static func seconds(_ nanoseconds: UInt64) -> TimeInterval {
        TimeInterval(nanoseconds) / 1_000_000_000
    }

    // MARK: - The timer

    private func startTimer() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: Self.queue)
        source.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.sample() }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    private static let queue = DispatchQueue(label: "sevo.presentstats", qos: .utility)
}

/// One decimal is all a frame rate carries; the record is read by people.
private nonisolated func rounded(_ value: Double) -> Double {
    (value * 10).rounded() / 10
}

