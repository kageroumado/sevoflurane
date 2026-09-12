import Foundation

/// The logs a game writes for itself, gathered for the runs a report covers.
///
/// Every engine invents its own dumping ground and none of them is named for
/// the app id, so the join is made from the game's own install: a Unity
/// player carries `<Game>_Data/app.info`, whose first line is the company and
/// whose second is the product it logs under, and an Unreal game's shipping
/// executable names the project its `Saved/` directory sits in. A run whose
/// install says neither falls back to the write times — a file last written
/// while the run was up — which two games up at once can both claim.
///
/// Paths are rewritten (``Redaction``) and every file is capped, because a
/// game left running writes without a bound.
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
    /// can land just after the run record closes. Only the fallback join and
    /// Unreal's shared `Saved/` directories spend this.
    static let graceAfterRun: TimeInterval = 300

    /// What every run in `records` left behind, newest run first so the
    /// budget is spent on what is being asked about.
    static func collect(for records: [RunRecord]) -> [Collected] {
        var collected: [Collected] = []
        var budget = maximumBytesTotal
        var claimed: Set<URL> = []
        var taken: Set<String> = []
        let renderer = rendererLogs()
        var everyUnityLog: [(url: URL, written: Date)]?
        for record in records.reversed() {
            var sources = unityLogs(for: record) ?? {
                let all = everyUnityLog ?? unityPlayerLogs(underUsers: windowsUsers)
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

    /// Where one file goes under `games/<appid>/`.
    ///
    /// Two files of one app id can share a name — an Unreal crash directory
    /// per crash, two Unity products claimed by the same fallback — and the
    /// report is a flat directory per app id, so a repeat is qualified by the
    /// directory it came out of rather than overwriting what is already there.
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

    /// The bottle's Windows profiles, one directory per user.
    private static var windowsUsers: URL {
        SteamBottle.root.appendingPathComponent("drive_c/users")
    }

    // MARK: - Unity

    /// The file the Unity player writes now, and the one it rotated the
    /// previous launch's output into.
    static let unityLogNames = ["Player.log", "Player-prev.log"]

    /// Where a run's Unity player writes, from the identity in its install.
    /// `nil` when the install names no company and product, which is the
    /// caller's cue to fall back to the write times.
    private static func unityLogs(for record: RunRecord) -> [URL]? {
        guard let install = SharedGames.installed(appID: record.appid),
              let identity = unityIdentity(inInstall: install.directory, exe: record.exe)
        else { return nil }
        return unityLogs(
            company: identity.company, product: identity.product, underUsers: windowsUsers,
        )
    }

    /// The Unity logs a company and product wrote, in every Windows profile
    /// the bottle has.
    ///
    /// Both files are taken whether or not either was written during the run:
    /// a second launch of the same game rotates the first launch's output
    /// into `Player-prev.log`, so that is where the earlier run's log is.
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

    /// The company and product a Unity game logs under, from the `app.info`
    /// its player data directory carries: the first line is the company, the
    /// second the product. The directory matching the run's executable is
    /// read first, since a game can ship more than one player.
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

    /// Unity writes `Player.log` under the Windows user's `LocalLow`, one
    /// directory per company and product, neither of which names the app id.
    private static func unityPlayerLogs(underUsers users: URL) -> [(url: URL, written: Date)] {
        var found: [(url: URL, written: Date)] = []
        for user in InstallDirectory.entries(in: users) where user.isDirectory {
            let lowRoot = user.url.appendingPathComponent("AppData/LocalLow")
            for company in InstallDirectory.entries(in: lowRoot) where company.isDirectory {
                for product in InstallDirectory.entries(in: company.url) where product.isDirectory {
                    let log = product.url.appendingPathComponent(unityLogNames[0])
                    guard let written = modified(log) else { continue }
                    found.append((log, written))
                }
            }
        }
        return found
    }

    /// The entry a name refers to, matched case-insensitively: the bottle's
    /// drive is case sensitive, and Unity writes the name into `app.info` and
    /// creates the directory from separate code paths.
    private static func directory(named name: String, in parent: URL) -> URL? {
        let wanted = name.lowercased()
        return InstallDirectory.entries(in: parent)
            .first { $0.isDirectory && $0.name.lowercased() == wanted }?.url
    }

    // MARK: - Unreal

    /// Unreal keeps its logs and crash reports under `<Project>/Saved/`, which
    /// sits beside the game in a development build and under the Windows
    /// user's `AppData\Local` in a shipping one — where every project has a
    /// directory whether or not it ran, so those are taken by write time.
    private static func unrealLogs(for record: RunRecord) -> [URL] {
        let project = unrealProject(of: record.exe)
        // The user's `AppData\Local` holds a directory for every Unreal game
        // ever run, so a run that cannot name its project would claim all of
        // them that were written while it was up.
        guard project != nil || record.runtime == "unreal", let window = window(of: record)
        else { return [] }
        var savedDirectories: [URL] = []
        if let install = SharedGames.installed(appID: record.appid) {
            savedDirectories += InstallDirectory.entries(in: install.directory)
                .filter(\.isDirectory)
                .map { $0.url.appendingPathComponent("Saved") }
        }
        for user in InstallDirectory.entries(in: windowsUsers) where user.isDirectory {
            let local = user.url.appendingPathComponent("AppData/Local")
            savedDirectories += InstallDirectory.entries(in: local)
                .filter { $0.isDirectory && (project == nil || $0.name.lowercased() == project) }
                .map { $0.url.appendingPathComponent("Saved") }
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

    // MARK: - The renderer

    /// The renderer's own logs, when the bottle's environment names where
    /// they go. DXMT takes a directory and writes one file per executable in
    /// it, so a directory contributes its files rather than itself.
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
                let logs = entries.isEmpty
                    ? [url] : entries.filter { !$0.isDirectory && isText($0.name) }.map(\.url)
                found += logs.filter { !found.contains($0) }
            }
        }
        return found
    }

    private static let rendererLogKey = "DXMT_LOG_PATH="

    // MARK: - Files

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
