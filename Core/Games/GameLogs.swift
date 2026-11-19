import Foundation

/// The logs a game writes for itself, gathered for the runs a report covers.
///
/// No log is named for the app id, so the join comes from the install: Unity's
/// `<Game>_Data/app.info` names the company and product, and an Unreal
/// shipping exe names its project. Otherwise write times decide, which two
/// running games can both claim. Paths are redacted and files capped.
nonisolated enum GameLogs {
    struct Collected {
        /// Where it goes inside the report, `games/<appid>/…`.
        let path: String
        let text: String
    }

    /// How much of a log's end is kept.
    static let maximumBytesPerFile = 2_000_000
    /// The whole section's budget, spent newest run first.
    static let maximumBytesTotal = 20_000_000
    /// A last write can land after the run record closes; used by the
    /// write-time joins.
    static let graceAfterRun: TimeInterval = 300

    /// What every run in `records` left behind, newest first for the budget.
    static func collect(for records: [RunRecord]) -> [Collected] {
        var collected: [Collected] = []
        var budget = maximumBytesTotal
        var claimed: Set<URL> = []
        var taken: Set<String> = []
        let renderer = rendererLogs()
        var everyUnityLog: [(url: URL, written: Date)]?
        for record in records.reversed() {
            var sources = unityLogs(for: record) ?? {
                let all = everyUnityLog ?? windowsUserRoots.flatMap(unityPlayerLogs(underUsers:))
                everyUnityLog = all
                guard let window = window(of: record) else { return [] }
                return all.filter { window.contains($0.written) }.map(\.url)
            }()
            sources += unrealLogs(for: record)
            sources += renderer
            for source in sources {
                guard budget > 0, claimed.insert(source).inserted,
                      let file = read(source) else { continue }
                budget -= file.utf8.count
                let path = path(of: source, forApp: record.appid, avoiding: taken)
                taken.insert(path)
                collected.append(Collected(path: path, text: file))
            }
        }
        return collected
    }

    /// Where one file goes under `games/<appid>/`; a repeated name is
    /// qualified by its parent directory.
    static func path(of url: URL, forApp appID: Int, avoiding taken: Set<String>) -> String {
        let root = "games/\(appID)"
        let name = url.lastPathComponent
        let plain = "\(root)/\(name)"
        guard taken.contains(plain) else { return plain }
        let parent = url.deletingLastPathComponent().lastPathComponent
        var qualified = "\(root)/\(parent)/\(name)"
        var index = 1
        while taken.contains(qualified) {
            index += 1
            qualified = "\(root)/\(parent)-\(index)/\(name)"
        }
        return qualified
    }

    /// The stretch of time a run's own files were written in.
    private static func window(of record: RunRecord) -> ClosedRange<Date>? {
        guard let start = runRecordStamp.date(from: record.t) else { return nil }
        let end = start.addingTimeInterval((record.durationSeconds ?? 0) + graceAfterRun)
        return start ... end
    }

    /// The bottle's and the companion prefix's Windows profiles.
    private static var windowsUserRoots: [URL] {
        [SteamBottle.root, SteamBottle.companion].map { $0.appendingPathComponent("drive_c/users") }
    }

    // MARK: - Unity

    /// Current and rotated player logs, under Unity's and HoYoverse's names.
    static let unityLogNames = ["Player.log", "Player-prev.log", "output_log.txt", "output_log.txt.last"]

    /// The names a player's current log goes by.
    private static let currentUnityLogNames = ["Player.log", "output_log.txt"]

    /// A run's Unity logs from its install's identity; `nil` sends the caller
    /// to the write times.
    private static func unityLogs(for record: RunRecord) -> [URL]? {
        let install = SharedGames.installed(appID: record.appid)?.directory
            ?? AdoptedPrograms.program(record.appid)?.url.deletingLastPathComponent()
        guard let install, let identity = unityIdentity(inInstall: install, exe: record.exe)
        else { return nil }
        return windowsUserRoots.flatMap {
            unityLogs(company: identity.company, product: identity.product, underUsers: $0)
        }
    }

    /// A company and product's Unity logs in every profile, whatever their
    /// write times: a second launch rotates the first into `Player-prev.log`.
    static func unityLogs(company: String, product: String, underUsers users: URL) -> [URL] {
        var found: [URL] = []
        for user in InstallDirectory.entries(in: users) where user.isDirectory {
            let lowRoot = user.url.appendingPathComponent("AppData/LocalLow")
            guard let companyDirectory = directory(named: company, in: lowRoot),
                  let productDirectory = directory(named: product, in: companyDirectory)
            else { continue }
            found += unityLogNames
                .map { productDirectory.appendingPathComponent($0) }
                .filter { modified($0) != nil }
        }
        return found
    }

    /// The company and product from `app.info`, preferring the player
    /// directory that matches `exe`.
    static func unityIdentity(
        inInstall directory: URL, exe: String?,
    ) -> (company: String, product: String)? {
        let stem = exe.map { ($0 as NSString).deletingPathExtension.lowercased() }
        let players = InstallDirectory.entries(in: directory)
            .filter { $0.isDirectory && $0.name.hasSuffix(playerDataSuffix) }
            .sorted { first, second in
                playerName(of: first.name) == stem && playerName(of: second.name) != stem
            }
        for player in players {
            let info = player.url.appendingPathComponent("app.info")
            guard let text = try? String(contentsOf: info, encoding: .utf8) else { continue }
            let lines = text.split(whereSeparator: \.isNewline)
            guard lines.count >= 2 else { continue }
            return (String(lines[0]), String(lines[1]))
        }
        return nil
    }

    private static let playerDataSuffix = "_Data"

    /// `HollowKnight_Data` is `hollowknight` — what the executable beside it
    /// is called.
    private static func playerName(of dataDirectory: String) -> String {
        dataDirectory.dropLast(playerDataSuffix.count).lowercased()
    }

    /// Every current Unity log under `LocalLow`, with its write time.
    private static func unityPlayerLogs(underUsers users: URL) -> [(url: URL, written: Date)] {
        var found: [(url: URL, written: Date)] = []
        for user in InstallDirectory.entries(in: users) where user.isDirectory {
            let lowRoot = user.url.appendingPathComponent("AppData/LocalLow")
            for company in InstallDirectory.entries(in: lowRoot) where company.isDirectory {
                for product in InstallDirectory.entries(in: company.url) where product.isDirectory {
                    for name in currentUnityLogNames {
                        let log = product.url.appendingPathComponent(name)
                        guard let written = modified(log) else { continue }
                        found.append((log, written))
                    }
                }
            }
        }
        return found
    }

    /// Case-insensitive: Unity's `app.info` and directory names can differ in
    /// case on the case-sensitive drive.
    private static func directory(named name: String, in parent: URL) -> URL? {
        let wanted = name.lowercased()
        return InstallDirectory.entries(in: parent)
            .first { $0.isDirectory && $0.name.lowercased() == wanted }?.url
    }

    // MARK: - Unreal

    /// Unreal's `<Project>/Saved/` logs, beside the game or under
    /// `AppData\Local`, taken by write time.
    private static func unrealLogs(for record: RunRecord) -> [URL] {
        let project = unrealProject(of: record.exe)
        // An unnamed project would claim every Unreal game written meanwhile.
        guard project != nil || record.runtime == "unreal", let window = window(of: record)
        else { return [] }
        var savedDirectories: [URL] = []
        if let install = SharedGames.installed(appID: record.appid) {
            savedDirectories += InstallDirectory.entries(in: install.directory)
                .filter(\.isDirectory)
                .map { $0.url.appendingPathComponent("Saved") }
        }
        for users in windowsUserRoots {
            for user in InstallDirectory.entries(in: users) where user.isDirectory {
                let local = user.url.appendingPathComponent("AppData/Local")
                savedDirectories += InstallDirectory.entries(in: local)
                    .filter { $0.isDirectory && (project == nil || $0.name.lowercased() == project) }
                    .map { $0.url.appendingPathComponent("Saved") }
            }
        }
        var found: [URL] = []
        for saved in savedDirectories {
            for directory in ["Logs", "Crashes"] {
                for file in textFiles(under: saved.appendingPathComponent(directory)) {
                    guard let written = modified(file), window.contains(written) else { continue }
                    found.append(file)
                }
            }
        }
        return found
    }

    /// `Subnautica2-Win64-Shipping.exe` is `subnautica2`.
    private static func unrealProject(of exe: String?) -> String? {
        guard let exe = exe?.lowercased() else { return nil }
        for suffix in ["-win64-shipping.exe", "-win32-shipping.exe"]
            where exe.hasSuffix(suffix) {
            return String(exe.dropLast(suffix.count))
        }
        return nil
    }

    // MARK: - The renderer

    /// The renderer logs `DXMT_LOG_PATH` names; a directory contributes its
    /// files.
    private static func rendererLogs() -> [URL] {
        let sevo = SteamBottle.root.appendingPathComponent(".sevo")
        var files = [
            sevo.appendingPathComponent("bottle.env"),
            sevo.appendingPathComponent("debug.env"),
        ]
        files += InstallDirectory.entries(in: sevo.appendingPathComponent("apps")).map(\.url)
        var found: [URL] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix(rendererLogKey) {
                let value = String(line.dropFirst(rendererLogKey.count))
                guard let url = SteamBottle.macURL(fromWindowsPath: value)
                    ?? (value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil),
                    modified(url) != nil else { continue }
                let entries = InstallDirectory.entries(in: url)
                // The variable can name any folder, and what is found goes
                // into a shared report: only files named as DXMT names its
                // logs, `<program>_<library>.log`.
                let logs = entries.isEmpty
                    ? [url] : entries.filter { !$0.isDirectory }.map(\.url)
                found += logs.filter { isRendererLog($0.lastPathComponent) && !found.contains($0) }
            }
        }
        return found
    }

    private static let rendererLogKey = "DXMT_LOG_PATH="

    static func isRendererLog(_ name: String) -> Bool {
        name.wholeMatch(of: /.+_[A-Za-z0-9]+\.log/) != nil
    }

    // MARK: - Files

    /// Extensions whose content is text.
    private static let textExtensions = ["log", "txt", "xml", "json", "ini", "runtime-xml"]

    /// Text files in a directory and one level under (one per Unreal crash).
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

    /// The end of a file, redacted; `nil` when missing or empty.
    private static func read(_ url: URL) -> String? {
        guard let (text, elided) = ReportStripper.rawTail(of: url, limit: maximumBytesPerFile) else {
            return nil
        }
        return elided + Redaction.apply(to: text)
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
