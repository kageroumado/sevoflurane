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
/// machine, the active engine's `engine-info.json`, the bottle's env files,
/// the game launcher bundles, Steam's own logs, and the last two days of
/// crash reports from the engine's processes. Nothing in it names the
/// account; crash reports and env files carry paths under the home
/// directory, so the user's short name is in them.
nonisolated enum Diagnostics {
    static let crashReportPrefixes = ["wine", "wine64", "nwjs", "Sevoflurane", "steam", "sevo-"]
    /// `console_log.txt` carries the whole `GameAction` trail and the exit
    /// code of a game the client started, which is the answer to most of what
    /// a launch failure is asked about.
    static let steamLogNames = [
        "bootstrap_log.txt", "connection_log.txt", "webhelper.txt", "gameprocess_log.txt",
        "console_log.txt",
    ]

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

        let logs = manager.homeDirectoryForCurrentUser.appending(path: "Library/Logs")
        for file in [
            "Sevoflurane.log", "Sevoflurane.old.log", "Sevoflurane-wine.log", "Sevoflurane-wine.old.log",
            "Sevoflurane-windows.log",
        ] {
            copy(logs.appendingPathComponent(file), as: "logs/\(file)")
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
        let recent = Date().addingTimeInterval(-48 * 3600)
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
