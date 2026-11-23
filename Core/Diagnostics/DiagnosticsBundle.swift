import Foundation

/// The report bundle: app logs, `doctor` and `status`, the machine, the
/// engine's `engine-info.json`, the bottle's env files, launcher bundles,
/// Steam's logs, this month's runs with their game logs, and two days of
/// crash reports, every file passed through ``Redaction``. `sevo diag` and
/// the app's panel about a run share it; what only a face knows arrives through
/// ``faceReport``.
nonisolated enum Diagnostics {
    /// What the building face knows, as JSON text.
    struct FaceReport: Sendable {
        var doctor: String?
        var status: String?
        /// `bottle/dependencies.json`.
        var bottleState: String?
        /// Merged into `host.json`.
        var host: [String: String] = [:]
    }

    enum Failure: Error, CustomStringConvertible {
        case couldNotWrite(path: String, reason: String)

        var description: String {
            switch self {
            case let .couldNotWrite(path, reason): "could not write \(path): \(reason)"
            }
        }
    }

    /// Installed by the process: the CLI answers with `Doctor`, the app asks
    /// its bundled `sevo`.
    nonisolated(unsafe) static var faceReport: @Sendable () async -> FaceReport = { FaceReport() }

    /// `console_log.txt` carries the `GameAction` trail and a game's exit code.
    static let steamLogNames = [
        "bootstrap_log.txt", "connection_log.txt", "webhelper.txt", "gameprocess_log.txt",
        "console_log.txt",
    ]
    /// How far back crash reports and exception sidecars are collected.
    static let crashReportWindow: TimeInterval = 48 * 3600
    static let appLogNames = [
        "Sevoflurane.log", "Sevoflurane.old.log", "Sevoflurane-wine.log", "Sevoflurane-wine.old.log",
        "Sevoflurane-windows.log",
    ]

    /// Writes the bundle into a directory, at a `.zip` path, or on the
    /// Desktop, and answers where.
    ///
    /// `run` narrows it to one run, for a report about that run alone: its
    /// record in place of the month's, its game's logs and settings in place
    /// of every game's, crash reports from its start on, and no launcher
    /// list. The app's, Wine's and Steam's logs are whole either way.
    static func bundle(to destination: URL?, steamLogs: Bool, onlyRun run: RunRecord? = nil) async throws -> URL {
        let manager = FileManager.default
        let name = "Sevoflurane-report-\(stamp.string(from: Date()))"
        let zip: URL = if let destination, destination.pathExtension == "zip" {
            destination
        } else {
            (destination ?? UserHome.url.appending(path: "Desktop"))
                .appendingPathComponent("\(name).zip")
        }
        let staging = Staging(root: manager.temporaryDirectory.appendingPathComponent(name))
        try staging.begin()
        defer { staging.end() }

        let face = await faceReport()
        if let doctor = face.doctor { staging.write(doctor, as: "doctor.json") }
        if let status = face.status { staging.write(status, as: "status.json") }
        await staging.write(JSONText.string(host(face: face), pretty: true), as: "host.json")
        if let bottleState = face.bottleState {
            staging.write(bottleState, as: "bottle/dependencies.json")
        }
        collectAppLogs(into: staging)
        collectEngineAndBottle(into: staging, onlyApp: run?.appid)
        if run == nil { collectLaunchers(into: staging) }
        collectCrashReports(into: staging, since: run.flatMap { ISO8601DateFormatter().date(from: $0.t) })
        if steamLogs { collectSteamLogs(into: staging) }
        collectRuns(into: staging, only: run)
        staging.writeContents()

        try? manager.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: zip)
        let ditto = await Subprocess.run(
            "/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", staging.root.path, zip.path],
            capture: .combined, timeout: .seconds(60),
        )
        guard ditto.status == 0, manager.fileExists(atPath: zip.path) else {
            throw Failure.couldNotWrite(path: zip.path, reason: ditto.output)
        }
        return zip
    }

    // MARK: - The pieces

    private static func collectAppLogs(into staging: Staging) {
        for file in appLogNames {
            staging.copy(logs.appendingPathComponent(file), as: "logs/\(file)")
        }
        // `ExceptionWatch` sidecars.
        for url in recentFiles(in: logs, where: { $0.hasPrefix("Sevoflurane-exception-") && $0.hasSuffix(".json") }) {
            staging.copy(url, as: "logs/\(url.lastPathComponent)")
        }
    }

    private static func collectEngineAndBottle(into staging: Staging, onlyApp appID: Int?) {
        staging.copy(Engine.active.root.appendingPathComponent("engine-info.json"), as: "engine/engine-info.json")
        let sevoDir = SteamBottle.root.appendingPathComponent(".sevo")
        staging.copy(sevoDir.appendingPathComponent("bottle.env"), as: "bottle/bottle.env")
        // Present only while debug mode is on.
        staging.copy(sevoDir.appendingPathComponent("debug.env"), as: "bottle/debug.env")
        let apps = sevoDir.appendingPathComponent("apps")
        for app in (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? [] {
            let file = apps.appendingPathComponent(app)
            // Each game's file names it in `# app <id> <name>` (``ConfigMaterializer``).
            if let appID, !isEnvFile(file, ofApp: appID) { continue }
            staging.copy(file, as: "bottle/apps/\(app)")
        }
    }

    static func isEnvFile(_ file: URL, ofApp appID: Int) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        // After the writer's own header line.
        return text.split(whereSeparator: \.isNewline).prefix(3).contains { line in
            line == "# app \(appID)" || line.hasPrefix("# app \(appID) ")
        }
    }

    /// Which games have a launcher bundle, and on which engine.
    private static func collectLaunchers(into staging: Staging) {
        let launchers = GameLaunchers.inventory()
        staging.write(
            launchers.isEmpty ? "no launcher bundles\n" : launchers.joined(separator: "\n") + "\n",
            as: "launchers.txt",
        )
    }

    /// Our crash reports, matched by the per-run collector's lists.
    private static func collectCrashReports(into staging: Staging, since: Date?) {
        let reports = logs.appendingPathComponent("DiagnosticReports")
        for url in recentFiles(in: reports, since: since, where: { _ in true })
            where CrashReportIPS.isOurs(
                url, prefixes: CrashCollector.ourCrashReportPrefixes,
                pathMarkers: CrashCollector.ourImageMarkers,
            ) {
            staging.copy(url, as: "crashes/\(url.lastPathComponent)")
        }
    }

    private static func collectSteamLogs(into staging: Staging) {
        let steamLogs = SteamBottle.steamRoot.appendingPathComponent("logs")
        for file in steamLogNames {
            staging.copy(steamLogs.appendingPathComponent(file), as: "steam/\(file)")
        }
    }

    /// The month's run records and their games' own logs, or one run's.
    private static func collectRuns(into staging: Staging, only run: RunRecord?) {
        if let run {
            if let line = try? JSONEncoder().encode(run) {
                staging.write(String(decoding: line, as: UTF8.self) + "\n", as: "runs/run.jsonl")
            }
            for log in GameLogs.collect(for: [run]) {
                staging.write(log.text, as: log.path)
            }
            return
        }
        let runs = RunLog.records(inMonth: Date())
        let month = RunLog.url(forMonth: Date())
        staging.copy(month, as: "runs/\(month.lastPathComponent)")
        for log in GameLogs.collect(for: runs) {
            staging.write(log.text, as: log.path)
        }
    }

    /// The machine and the software on it, without the account.
    private static func host(face: FaceReport) async -> [String: Any] {
        var host: [String: Any] = [
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "engine": Engine.active.description,
        ]
        for (key, name) in [("hw.model", "model"), ("machdep.cpu.brand_string", "chip"), ("hw.memsize", "memory_bytes")] {
            let result = await Subprocess.run("/usr/sbin/sysctl", ["-n", key], timeout: .seconds(5))
            if result.status == 0 { host[name] = result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let version = appVersion { host["app"] = version }
        if let audio = HostSnapshot.defaultAudioOutput() {
            host["audio_output"] = [
                "name": audio.name, "transport": audio.transport,
                "sample_rate_hz": audio.sampleRateHz, "running": audio.running,
            ] as [String: Any]
        }
        for (key, value) in face.host {
            host[key] = value
        }
        return host
    }

    /// The app's marketing version, also from `Contents/Helpers/sevo`.
    private static var appVersion: String? {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        let contents = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
        guard let contents, let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    private static var logs: URL {
        UserHome.url.appending(path: "Library/Logs")
    }

    /// The files in a directory modified inside the crash report window.
    private static func recentFiles(
        in directory: URL, since: Date? = nil, where wanted: (String) -> Bool,
    ) -> [URL] {
        let since = since ?? Date().addingTimeInterval(-crashReportWindow)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter(wanted).map(directory.appendingPathComponent).filter { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return modified.map { $0 > since } ?? false
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private final class Staging {
        let root: URL
        private var contents: [String] = []
        private let manager = FileManager.default

        init(root: URL) {
            self.root = root
        }

        func begin() throws {
            try? manager.removeItem(at: root)
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func end() {
            try? manager.removeItem(at: root)
        }

        /// Everything goes through ``Redaction``: the zip is attached to
        /// public issues.
        func write(_ text: String, as file: String) {
            let url = root.appendingPathComponent(file)
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let redacted = Redaction.apply(to: text)
            if (try? redacted.write(to: url, atomically: true, encoding: .utf8)) != nil { contents.append(file) }
        }

        func copy(_ source: URL, as file: String) {
            guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return }
            write(String(decoding: data, as: UTF8.self), as: file)
        }

        func writeContents() {
            write(contents.sorted().joined(separator: "\n") + "\n", as: "contents.txt")
        }
    }
}
