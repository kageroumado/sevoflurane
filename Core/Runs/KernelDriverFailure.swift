import Foundation

/// A Windows program's kernel driver (anti-cheat, some DRM) that Wine could
/// not load. A program that needs it quits or waits with nothing on screen,
/// and only Wine's log says why.
nonisolated enum KernelDriverFailure {
    /// The driver named in a failure line of Wine's log, like
    /// `HoYoKProtect.sys`, or `nil` when the text has none.
    ///
    /// Two shapes: the loader missing a kernel import for a `.sys` image
    /// (`import_dll Library WDFLDR.SYS (which is needed by L"…\HoYoKProtect.sys") not found`),
    /// and ntoskrnl failing to start a driver service
    /// (`ZwLoadDriver failed to create driver L"\Driver\HoYoKProtect"`).
    static func driver(in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("import_dll") || line.contains("ZwLoadDriver") {
            if let neededBy = line.range(of: #"needed by L"[^"]*\\([^\\"]+\.sys)""#, options: [.regularExpression, .caseInsensitive]) {
                let quoted = line[neededBy]
                if let name = quoted.split(separator: "\\").last?.split(separator: "\"").first {
                    return String(name)
                }
            }
            if line.contains("ZwLoadDriver"),
               let driver = line.range(of: #"\\+Driver\\+[^"\\]+"#, options: .regularExpression) {
                return String(line[driver].split(separator: "\\").last ?? "") + ".sys"
            }
        }
        return nil
    }

    /// How long after a launch the log is read for a driver failure: an
    /// anti-cheat service starts with its program, well inside this.
    static let watchFor: Duration = .seconds(60)
    static let pollEvery: Duration = .seconds(5)

    /// What the log says about a launched program.
    enum Outcome: Equatable {
        /// One of the program's processes drew more than a splash.
        case presented
        /// A driver failed to load and nothing of the program has drawn more
        /// than a splash.
        case driverFailed(String)
        case nothing
    }

    /// The fewest frames a process presents once it draws: a splash presents
    /// once per repaint and a game every frame, so half a second of frames
    /// tells them apart.
    static let fewestFrames: UInt64 = 30

    /// The smallest picture a game renders, 320 by 180. A surface narrower or
    /// shorter is a splash or a banner (283 by 70 in the case on record).
    static let smallestPicture = (width: 320, height: 180)

    /// What `text`, the log since the program's launch, says about it. The
    /// program's processes are its own executable, any process started under
    /// `appID`, and any process started with no Steam app id outside Wine's
    /// own: a launcher's game is the last. One of them that drew
    /// (``drew(frames:largestSurface:)``) answers ``Outcome/presented``
    /// whatever driver failed.
    ///
    /// - Parameter frames: The frames a process has presented so far, by its
    ///   macOS pid, for a process that has logged no count of its own: the
    ///   engine writes one only at a process's exit.
    static func outcome(
        in text: String, program exe: String, appID: Int? = nil,
        frames: (pid_t) -> UInt64? = { _ in nil },
    ) -> Outcome {
        let wanted = exe.lowercased()
        let ownID = appID.map(String.init)
        var programPIDs: Set<Substring> = []
        var presentedPIDs: Set<Substring> = []
        var framesAtExit: [Substring: UInt64] = [:]
        var largestSurface: [Substring: (width: Int, height: Int)] = [:]
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("sevo:") {
            if let match = line.firstMatch(of: run) {
                let name = match.output.2.lowercased()
                let started = match.output.3
                if name == wanted || ownID.map({ $0 == started }) == true
                    || (started == "none" && !wineOwn.contains(name)) {
                    programPIDs.insert(match.output.1)
                }
            } else if let match = line.firstMatch(of: firstPresent) {
                presentedPIDs.insert(match.output.1)
            } else if let match = line.firstMatch(of: exitPresents) {
                framesAtExit[match.output.1] = UInt64(match.output.2)
            } else if let match = line.firstMatch(of: source) ?? line.firstMatch(of: chain),
                      let width = Int(match.output.2), let height = Int(match.output.3) {
                let known = largestSurface[match.output.1]
                if width * height > (known.map { $0.width * $0.height } ?? 0) {
                    largestSurface[match.output.1] = (width, height)
                }
            }
        }
        let drew = programPIDs.intersection(presentedPIDs).contains { pid in
            Self.drew(
                frames: framesAtExit[pid] ?? pid_t(pid).flatMap(frames),
                largestSurface: largestSurface[pid],
            )
        }
        if drew { return .presented }
        return driver(in: text).map(Outcome.driverFailed) ?? .nothing
    }

    /// Whether a process that presented a frame drew more than a splash. Its
    /// frame count decides when one is known; else the largest surface the
    /// presenter named for it; with neither, the frame it presented stands.
    ///
    /// The count comes first because the presenter names a surface only for
    /// the frames it carries itself: a renderer that presents its own
    /// drawables can leave a small window's surface as the only one named.
    static func drew(frames: UInt64?, largestSurface: (width: Int, height: Int)?) -> Bool {
        if let frames { return frames >= fewestFrames }
        if let largestSurface {
            return largestSurface.width >= smallestPicture.width && largestSurface.height >= smallestPicture.height
        }
        return true
    }

    /// Polls Wine's log after `offset` for ``watchFor``; answers the failed
    /// driver when the program drew nothing, `nil` once it draws.
    ///
    /// - Parameter frames: See ``outcome(in:program:appID:frames:)``; the
    ///   bottles' present counters unless a test supplies its own.
    static func watch(
        from offset: UInt64, program exe: String, log: URL = WineLog.fileURL,
        frames: () -> [pid_t: UInt64] = { countedFrames() },
    ) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now + watchFor
        var last = Outcome.nothing
        while clock.now < deadline {
            try? await Task.sleep(for: pollEvery)
            guard let handle = try? FileHandle(forReadingFrom: log) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd() else { continue }
            let counted = frames()
            last = outcome(in: String(decoding: data, as: UTF8.self), program: exe) { counted[$0] }
            if last == .presented { return nil }
        }
        if case let .driverFailed(driver) = last { return driver }
        return nil
    }

    /// The frames each process of the bottle and its companion prefix has
    /// presented, from the driver's counter pages (``PresentStats``). A page
    /// outlives a killed process, so a count stands after its process is gone.
    static func countedFrames(
        in directories: [URL] = [SteamBottle.root, SteamBottle.companion].map { $0.appendingPathComponent(".sevo/run") },
    ) -> [pid_t: UInt64] {
        var counted: [pid_t: UInt64] = [:]
        for page in directories.flatMap(PresentStats.pages(in:)) {
            counted[page.pid] = max(page.frames, page.drawables)
        }
        return counted
    }

    // The executable's name can carry spaces, so it runs to the app id.
    private nonisolated(unsafe) static let run = /sevo:run pid=(\d+) exe=(.+?) appid=(\S+)/
    private nonisolated(unsafe) static let firstPresent = /sevo:gfx pid=(\d+) first present/
    /// Written as a process exits: every frame it presented.
    private nonisolated(unsafe) static let exitPresents = /sevo:gfx pid=(\d+) exit presents=(\d+)/
    /// The presenter's frame ring, made at the size the renderer draws.
    private nonisolated(unsafe) static let source = /sevo:presenter pid=(\d+) (?:gl )?source (\d+)x(\d+)/
    /// The presenter's scaling chain, from the size it is handed to the size on screen.
    private nonisolated(unsafe) static let chain = #/sevo:presenter pid=(\d+) chain .+ (\d+)x(\d+) -> /#

    /// The prefix's own processes, which start with no app id and never draw
    /// for a program.
    private static let wineOwn: Set<String> = [
        "conhost.exe", "explorer.exe", "plugplay.exe", "rpcss.exe", "rundll32.exe", "services.exe",
        "start.exe", "svchost.exe", "tabtip.exe", "wineboot.exe", "winedbg.exe", "winedevice.exe",
    ]

    static func size(of url: URL = WineLog.fileURL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
