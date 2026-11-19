import Foundation

/// What a game page needs to offer the choice between a game's macOS and
/// Windows builds (``SteamPlayMacOS``), served as JSON by the bridge's
/// `GET /__native/<appid>`.
nonisolated struct NativeBuildInfo: Codable, Sendable, Equatable {
    /// The running engine switches Steam Play on, so a mapped game installs
    /// and launches its macOS build.
    let enabled: Bool
    /// Steam sells a macOS build (`common/oslist`).
    let hasMacBuild: Bool
    /// The macOS build is more than 32-bit Intel code.
    let runnable: Bool
    /// Download sizes in bytes; `nil` when the app cache lists no size.
    let macDownload: Int64?
    let windowsDownload: Int64?
    /// Both builds are the same depots, so a switch downloads nothing.
    let sameFiles: Bool
    /// The build on disk; `nil` when the game is not installed or its depots
    /// serve both platforms.
    let installed: SteamPlayMacOS.Platform?
    let macHint: String
    let windowsHint: String
    /// The tool to map the game to for its macOS build.
    let tool: String
    /// Steam for Mac's copy, which installing the macOS build clones in place
    /// of a download (``SteamForMacCopy``); `nil` when the game is installed
    /// here or there is no cloneable complete copy.
    var steamForMacCopy: CopyOffer? = nil

    struct CopyOffer: Codable, Sendable, Equatable {
        /// What the copy occupies on disk, which the clone shares.
        let bytes: Int64
    }

    // MARK: - Depots

    /// One depot of an app, as the client's app cache lists it.
    struct Depot: Equatable, Sendable {
        let id: Int
        /// Empty for every platform.
        let platforms: Set<String>
        /// The compressed download, falling back to the size on disk.
        let download: Int64?
        /// A DLC, extra-language or other app's depot, which installing the
        /// game alone leaves out.
        let isOptional: Bool

        func serves(_ platform: SteamPlayMacOS.Platform) -> Bool {
            platforms.isEmpty || platforms.contains(platform.rawValue)
        }
    }

    static func depots(inAppInfo app: [String: SteamAppInfo.Value]) -> [Depot] {
        guard case let .table(depots)? = app["depots"] else { return [] }
        return depots.compactMap { key, value -> Depot? in
            guard let id = Int(key), case let .table(depot) = value else { return nil }
            var platforms: Set<String> = []
            var language = ""
            if case let .table(config)? = depot["config"] {
                if case let .string(list)? = config["oslist"] {
                    platforms = Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                }
                if case let .string(value)? = config["language"] { language = value.lowercased() }
            }
            var download: Int64?
            if case let .table(manifests)? = depot["manifests"], case let .table(published)? = manifests["public"] {
                download = number(published["download"]) ?? number(published["size"])
            }
            let foreign = depot["dlcappid"] != nil || depot["depotfromapp"] != nil || depot["sharedinstall"] != nil
            let extraLanguage = !language.isEmpty && language != "english"
            return Depot(id: id, platforms: platforms, download: download, isOptional: foreign || extraLanguage)
        }
        .sorted { $0.id < $1.id }
    }

    private static func number(_ value: SteamAppInfo.Value?) -> Int64? {
        switch value {
        case let .number(number): number
        case let .string(text): Int64(text)
        default: nil
        }
    }

    /// The summed download of every required depot serving `platform`;
    /// `nil` when none of them lists a size.
    static func download(for platform: SteamPlayMacOS.Platform, depots: [Depot]) -> Int64? {
        let sizes = depots.filter { !$0.isOptional && $0.serves(platform) }.compactMap(\.download)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    static func sameFiles(_ depots: [Depot]) -> Bool {
        depots.filter { !$0.isOptional }.allSatisfy { $0.serves(.macos) && $0.serves(.windows) }
    }

    /// The installed build: macOS if an installed depot serves macOS only,
    /// else Windows if one serves Windows only, else `nil`.
    static func installedBuild(manifest text: String, depots: [Depot]) -> SteamPlayMacOS.Platform? {
        guard let installed = TextKeyValues.parse(text)?.at(["AppState", "InstalledDepots"]) else { return nil }
        let ids = Set(installed.entries.compactMap { Int($0.key) })
        let platforms = depots.filter { ids.contains($0.id) }.map(\.platforms)
        if platforms.contains(where: { $0.contains("macos") && !$0.contains("windows") }) { return .macos }
        if platforms.contains(where: { $0.contains("windows") && !$0.contains("macos") }) { return .windows }
        return nil
    }

    // MARK: - The verdicts

    /// The line under the macOS choice.
    static func macHint(_ native: GameCompatBadge?) -> String {
        guard let native, native.state != .unknown else { return "Built for macOS" }
        return "Built for macOS · \(native.label)"
    }

    /// The line under the Windows choice.
    static func windowsHint(_ windows: GameCompatBadge?) -> String {
        guard let windows, windows.state != .unknown else { return "Runs through Sevoflurane" }
        return "Runs through Sevoflurane · \(windows.label)"
    }

    // MARK: - Assembly

    /// The page's answer for one game.
    static func make(
        appID _: Int, enabled: Bool, appInfo: [String: SteamAppInfo.Value]?, manifest: String?, record: GameCompatRecord?,
        steamForMacCopy: SteamForMacCopy.Copy? = nil,
    ) -> NativeBuildInfo {
        var platforms: Set<String> = []
        if case let .table(common)? = appInfo?["common"], case let .string(list)? = common["oslist"] {
            platforms = Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        }
        let depots = appInfo.map(depots(inAppInfo:)) ?? []
        return NativeBuildInfo(
            enabled: enabled,
            hasMacBuild: platforms.contains("macos"),
            runnable: record?.macArchitectures?.is32BitOnly != true,
            macDownload: download(for: .macos, depots: depots),
            windowsDownload: download(for: .windows, depots: depots),
            sameFiles: !depots.isEmpty && sameFiles(depots),
            installed: manifest.flatMap { installedBuild(manifest: $0, depots: depots) },
            macHint: macHint(record?.nativeBadge),
            windowsHint: windowsHint(record?.mac),
            tool: SteamPlayMacOS.toolName,
            steamForMacCopy: manifest == nil && enabled ? steamForMacCopy.map { CopyOffer(bytes: $0.bytes) } : nil,
        )
    }

    /// The game's manifest text from whichever library holds it.
    static func manifest(appID: Int, steamRoot: URL = SteamBottle.steamRoot) -> String? {
        for steamapps in SteamLibraries.steamapps(steamRoot: steamRoot) {
            let url = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return nil
    }
}
