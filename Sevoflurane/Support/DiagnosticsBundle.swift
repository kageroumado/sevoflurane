import Foundation

/// The report bundle: the three logs, `doctor` and `status` as JSON, the
/// machine, the active engine's `engine-info.json`, the bottle's env files
/// and dependency state, the game launcher bundles, Steam's own logs, this
/// month's run records with the logs the games in them wrote for themselves,
/// and the last two days of crash reports from the engine's processes.
/// Nothing in it names the account; crash reports and env files carry paths
/// under the home directory, so the user's short name is in them.
///
/// One builder for every face of the project: `sevo diag` writes it to the
/// Desktop, the app's crash prompt sends it. Whatever a face knows that this
/// code cannot ask — the doctor's verdicts, the daemon's status — arrives
/// through ``faceReport``.
nonisolated enum Diagnostics {
    /// What the face building the bundle knows about the installation and
    /// this code cannot find out for itself, as JSON text ready to write.
    struct FaceReport: Sendable {
        /// The doctor's verdicts (`doctor.json`).
        var doctor: String?
        /// The daemon's status (`status.json`).
        var status: String?
        /// The bottle's dependency catalog and last provisioning outcome
        /// (`bottle/dependencies.json`).
        var bottleState: String?
        /// Which face wrote the bundle and its version, merged into `host.json`.
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

    /// Installed by the process before it builds a bundle. The CLI answers
    /// with `Doctor`; the app asks its bundled `sevo` the same questions.
    nonisolated(unsafe) static var faceReport: @Sendable () async -> FaceReport = { FaceReport() }

    /// `console_log.txt` carries the whole `GameAction` trail and the exit
    /// code of a game the client started, which is the answer to most of what
    /// a launch failure is asked about.
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

    /// Writes the bundle and answers where it went.
    ///
    /// - Parameter destination: A directory the zip is named into, a `.zip`
    ///   path it is written at, or nil for the Desktop.
    static func bundle(to destination: URL?, steamLogs: Bool) async throws -> URL {
        let manager = FileManager.default
        let name = "Sevoflurane-report-\(stamp.string(from: Date()))"
        let zip: URL = if let destination, destination.pathExtension == "zip" {
            destination
        } else {
            (destination ?? manager.homeDirectoryForCurrentUser.appending(path: "Desktop"))
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
        collectEngineAndBottle(into: staging)
        collectLaunchers(into: staging)
        collectCrashReports(into: staging)
        if steamLogs { collectSteamLogs(into: staging) }
        collectRuns(into: staging)
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
        // One sidecar per ObjC exception the app caught (`ExceptionWatch`),
        // over the same window as the crash reports.
        for url in recentFiles(in: logs, where: { $0.hasPrefix("Sevoflurane-exception-") && $0.hasSuffix(".json") }) {
            staging.copy(url, as: "logs/\(url.lastPathComponent)")
        }
    }

    private static func collectEngineAndBottle(into staging: Staging) {
        staging.copy(Engine.active.root.appendingPathComponent("engine-info.json"), as: "engine/engine-info.json")
        let sevoDir = SteamBottle.root.appendingPathComponent(".sevo")
        staging.copy(sevoDir.appendingPathComponent("bottle.env"), as: "bottle/bottle.env")
        // Present only while debug mode is on, which is itself the answer to
        // "why is this Wine log so large".
        staging.copy(sevoDir.appendingPathComponent("debug.env"), as: "bottle/debug.env")
        let apps = sevoDir.appendingPathComponent("apps")
        for app in (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? [] {
            staging.copy(apps.appendingPathComponent(app), as: "bottle/apps/\(app)")
        }
    }

    /// Which games have a launcher bundle, and on which engine: a game whose
    /// Dock tile says "wine" either has no bundle or did not take it, and the
    /// two look identical from the outside.
    private static func collectLaunchers(into staging: Staging) {
        let launchers = GameLaunchers.inventory()
        staging.write(
            launchers.isEmpty ? "no launcher bundles\n" : launchers.joined(separator: "\n") + "\n",
            as: "launchers.txt",
        )
    }

    /// The reports macOS wrote for the engine's processes and for the games
    /// they ran, whichever name a report carries. The per-run collector and
    /// this bundle answer the question with the same lists, so a report one
    /// keeps the other keeps too.
    private static func collectCrashReports(into staging: Staging) {
        let reports = logs.appendingPathComponent("DiagnosticReports")
        for url in recentFiles(in: reports, where: { _ in true })
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

    /// The month's run records, and the logs the games in them wrote for
    /// themselves — the two things that say what a launch did rather than
    /// what the app saw of it.
    private static func collectRuns(into staging: Staging) {
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
        for (key, value) in face.host {
            host[key] = value
        }
        return host
    }

    /// The app's marketing version, whether this process is the app or the
    /// CLI riding inside it as `Contents/Helpers/sevo`.
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
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs")
    }

    /// The files in a directory modified inside the crash report window.
    private static func recentFiles(in directory: URL, where wanted: (String) -> Bool) -> [URL] {
        let since = Date().addingTimeInterval(-crashReportWindow)
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

    /// The directory the zip is made from, and the list of what landed in it.
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

        /// Everything the zip carries is text, and all of it goes through
        /// ``Redaction``: the zip is what people attach to a public issue.
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
