import ArgumentParser
import Foundation

/// `sevo diag`: what a bug report needs, in one zip on the Desktop.
struct DiagCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diag",
        abstract: "Write a zip of the logs, a doctor report and the engine's identity, for a bug report.",
    )

    @Option(
        name: .customLong("output"),
        help: "A directory, or a .zip path. Default: the Desktop.",
    ) var output: String?
    @Flag(
        name: .customLong("steam-logs"),
        inversion: .prefixedNo,
        help: "Steam's own bootstrap, connection, webhelper, game-process and console logs from the bottle.",
    ) var steamLogs = true
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        let destination = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let zip = try await Diagnostics.bundle(to: destination, steamLogs: steamLogs)
        print(asJSON ? Sevo.json(["path": zip.path]) : zip.path)
    }
}

/// The report bundle: the three logs, `doctor` and `status` as JSON, the
/// machine, the active engine's `engine-info.json`, the bottle's env files
/// and dependency state, the game launcher bundles, Steam's own logs, this
/// month's run records with the logs the games in them wrote for themselves,
/// and the last two days of crash reports from the engine's processes.
/// Nothing in it names the account; crash reports and env files carry paths
/// under the home directory, so the user's short name is in them.
nonisolated enum Diagnostics {
    static let crashReportPrefixes = ["wine", "wine64", "nwjs", "Sevoflurane", "steam", "sevo-"]
    /// `console_log.txt` carries the whole `GameAction` trail and the exit
    /// code of a game the client started, which is the answer to most of what
    /// a launch failure is asked about.
    static let steamLogNames = [
        "bootstrap_log.txt", "connection_log.txt", "webhelper.txt", "gameprocess_log.txt",
        "console_log.txt",
    ]
    /// How far back crash reports and exception sidecars are collected.
    static let crashReportWindow: TimeInterval = 48 * 3600

    static func bundle(to destination: URL?, steamLogs: Bool) async throws -> URL {
        let manager = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let name = "Sevoflurane-report-\(formatter.string(from: Date()))"
        let zip: URL = if let destination, destination.pathExtension == "zip" {
            destination
        } else {
            (destination ?? manager.homeDirectoryForCurrentUser.appending(path: "Desktop"))
                .appendingPathComponent("\(name).zip")
        }
        let staging = manager.temporaryDirectory.appendingPathComponent(name)
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        var contents: [String] = []
        func write(_ text: String, as file: String) {
            let url = staging.appendingPathComponent(file)
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { contents.append(file) }
        }
        func copy(_ source: URL, as file: String? = nil) {
            let target = staging.appendingPathComponent(file ?? source.lastPathComponent)
            guard manager.fileExists(atPath: source.path) else { return }
            try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? manager.copyItem(at: source, to: target)) != nil { contents.append(file ?? source.lastPathComponent) }
        }

        let snapshot = await Doctor.snapshot()
        let checks = Doctor.checks(from: snapshot)
        write(Sevo.json(Doctor.jsonReport(from: snapshot, checks: checks), pretty: true), as: "doctor.json")
        if let status = snapshot.appStatus {
            write(Sevo.json(status, pretty: true), as: "status.json")
        }
        write(Sevo.json(await host(), pretty: true), as: "host.json")
        let bottleState: [String: Any] = [
            "dependencies": snapshot.dependencies,
            "provisioning": snapshot.provision.map(\.dictionary) ?? NSNull(),
        ]
        write(Sevo.json(bottleState, pretty: true), as: "bottle/dependencies.json")

        let logs = manager.homeDirectoryForCurrentUser.appending(path: "Library/Logs")
        for file in [
            "Sevoflurane.log", "Sevoflurane.old.log", "Sevoflurane-wine.log", "Sevoflurane-wine.old.log",
            "Sevoflurane-windows.log",
        ] {
            copy(logs.appendingPathComponent(file), as: "logs/\(file)")
        }
        // One sidecar per ObjC exception the app caught (`ExceptionWatch`),
        // over the same window as the crash reports below.
        let recentReports = Date().addingTimeInterval(-crashReportWindow)
        for file in (try? manager.contentsOfDirectory(atPath: logs.path)) ?? []
            where file.hasPrefix("Sevoflurane-exception-") && file.hasSuffix(".json") {
            let url = logs.appendingPathComponent(file)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified > recentReports else { continue }
            copy(url, as: "logs/\(file)")
        }

        let engine = Engine.active
        copy(engine.root.appendingPathComponent("engine-info.json"), as: "engine/engine-info.json")
        let sevoDir = SteamBottle.root.appendingPathComponent(".sevo")
        copy(sevoDir.appendingPathComponent("bottle.env"), as: "bottle/bottle.env")
        for app in (try? manager.contentsOfDirectory(atPath: sevoDir.appendingPathComponent("apps").path)) ?? [] {
            copy(sevoDir.appendingPathComponent("apps/\(app)"), as: "bottle/apps/\(app)")
        }

        // Which games have a launcher bundle, and on which engine: a game
        // whose Dock tile says "wine" either has no bundle or did not take
        // it, and the two look identical from the outside.
        let launchers = GameLaunchers.inventory()
        write(
            launchers.isEmpty ? "no launcher bundles\n" : launchers.joined(separator: "\n") + "\n",
            as: "launchers.txt",
        )

        let reports = logs.appendingPathComponent("DiagnosticReports")
        let recent = Date().addingTimeInterval(-crashReportWindow)
        for file in (try? manager.contentsOfDirectory(atPath: reports.path)) ?? [] {
            guard crashReportPrefixes.contains(where: { file.hasPrefix($0) }) else { continue }
            let url = reports.appendingPathComponent(file)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified > recent else { continue }
            copy(url, as: "crashes/\(file)")
        }

        if steamLogs {
            let steamLogs = SteamBottle.steamRoot.appendingPathComponent("logs")
            for file in steamLogNames {
                copy(steamLogs.appendingPathComponent(file), as: "steam/\(file)")
            }
        }

        // The month's run records, and the logs the games in them wrote for
        // themselves — the two things that say what a launch did rather than
        // what the app saw of it.
        let runs = RunLog.records(inMonth: Date())
        copy(RunLog.url(forMonth: Date()), as: "runs/\(RunLog.url(forMonth: Date()).lastPathComponent)")
        for log in GameLogs.collect(for: runs) {
            write(log.text, as: log.path)
        }

        write(contents.sorted().joined(separator: "\n") + "\n", as: "contents.txt")

        try? manager.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: zip)
        let ditto = await Subprocess.run(
            "/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", staging.path, zip.path],
            capture: .combined, timeout: .seconds(60),
        )
        guard ditto.status == 0, manager.fileExists(atPath: zip.path) else {
            throw ClientOps.Failure.message("could not write \(zip.path): \(ditto.output)")
        }
        return zip
    }

    /// The machine and the software on it, without the account.
    private static func host() async -> [String: Any] {
        var host: [String: Any] = [
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "sevo": Sevo.version,
            "engine": Engine.active.description,
        ]
        for (key, name) in [("hw.model", "model"), ("machdep.cpu.brand_string", "chip"), ("hw.memsize", "memory_bytes")] {
            let result = await Subprocess.run("/usr/sbin/sysctl", ["-n", key], timeout: .seconds(5))
            if result.status == 0 { host[name] = result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        // The CLI rides inside the app bundle as Contents/Helpers/sevo.
        let contents = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
        if let contents, let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
           let version = plist["CFBundleShortVersionString"] as? String {
            host["app"] = version
        }
        return host
    }
}

/// The logs a game writes for itself, gathered for the runs a report covers.
///
/// Every engine invents its own dumping ground and none of them is named for
/// the app id, so a file is claimed by a run when it was last written during
/// that run — the only join that exists between a Unity player's `Player.log`
/// and the launch that produced it. Two games up at once can therefore both
/// claim a file, which costs a duplicate rather than a missing log. Paths are
/// rewritten (``Redaction``) and every file is capped, because a game left
/// running writes without a bound.
nonisolated enum GameLogs {
    struct Collected {
        /// Where it goes inside the report, `games/<appid>/…`.
        let path: String
        let text: String
    }

    /// How much of a log is kept: the end, where the failure is.
    static let maximumBytesPerFile = 2_000_000
    /// The whole section's budget, spent newest run first.
    static let maximumBytesTotal = 20_000_000
    /// A log is still being written when the process dies, so its last write
    /// can land just after the run record closes.
    static let graceAfterRun: TimeInterval = 300

    /// What every run in `records` left behind, newest run first so the
    /// budget is spent on what is being asked about.
    static func collect(for records: [RunRecord]) -> [Collected] {
        var collected: [Collected] = []
        var budget = maximumBytesTotal
        let unityLogs = unityPlayerLogs()
        let renderer = rendererLogs()
        for record in records.reversed() {
            guard let window = window(of: record) else { continue }
            var sources = (unityLogs + unrealLogs(for: record))
                .filter { window.contains($0.written) }
                .map(\.url)
            sources += renderer
            for source in sources {
                guard budget > 0, let file = read(source) else { continue }
                budget -= file.utf8.count
                collected.append(
                    Collected(path: "games/\(record.appid)/\(source.lastPathComponent)", text: file),
                )
            }
        }
        return collected
    }

    /// The stretch of time a run's own files were written in.
    private static func window(of record: RunRecord) -> ClosedRange<Date>? {
        guard let start = runRecordStamp.date(from: record.t) else { return nil }
        let end = start.addingTimeInterval((record.durationSeconds ?? 0) + graceAfterRun)
        return start ... end
    }

    /// Unity writes `Player.log` under the Windows user's `LocalLow`, one
    /// directory per company and product, neither of which names the app id.
    private static func unityPlayerLogs() -> [(url: URL, written: Date)] {
        let users = SteamBottle.root.appendingPathComponent("drive_c/users")
        var found: [(url: URL, written: Date)] = []
        for user in InstallDirectory.entries(in: users) where user.isDirectory {
            let lowRoot = user.url.appendingPathComponent("AppData/LocalLow")
            for company in InstallDirectory.entries(in: lowRoot) where company.isDirectory {
                for product in InstallDirectory.entries(in: company.url) where product.isDirectory {
                    let log = product.url.appendingPathComponent("Player.log")
                    guard let written = modified(log) else { continue }
                    found.append((log, written))
                }
            }
        }
        return found
    }

    /// Unreal keeps its logs and crash reports under `<Project>/Saved/`, which
    /// sits beside the game in a development build and under the Windows
    /// user's `AppData\Local` in a shipping one — where every project has a
    /// directory whether or not it ran.
    private static func unrealLogs(for record: RunRecord) -> [(url: URL, written: Date)] {
        let project = unrealProject(of: record.exe)
        // The user's `AppData\Local` holds a directory for every Unreal game
        // ever run, so a run that cannot name its project would claim all of
        // them that were written while it was up.
        guard project != nil || record.runtime == "unreal" else { return [] }
        var savedDirectories: [URL] = []
        if let install = SharedGames.installed(appID: record.appid) {
            savedDirectories += InstallDirectory.entries(in: install.directory)
                .filter(\.isDirectory)
                .map { $0.url.appendingPathComponent("Saved") }
        }
        let users = SteamBottle.root.appendingPathComponent("drive_c/users")
        for user in InstallDirectory.entries(in: users) where user.isDirectory {
            let local = user.url.appendingPathComponent("AppData/Local")
            savedDirectories += InstallDirectory.entries(in: local)
                .filter { $0.isDirectory && (project == nil || $0.name.lowercased() == project) }
                .map { $0.url.appendingPathComponent("Saved") }
        }
        var found: [(url: URL, written: Date)] = []
        for saved in savedDirectories {
            for directory in ["Logs", "Crashes"] {
                for file in textFiles(under: saved.appendingPathComponent(directory)) {
                    guard let written = modified(file) else { continue }
                    found.append((file, written))
                }
            }
        }
        return found
    }

    /// The project name Unreal writes under, taken off its shipping
    /// executable: `Subnautica2-Win64-Shipping.exe` is `Subnautica2`.
    private static func unrealProject(of exe: String?) -> String? {
        guard let exe = exe?.lowercased() else { return nil }
        for suffix in ["-win64-shipping.exe", "-win32-shipping.exe"]
            where exe.hasSuffix(suffix) {
            return String(exe.dropLast(suffix.count))
        }
        return nil
    }

    /// The renderer's own log, when the bottle's environment names one.
    private static func rendererLogs() -> [URL] {
        let sevo = SteamBottle.root.appendingPathComponent(".sevo")
        var files = [sevo.appendingPathComponent("bottle.env")]
        files += InstallDirectory.entries(in: sevo.appendingPathComponent("apps")).map(\.url)
        var found: [URL] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix(rendererLogKey) {
                let value = String(line.dropFirst(rendererLogKey.count))
                guard let url = SteamBottle.macURL(fromWindowsPath: value)
                    ?? (value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil),
                    modified(url) != nil, !found.contains(url) else { continue }
                found.append(url)
            }
        }
        return found
    }

    private static let rendererLogKey = "DXMT_LOG_PATH="

    /// Extensions whose content is text. A minidump is bytes nobody can read
    /// out of a report, so it is left where it is.
    private static let textExtensions = ["log", "txt", "xml", "json", "ini", "runtime-xml"]

    /// Text files in a directory and one level under it — Unreal's crash
    /// reports are one directory per crash.
    private static func textFiles(under directory: URL) -> [URL] {
        var found: [URL] = []
        for entry in InstallDirectory.entries(in: directory) {
            if entry.isDirectory {
                found += InstallDirectory.entries(in: entry.url)
                    .filter { !$0.isDirectory && isText($0.name) }
                    .map(\.url)
            } else if isText(entry.name) {
                found.append(entry.url)
            }
        }
        return found
    }

    private static func isText(_ name: String) -> Bool {
        textExtensions.contains { name.lowercased().hasSuffix(".\($0)") }
    }

    /// The end of a file, redacted. `nil` when it is not there or is empty.
    private static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let tail = data.suffix(maximumBytesPerFile)
        let elided = tail.count < data.count
            ? "… the first \(data.count - tail.count) bytes are not in this report\n"
            : ""
        return elided + Redaction.apply(to: String(decoding: tail, as: UTF8.self))
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
