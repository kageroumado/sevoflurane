import Foundation

/// What a game page needs to offer the choice between a game's macOS and
/// Windows builds (``SteamPlayMacOS``): whether the client can install the
/// macOS one, how much each download is, which build is on disk, and which
/// one the compatibility verdicts favor. Served to the page as JSON by the
/// bridge's `GET /__native/<appid>`.
nonisolated struct NativeBuildInfo: Codable, Sendable, Equatable {
    /// The running engine switches Steam Play on, so a mapped game installs
    /// and launches its macOS build.
    let enabled: Bool
    /// Steam sells a macOS build (`common/oslist`).
    let hasMacBuild: Bool
    /// The macOS build runs on this Mac: it is more than 32-bit Intel code.
    let runnable: Bool
    /// What installing each build downloads, in bytes; `nil` when the app
    /// cache lists no size.
    let macDownload: Int64?
    let windowsDownload: Int64?
    /// Both builds are the same depots, so a switch downloads nothing.
    let sameFiles: Bool
    /// The build on disk, read from the depots the manifest lists; `nil`
    /// when the game is not installed or its depots serve both platforms.
    let installed: SteamPlayMacOS.Platform?
    /// The build the verdicts favor: the macOS one unless the Windows build
    /// is rated better.
    let recommended: SteamPlayMacOS.Platform
    /// One short line under each choice.
    let macHint: String
    let windowsHint: String
    /// The tool to map the game to for its macOS build.
    let tool: String

    // MARK: - Depots

    /// One depot of an app, as the client's app cache lists it.
    struct Depot: Equatable, Sendable {
        let id: Int
        /// The platforms the depot serves; empty for every platform.
        let platforms: Set<String>
        /// The compressed download, falling back to the size on disk.
        let download: Int64?
        /// The depot belongs to a DLC, an extra language, or another app, so
        /// installing the game alone leaves it out.
        let isOptional: Bool

        func serves(_ platform: SteamPlayMacOS.Platform) -> Bool {
            platforms.isEmpty || platforms.contains(platform.rawValue)
        }
    }

    /// The depots under an app's `depots` table in the app cache.
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

    /// What installing the game for `platform` downloads: every required
    /// depot that serves it. `nil` when none of them lists a size.
    static func download(for platform: SteamPlayMacOS.Platform, depots: [Depot]) -> Int64? {
        let sizes = depots.filter { !$0.isOptional && $0.serves(platform) }.compactMap(\.download)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    /// Whether every required depot serves both platforms.
    static func sameFiles(_ depots: [Depot]) -> Bool {
        depots.filter { !$0.isOptional }.allSatisfy { $0.serves(.macos) && $0.serves(.windows) }
    }

    /// The build whose depots the manifest lists: macOS when one installed
    /// depot is for macOS only, Windows when one is for Windows only, `nil`
    /// when every installed depot serves both or the manifest lists none.
    static func installedBuild(manifest text: String, depots: [Depot]) -> SteamPlayMacOS.Platform? {
        guard let installed = TextKeyValues.parse(text)?.at(["AppState", "InstalledDepots"]) else { return nil }
        let ids = Set(installed.entries.compactMap { Int($0.key) })
        let platforms = depots.filter { ids.contains($0.id) }.map(\.platforms)
        if platforms.contains(where: { $0.contains("macos") && !$0.contains("windows") }) { return .macos }
        if platforms.contains(where: { $0.contains("windows") && !$0.contains("macos") }) { return .windows }
        return nil
    }

    // MARK: - The verdicts

    /// The build to suggest: the macOS one unless the Windows build is rated
    /// better, since a native build skips the translation layers.
    static func recommendation(native: GameCompatBadge?, windows: GameCompatBadge?) -> SteamPlayMacOS.Platform {
        rank(windows?.state) > rank(native?.state) ? .windows : .macos
    }

    private static func rank(_ state: GameCompatBadge.State?) -> Int {
        switch state {
        case .verified: 3
        case .playable: 2
        case .unknown, nil: 1
        case .unsupported: 0
        }
    }

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

    /// The page's answer for one game, from the app cache, the game's
    /// manifest, and its compatibility record when one is at hand.
    static func make(
        appID _: Int, enabled: Bool, appInfo: [String: SteamAppInfo.Value]?, manifest: String?, record: GameCompatRecord?,
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
            recommended: recommendation(native: record?.nativeBadge, windows: record?.mac),
            macHint: macHint(record?.nativeBadge),
            windowsHint: windowsHint(record?.mac),
            tool: SteamPlayMacOS.toolName,
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
