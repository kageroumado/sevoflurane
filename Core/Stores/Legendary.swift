import Foundation

/// The Epic Games Store through legendary: signing in with the code Epic's
/// login page hands over, the account's Windows library, and installing,
/// updating, checking and starting a title.
///
/// legendary keeps the sign-in, the library's metadata and what is installed
/// in its own folder (``StoreTool/configFolder``), which every call points it
/// at; Sevoflurane keeps none of it.
nonisolated enum Legendary {
    /// Epic's login page, which ends on a JSON page holding the
    /// authorization code legendary signs in with.
    static let loginURL = URL(string: "https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode")!

    /// Whether `url` is the JSON page the login ends on.
    static func isRedirectPage(_ url: URL) -> Bool {
        url.host() == "www.epicgames.com" && url.path() == "/id/api/redirect"
    }

    /// The authorization code in the text of the redirect page:
    /// `{"redirectUrl": …, "authorizationCode": "…", "sid": null}`.
    static func authorizationCode(inPage text: String) -> String? {
        struct Page: Decodable { let authorizationCode: String? }
        let code = (try? JSONDecoder().decode(Page.self, from: Data(text.utf8)))?.authorizationCode
        return code?.isEmpty == false ? code : nil
    }

    // MARK: - Commands

    static func signIn(code: String) async throws {
        let result = try await StoreProcess.run(.legendary, ["auth", "--code", code], timeout: .seconds(60))
        guard result.succeeded, try await account(inStatus: status()) != nil else {
            throw StoreFailure(result.failure)
        }
    }

    static func signOut() async throws {
        _ = try await StoreProcess.run(.legendary, ["auth", "--delete"], timeout: .seconds(30))
    }

    /// `status --offline --json`, which reads the sign-in without the network.
    static func status() async throws -> String {
        try await StoreProcess.run(.legendary, ["status", "--offline", "--json"], timeout: .seconds(30)).stdout
    }

    /// The account's Windows titles, fetched fresh from Epic.
    static func library() async throws -> [StoreTitle] {
        let result = try await StoreProcess.run(.legendary, ["list", "--platform", "Windows", "--json"], timeout: .seconds(300))
        guard result.succeeded else { throw StoreFailure(result.failure) }
        return titles(inList: result.stdout)
    }

    static func installed() async throws -> [StoreInstall] {
        let result = try await StoreProcess.run(.legendary, ["list-installed", "--json"], timeout: .seconds(60))
        guard result.succeeded else { throw StoreFailure(result.failure) }
        return installs(inList: result.stdout)
    }

    /// The bytes a title takes on disk, from its current manifest.
    static func installSize(_ id: String) async throws -> Int64? {
        let result = try await StoreProcess.run(.legendary, ["info", id, "--platform", "Windows", "--json"], timeout: .seconds(120))
        guard result.succeeded else { throw StoreFailure(result.failure) }
        return diskSize(inInfo: result.stdout)
    }

    /// Downloads a title into a folder of its own under `base`, named after
    /// its app name rather than the folder Epic's metadata gives, which
    /// legendary would join to `base` as it stands.
    static func install(_ id: String, base: URL, onLine: @escaping @Sendable (String) -> Void) async throws {
        guard let folder = StorePaths.folderName(id, fallback: id) else {
            throw StoreFailure("\(id) cannot name a folder")
        }
        let arguments = [
            "-y", "install", id, "--platform", "Windows", "--base-path", base.path,
            "--game-folder", folder, "--skip-sdl", "--skip-dlcs",
        ]
        let result = try await StoreProcess.run(.legendary, arguments, onLine: onLine)
        guard result.succeeded else { throw StoreFailure(result.failure) }
    }

    static func update(_ id: String, onLine: @escaping @Sendable (String) -> Void) async throws {
        let result = try await StoreProcess.run(.legendary, ["-y", "update", id, "--update-only", "--skip-sdl"], onLine: onLine)
        guard result.succeeded else { throw StoreFailure(result.failure) }
    }

    /// Checks every file and downloads the ones that are missing or damaged.
    static func repair(_ id: String, onLine: @escaping @Sendable (String) -> Void) async throws {
        let result = try await StoreProcess.run(.legendary, ["-y", "repair", id], onLine: onLine)
        guard result.succeeded else { throw StoreFailure(result.failure) }
    }

    /// Forgets an installed title; its files are left for the caller.
    static func forget(_ id: String) async throws {
        let result = try await StoreProcess.run(
            .legendary, ["-y", "uninstall", id, "--keep-files", "--skip-uninstaller"], timeout: .seconds(60),
        )
        guard result.succeeded else { throw StoreFailure(result.failure) }
    }

    /// What starts a title, with a sign-in code good for this one launch.
    /// Signed out or offline, or asked for `offline`, it is legendary's
    /// offline arguments, which hold no code.
    ///
    /// Wine is left out (`--no-wine`): the game is started by Sevoflurane's
    /// own engine, and legendary would otherwise look for CrossOver.
    static func launchPlan(_ id: String, offline: Bool = false) async throws -> StoreLaunchPlan {
        let base = ["launch", id, "--json", "--no-wine", "--skip-version-check"]
        var result = try await StoreProcess.run(.legendary, base + (offline ? ["--offline"] : []), timeout: .seconds(45))
        if !result.succeeded, !offline {
            result = try await StoreProcess.run(.legendary, base + ["--offline"], timeout: .seconds(30))
        }
        guard result.succeeded, let plan = launchPlan(inJSON: result.stdout) else {
            throw StoreFailure(result.failure)
        }
        return plan
    }

    // MARK: - Parsing

    /// The account name `status --json` reports, nil when signed out.
    static func account(inStatus text: String) -> String? {
        struct Status: Decodable { let account: String? }
        guard let account = (try? JSONDecoder().decode(Status.self, from: Data(text.utf8)))?.account,
              !account.isEmpty, account != "<not logged in>" else { return nil }
        return account
    }

    private struct ListedGame: Decodable {
        struct Asset: Decodable {
            let buildVersion: String?
            enum CodingKeys: String, CodingKey { case buildVersion = "build_version" }
        }

        struct Metadata: Decodable {
            struct Image: Decodable {
                let type: String
                let url: String
            }

            struct Attribute: Decodable { let value: String? }
            struct Category: Decodable { let path: String }

            let keyImages: [Image]?
            let customAttributes: [String: Attribute]?
            let categories: [Category]?
        }

        let appName: String
        let appTitle: String
        let assetInfos: [String: Asset]?
        let metadata: Metadata?

        enum CodingKeys: String, CodingKey {
            case appName = "app_name"
            case appTitle = "app_title"
            case assetInfos = "asset_infos"
            case metadata
        }
    }

    /// The installable Windows titles in `list --json`. A title another
    /// launcher manages (Ubisoft, EA) installs nothing through legendary and
    /// is left out; DLC is nested under its game and never listed.
    static func titles(inList text: String) -> [StoreTitle] {
        guard let games = try? JSONDecoder().decode([ListedGame].self, from: Data(text.utf8)) else { return [] }
        return games.compactMap { game in
            guard let windows = game.assetInfos?["Windows"],
                  game.metadata?.customAttributes?["ThirdPartyManagedApp"]?.value == nil else { return nil }
            return StoreTitle(
                store: .epic, id: game.appName, title: game.appTitle,
                art: art(in: game.metadata?.keyImages ?? []), version: windows.buildVersion,
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The landscape box art, else whatever wide image the title has.
    private static func art(in images: [ListedGame.Metadata.Image]) -> URL? {
        for type in ["DieselGameBox", "OfferImageWide", "Thumbnail", "DieselGameBoxTall"] {
            if let image = images.first(where: { $0.type == type }), let url = URL(string: image.url) {
                return url
            }
        }
        return nil
    }

    private struct InstalledGame: Decodable {
        let appName: String
        let title: String
        let version: String
        let installPath: String
        let installSize: Int64?
        let isDLC: Bool?
        let platform: String?

        enum CodingKeys: String, CodingKey {
            case appName = "app_name"
            case title
            case version
            case installPath = "install_path"
            case installSize = "install_size"
            case isDLC = "is_dlc"
            case platform
        }
    }

    /// The installed Windows games in `list-installed --json`.
    static func installs(inList text: String) -> [StoreInstall] {
        guard let games = try? JSONDecoder().decode([InstalledGame].self, from: Data(text.utf8)) else { return [] }
        return games.compactMap { game in
            guard game.isDLC != true, (game.platform ?? "Windows").hasPrefix("Win") else { return nil }
            return StoreInstall(
                store: .epic, id: game.appName, title: game.title, path: game.installPath,
                version: game.version, size: game.installSize,
            )
        }
    }

    /// The manifest's disk size in `info --json`.
    static func diskSize(inInfo text: String) -> Int64? {
        struct Info: Decodable {
            struct Manifest: Decodable {
                let diskSize: Int64?
                enum CodingKeys: String, CodingKey { case diskSize = "disk_size" }
            }

            let manifest: Manifest?
        }
        return (try? JSONDecoder().decode(Info.self, from: Data(text.utf8)))?.manifest?.diskSize
    }

    /// `launch --json`: the executable under the game's folder, the folder
    /// it starts in, and the game's own arguments followed by the user's and
    /// Epic's. Epic's ownership token is a file legendary wrote, named by a
    /// macOS path the game reads through the bottle's `Z:` drive.
    static func launchPlan(inJSON text: String) -> StoreLaunchPlan? {
        struct Parameters: Decodable {
            let gameExecutable: String
            let gameDirectory: String
            let workingDirectory: String?
            let gameParameters: [String]?
            let userParameters: [String]?
            let eglParameters: [String]?

            enum CodingKeys: String, CodingKey {
                case gameExecutable = "game_executable"
                case gameDirectory = "game_directory"
                case workingDirectory = "working_directory"
                case gameParameters = "game_parameters"
                case userParameters = "user_parameters"
                case eglParameters = "egl_parameters"
            }
        }
        guard let parameters = try? JSONDecoder().decode(Parameters.self, from: Data(text.utf8)),
              !parameters.gameExecutable.isEmpty else { return nil }
        let executable = URL(fileURLWithPath: parameters.gameDirectory)
            .appending(path: parameters.gameExecutable).standardizedFileURL.path
        let directory = parameters.workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let own = (parameters.gameParameters ?? []) + (parameters.userParameters ?? [])
        let epic = (parameters.eglParameters ?? []).map { argument in
            let key = "-epicovt="
            guard argument.hasPrefix(key) else { return argument }
            return key + SteamBottle.windowsPath(for: URL(fileURLWithPath: String(argument.dropFirst(key.count))))
        }
        return StoreLaunchPlan(
            folder: URL(fileURLWithPath: parameters.gameDirectory).standardizedFileURL.path,
            executable: executable, workingDirectory: directory,
            arguments: own.map(unquoted) + epic,
        )
    }

    /// legendary splits Epic's argument strings keeping their quotes; each
    /// token reaches the game as one argument already.
    private static func unquoted(_ token: String) -> String {
        guard token.count >= 2, token.hasPrefix("\""), token.hasSuffix("\"") else { return token }
        return String(token.dropFirst().dropLast())
    }
}
