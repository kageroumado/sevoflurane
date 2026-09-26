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

    private let runDirectories: [URL]
    private let lock = NSLock()
    private var armed: [Int: Run] = [:]
    private var timer: DispatchSourceTimer?

    /// - Parameters:
    ///   - prefix: the bottle the games run in. Its `.sevo/run` is where the
    ///     driver writes the pages.
    ///   - companions: the other prefixes games run in, whose pages are read
    ///     too: the bottle's companion, where HoYoverse's games run
    ///     (``SteamParent``).
    init(prefix: URL = SteamBottle.root, companions: [URL] = []) {
        self.runDirectories = ([prefix] + companions).map { $0.appendingPathComponent(".sevo/run") }
    }

    /// Counts `pid`'s page toward `appID`'s run whatever app id the page
    /// carries: a program Steam did not start has none (``RunRecorder``
    /// learns its process when it reaches the Mac driver).
    func claim(pid: pid_t, forApp appID: Int) {
        lock.lock()
        armed[appID]?.claimed.insert(pid)
        lock.unlock()
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

    /// A launch of `appID` has begun: its pages are sampled from now on, and its frames go
    /// to `trace` when one is given.
    func arm(appID: Int, trace: FrameTrace.Writer? = nil) {
        lock.lock()
        armed[appID]?.trace?.close()
        armed[appID] = Run(trace: trace)
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
        var run = armed.removeValue(forKey: appID)
        let idle = armed.isEmpty
        run?.trace?.close()
        lock.unlock()
        if idle { stopTimer() }
        return run?.frameRate
    }

    /// Writes a mark into every armed run's trace, after reading the frames
    /// presented so far, so the mark falls where it was asked for. Answers how
    /// many traces took it.
    @discardableResult
    func mark(_ label: String) -> Int {
        sample()
        lock.lock()
        defer { lock.unlock() }
        var marked = 0
        for run in armed.values {
            guard let trace = run.trace else { continue }
            trace.noteMark(label)
            marked += 1
        }
        return marked
    }

    /// Writes what the app saw of an armed run's window into its trace, when it differs
    /// from what the trace last said. Reads the frames presented so far first, so the
    /// change falls after them.
    func note(focus: FrameTrace.Focus, display: RunRecord.Display?, forApp appID: Int) {
        lock.lock()
        let changed = armed[appID].map { run in
            run.focus != focus || (display != nil && run.display != display)
        } ?? false
        lock.unlock()
        guard changed else { return }
        sample()
        lock.lock()
        defer { lock.unlock() }
        guard var run = armed[appID] else { return }
        if run.focus != focus {
            run.focus = focus
            run.trace?.noteFocus(focus)
        }
        if let display, run.display != display {
            run.display = display
            run.trace?.noteDisplay(display)
        }
        armed[appID] = run
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
        let pages = runDirectories.flatMap(Self.pages(in:))
        let now = Self.uptime
        lock.lock()
        for appID in Array(armed.keys) {
            let claimed = armed[appID]?.claimed ?? []
            armed[appID]?.absorb(pages.filter { $0.appid == appID || claimed.contains($0.pid) }, at: now)
        }
        lock.unlock()
    }

    deinit { timer?.cancel() }

    // MARK: - One run's samples

    /// How many frame times one run keeps in memory for its summary: about fourteen hours
    /// at 144 fps. The trace on disk has every frame either way.
    static let frameTimesKept = 8_000_000

    /// The counters of one launch: the page it is following, the per-second
    /// rates, the totals the average comes from, and every frame time the ring gave.
    private struct Run {
        var trace: FrameTrace.Writer?
        /// What the trace last said of the window, so it says each change once.
        var focus: FrameTrace.Focus?
        var display: RunRecord.Display?
        /// Processes counted for this run whatever app id their page carries
        /// (``PresentStats/claim(pid:forApp:)``).
        var claimed: Set<pid_t> = []
        /// Processes whose page this run has seen while they were alive. A page whose
        /// process is gone when the run first sees it is a dead launch's leftover — a
        /// killed process cannot unlink its own page — and its ring holds that launch's
        /// last frames, which are not this run's.
        private var seenAlive: Set<pid_t> = []
        private var frameTimes: [Float] = []
        private var droppedFrames = 0
        /// The process whose ring is being followed, the next ring index to read, and the
        /// last frame's stamp, which the next frame's time is measured from.
        private var ringPID: pid_t?
        private var ringNext: UInt64 = 0
        private var lastStamp: UInt32?
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
            for page in pages where page.alive {
                seenAlive.insert(page.pid)
            }
            let current = pages.filter { seenAlive.contains($0.pid) }
            guard let page = current.max(by: { $0.count < $1.count }) else {
                reading = nil
                return
            }
            // A page that went backwards is a new process under the same app
            // id — the count starts again, and so does the interval.
            if let previous = lastCount, let then = lastSampledAt,
               page.count >= previous, now > then {
                let seconds = now - then
                let frames = page.count - previous
                countedFrames += frames
                countedSeconds += seconds
                rates.append(Double(frames) / seconds)
                if rates.count > PresentStats.samplesKept { rates.removeFirst() }
            }
            lastCount = page.count
            lastSampledAt = now
            follow(page)
            reading = Reading(
                pid: page.pid, windowID: page.windowID, fps: rates.last ?? 0,
                silentFor: max(0, now - page.lastPresentUptime),
                presenting: page.alive,
            )
        }

        /// Reads the frames the page's ring gained since the last sample. A new process starts
        /// the ring over; a ring that turned more than once since the last read lost frames,
        /// which are counted rather than guessed.
        private mutating func follow(_ page: PresentStats.Page) {
            guard let ring = page.ring, page.ringCapacity > 8, page.ringHead > 1 else { return }
            let capacity = UInt64(page.ringCapacity)
            // One short of the head, where a slot may still be being written, and a few short
            // of a full ring at the tail, where the next frames overwrite the oldest.
            let end = page.ringHead - 1
            let oldest = end > capacity - 8 ? end - (capacity - 8) : 0
            if ringPID != page.pid {
                ringPID = page.pid
                ringNext = oldest
                lastStamp = nil
            }
            if ringNext < oldest {
                let lost = Int(oldest - ringNext)
                droppedFrames += lost
                trace?.noteDropped(lost)
                ringNext = oldest
                lastStamp = nil
            }
            guard ringNext < end else { return }
            var gained: [Float] = []
            gained.reserveCapacity(Int(end - ringNext))
            for index in ringNext ..< end {
                let stamp = ring[Int(index % capacity)]
                if let lastStamp {
                    // Wrapping microseconds: the difference of two neighbors is exact.
                    gained.append(Float(stamp &- lastStamp) / 1000)
                }
                lastStamp = stamp
            }
            ringNext = end
            trace?.append(gained)
            if frameTimes.count < PresentStats.frameTimesKept {
                frameTimes += gained.prefix(PresentStats.frameTimesKept - frameTimes.count)
            }
        }

        /// The record's frame rate: the average over the whole run, the mean of the slowest
        /// one per cent of the per-second samples, and when the engine has the ring, the
        /// frame-time summary and the trace it came from.
        var frameRate: RunRecord.FrameRate? {
            guard countedSeconds > 0, countedFrames > 0, !rates.isEmpty else { return nil }
            let slowest = rates.sorted().prefix(max(1, rates.count / 100))
            return RunRecord.FrameRate(
                avg: rounded(Double(countedFrames) / countedSeconds),
                low1: rounded(slowest.reduce(0, +) / Double(slowest.count)),
                samples: rates.count,
                frameTimes: FrameStats.summarize(frameTimes),
                dropped: droppedFrames > 0 ? droppedFrames : nil,
                trace: frameTimes.isEmpty ? nil : trace?.url.lastPathComponent,
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
        /// When the Cocoa main thread's run loop last turned; the engine writes it once a
        /// second. `nil` on a page from an engine that does not. Presents keep counting from the
        /// game's own threads while the main thread is blocked or gone, and the window then
        /// answers nothing: this is the field that stops.
        var mainBeatUptime: TimeInterval?
        /// The process that wrote the page is still running. A killed
        /// process cannot unlink its own page.
        var alive: Bool
        /// The frame-time ring (`sevo_stats_page.ring`): frames written so far, the slots,
        /// and each slot's stamp in wrapping microseconds. Nil ring on an engine without one.
        var ringHead: UInt64 = 0
        var ringCapacity: Int = 0
        var ring: [UInt32]?

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

    /// How long a process's main thread has gone without turning its run loop: `nil` when
    /// the process has no page, is gone, or runs on an engine that writes no beat.
    static func mainThreadSilence(
        of pid: pid_t, in directory: URL = SteamBottle.root.appendingPathComponent(".sevo/run"),
    ) -> TimeInterval? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(pid).stats")),
              let page = page(from: data), page.alive, let beat = page.mainBeatUptime
        else { return nil }
        return max(0, uptime - beat)
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
        let exe = data[64 ..< 96]
        let ring = ring(in: data)
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
            mainBeatUptime: data.count >= 104 && word(96) != 0 ? seconds(word(96)) : nil,
            alive: kill(pid, 0) == 0 || errno != ESRCH,
            ringHead: ring?.head ?? 0,
            ringCapacity: ring?.slots.count ?? 0,
            ring: ring?.slots,
        )
    }

    /// The ring at offset 104: the head, the capacity, the slots from 120. Nil when the
    /// page has none or claims more slots than it holds.
    private static func ring(in data: Data) -> (head: UInt64, slots: [UInt32])? {
        guard data.count >= 120 else { return nil }
        return data.withUnsafeBytes { raw in
            let capacity = Int(raw.loadUnaligned(fromByteOffset: 112, as: UInt32.self))
            guard capacity > 0, 120 + capacity * 4 <= raw.count else { return nil }
            let head = raw.loadUnaligned(fromByteOffset: 104, as: UInt64.self)
            let slots = (0 ..< capacity).map {
                raw.loadUnaligned(fromByteOffset: 120 + $0 * 4, as: UInt32.self)
            }
            return (head, slots)
        }
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
