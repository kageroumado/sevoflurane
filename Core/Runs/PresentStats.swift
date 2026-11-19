import Darwin
import Foundation

/// The frame rate of a running game, read from the driver.
///
/// Every renderer presents through `winemac.drv`, which counts presents into a
/// 4 KB page per process at `<prefix>/.sevo/run/<pid>.stats`
/// (`dlls/winemac.drv/sevo_stats.c`). Reading it needs no hook in the game, so
/// a title with its own anti-tamper still gets an fps number and a stall signal.
final nonisolated class PresentStats: @unchecked Sendable {
    /// How often the pages are read; also the resolution of the 1 % low.
    static let interval: TimeInterval = 1

    /// Per-second samples one run keeps: four hours. The average comes from
    /// totals, so it outlives dropped samples.
    static let samplesKept = 4 * 60 * 60

    /// Asked at every sample, so a bottle switch needs no app restart.
    private let runDirectories: () -> [URL]
    private let lock = NSLock()
    private var armed: [Int: Run] = [:]
    private var timer: DispatchSourceTimer?

    /// - Parameters:
    ///   - prefix: the bottle whose `.sevo/run` holds the pages.
    ///   - companions: other prefixes whose pages are read too, such as the
    ///     HoYoverse companion (``SteamParent``).
    init(prefix: URL, companions: [URL] = []) {
        let directories = ([prefix] + companions).map { $0.appendingPathComponent(".sevo/run") }
        runDirectories = { directories }
    }

    /// The live bottle and its companion, as chosen at each sample.
    init() {
        runDirectories = { [SteamBottle.root, SteamBottle.companion].map { $0.appendingPathComponent(".sevo/run") } }
    }

    /// Whether `appID`'s run has counted a frame yet.
    func hasCounted(forApp appID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed[appID]?.hasCounted ?? false
    }

    /// Counts `pid`'s page toward `appID`'s run whatever app id the page
    /// carries: a program Steam did not start has none.
    func claim(pid: pid_t, forApp appID: Int) {
        lock.lock()
        armed[appID]?.claimed.insert(pid)
        lock.unlock()
    }

    // MARK: - What a caller sees

    /// One armed run's counter as it stands right now.
    struct Reading: Equatable, Sendable {
        /// The busiest presenter among the run's processes.
        var pid: pid_t
        /// The Cocoa window number, 0 when no present path named one.
        var windowID: UInt64
        /// The last per-second sample, or 0 before the first one.
        var fps: Double
        /// How long the process has gone without a present: the stall
        /// watchdog's "no present for N seconds while alive".
        var silentFor: TimeInterval
        /// The run has a page and the process that wrote it is alive.
        var presenting: Bool
    }

    /// Starts sampling `appID`'s pages, writing frames to `trace` when given.
    func arm(appID: Int, trace: FrameTrace.Writer? = nil) {
        lock.lock()
        armed[appID]?.trace?.close()
        armed[appID] = Run(trace: trace)
        let needsTimer = timer == nil
        lock.unlock()
        if needsTimer { startTimer() }
    }

    /// Ends the run and returns its frame rate, or nil for a run that never
    /// presented (the record's `fps: null`).
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

    /// Samples first, then writes a mark into every armed run's trace, so the
    /// mark falls where it was asked for. Returns how many traces took it.
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

    /// Writes a change in the window's focus or display into the run's trace,
    /// sampling first so the change falls after the frames before it.
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

    /// The run's current reading, or nil when unarmed or without a page.
    func reading(forApp appID: Int) -> Reading? {
        lock.lock()
        defer { lock.unlock() }
        return armed[appID]?.reading
    }

    /// Reads every page once and folds it into the armed runs.
    func sample() {
        let pages = runDirectories().flatMap(Self.pages(in:))
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

    /// Frame times one run keeps in memory: about fifteen hours at 144 fps.
    /// The trace on disk has every frame.
    static let frameTimesKept = 8_000_000

    /// The counters of one launch.
    private struct Run {
        var trace: FrameTrace.Writer?
        /// What the trace last said, so each change is written once.
        var focus: FrameTrace.Focus?
        var display: RunRecord.Display?
        /// See ``PresentStats/claim(pid:forApp:)``.
        var claimed: Set<pid_t> = []
        /// Processes whose page this run has seen alive. A page whose process is
        /// already gone is a killed launch's leftover and is ignored.
        private var seenAlive: Set<pid_t> = []
        private var frameTimes: [Float] = []
        private var droppedFrames = 0
        /// The followed ring's process, next index, and last frame stamp.
        private var ringPID: pid_t?
        private var ringNext: UInt64 = 0
        private var lastStamp: UInt32?
        private var lastCount: UInt64?
        private var lastSampledAt: TimeInterval?
        private var countedFrames: UInt64 = 0
        var hasCounted: Bool { countedFrames > 0 }
        private var countedSeconds: TimeInterval = 0
        private var rates: [Double] = []
        var reading: Reading?

        /// Folds this second's pages in. The rate is the busiest page's: of a
        /// launcher, the game and a crash handler, only one draws.
        mutating func absorb(_ pages: [PresentStats.Page], at now: TimeInterval) {
            for page in pages where page.alive {
                seenAlive.insert(page.pid)
            }
            let current = pages.filter { seenAlive.contains($0.pid) }
            guard let page = current.max(by: { $0.count < $1.count }) else {
                reading = nil
                return
            }
            // A count that went backwards is a new process: start over.
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

        /// Reads the frames the ring gained since the last sample. Frames lost to
        /// a ring that wrapped past the last read are counted as dropped.
        private mutating func follow(_ page: PresentStats.Page) {
            guard let ring = page.ring, page.ringCapacity > 8, page.ringHead > 1 else { return }
            let capacity = UInt64(page.ringCapacity)
            // Stop one short of the head (a slot may be mid-write) and keep 8
            // slots clear at the tail (about to be overwritten).
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

        /// The record's frame rate: whole-run average, mean of the slowest 1 %
        /// of per-second samples, and the frame-time summary when there is a ring.
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
        /// Presents that reached the screen. D3DMetal coalesces these, so
        /// `drawables` is the rate wherever it is non-zero.
        var frames: UInt64
        /// Frames the renderer produced, one per Metal drawable.
        var drawables: UInt64
        var windowID: UInt64
        var source: Source
        var lastPresentUptime: TimeInterval
        var startedUptime: TimeInterval
        /// When the Cocoa main thread's run loop last turned, written once a
        /// second; nil on engines without it. Presents keep counting while the
        /// main thread is blocked, so this is the field that shows a hang.
        var mainBeatUptime: TimeInterval?
        /// The writer is still running; a killed process leaves its page.
        var alive: Bool
        /// The frame-time ring (`sevo_stats_page.ring`): frames written, slot
        /// count, and stamps in wrapping microseconds. Nil on engines without one.
        var ringHead: UInt64 = 0
        var ringCapacity: Int = 0
        var ring: [UInt32]?

        /// Which path counted `frames`.
        enum Source: UInt32, Sendable {
            case none = 0
            case clientSurface = 1
            case presenter = 2
        }

        /// The frames to measure a rate from: the presenter's count where it
        /// runs, else drawables, else the driver's presents (Vulkan, OpenGL, GDI).
        var count: UInt64 {
            if source == .presenter { return frames }
            return drawables > 0 ? drawables : frames
        }
    }

    /// How long a process's main thread has gone without turning its run loop;
    /// nil without a live page carrying a beat.
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

    /// Decodes one page: little-endian fields in `struct sevo_stats_page`
    /// order. The magic is written last, so a page without it is mid-creation.
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

    /// The ring: head at 104, capacity at 112, slots from 120. Nil when absent
    /// or claiming more slots than the page holds.
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

    /// The clock both sides share. Mach ticks differ between the Rosetta
    /// writer and this arm64 reader; `CLOCK_UPTIME_RAW` is nanoseconds on both.
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
