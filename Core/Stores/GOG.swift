import Foundation

/// GOG through gogdl: signing in with the code GOG's login page hands over,
/// the account's Windows library from GOG's own web API, and installing,
/// updating, checking and starting a title.
///
/// gogdl keeps the sign-in (``StoreTool/authFile``) and each install's
/// manifest; what is installed where is recorded beside them in
/// `installed.json`, because gogdl keeps no list of its own.
nonisolated enum GOG {
    static let clientID = "46899977096215655"

    /// GOG Galaxy's login page, which ends on `embed.gog.com/on_login_success`
    /// with the code in its query.
    static let loginURL = URL(string: "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=client2")!

    /// The code in the page the login ends on, or nil for any other page.
    static func authorizationCode(in url: URL) -> String? {
        guard url.host() == "embed.gog.com", url.path() == "/on_login_success",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return code
    }

    /// The language a title is installed in.
    static let language = "en-US"

    // MARK: - Sign-in

    /// The tokens `auth` prints: refreshed when they have expired, `null`
    /// when signed out.
    struct Credentials: Decodable, Equatable {
        let accessToken: String
        let userID: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case userID = "user_id"
        }
    }

    static func credentials(inAuth text: String) -> Credentials? {
        try? JSONDecoder().decode(Credentials.self, from: Data(text.utf8))
    }

    static func signIn(code: String) async throws {
        let result = try await StoreProcess.run(.gogdl, ["auth", "--code", code], timeout: .seconds(60))
        guard result.succeeded, credentials(inAuth: result.stdout) != nil else {
            throw StoreFailure(result.failure)
        }
    }

    /// The current tokens, refreshed by gogdl when they have expired; nil
    /// when signed out.
    static func credentials() async throws -> Credentials? {
        guard FileManager.default.fileExists(atPath: StoreTool.gogdl.authFile.path) else { return nil }
        let result = try await StoreProcess.run(.gogdl, ["auth"], timeout: .seconds(30))
        return credentials(inAuth: result.stdout)
    }

    static func signOut() throws {
        try? FileManager.default.removeItem(at: StoreTool.gogdl.authFile)
    }

    // MARK: - Library

    /// The account's name on GOG.
    static func account(_ credentials: Credentials, session: URLSession = .shared) async throws -> String? {
        struct User: Decodable { let username: String? }
        let data = try await get(URL(string: "https://embed.gog.com/userData.json")!, credentials, session)
        return try JSONDecoder().decode(User.self, from: data).username
    }

    /// Every Windows game the account owns, a page of GOG's library at a time.
    static func library(_ credentials: Credentials, session: URLSession = .shared) async throws -> [StoreTitle] {
        var titles: [StoreTitle] = []
        var page = 1
        var pages = 1
        repeat {
            let url = URL(string: "https://embed.gog.com/account/getFilteredProducts?mediaType=1&sortBy=title&page=\(page)")!
            let data = try await get(url, credentials, session)
            guard let parsed = libraryPage(data) else { throw StoreFailure("GOG's library could not be read") }
            titles += parsed.titles
            pages = parsed.pages
            page += 1
        } while page <= pages
        return titles.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func get(_ url: URL, _ credentials: Credentials, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StoreFailure("GOG answered HTTP \(http.statusCode)")
        }
        return data
    }

    /// One page of `getFilteredProducts`: its games that run on Windows and
    /// how many pages there are.
    static func libraryPage(_ data: Data) -> (titles: [StoreTitle], pages: Int)? {
        struct Page: Decodable {
            struct Product: Decodable {
                struct WorksOn: Decodable {
                    let windows: Bool?
                    enum CodingKeys: String, CodingKey { case windows = "Windows" }
                }

                let id: Int
                let title: String
                let image: String?
                let worksOn: WorksOn?
                let isGame: Bool?
            }

            let totalPages: Int?
            let products: [Product]
        }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { return nil }
        let titles = page.products.compactMap { product -> StoreTitle? in
            guard product.isGame != false, product.worksOn?.windows == true else { return nil }
            return StoreTitle(store: .gog, id: String(product.id), title: product.title, art: art(product.image))
        }
        return (titles, max(page.totalPages ?? 1, 1))
    }

    /// GOG names its tiles by a protocol-relative stem; `_196.jpg` is the
    /// 196-point landscape tile.
    static func art(_ stem: String?) -> URL? {
        guard let stem, !stem.isEmpty else { return nil }
        return URL(string: (stem.hasPrefix("//") ? "https:" + stem : stem) + "_196.jpg")
    }

    // MARK: - Builds

    /// What `info` says of a title's current Windows build.
    struct Build: Equatable, Sendable {
        let id: String
        let name: String?
        /// The folder name GOG gives the install.
        let folder: String?
        /// Bytes on disk: the files every language shares plus
        /// ``language``'s.
        let size: Int64?
    }

    static func build(_ id: String) async throws -> Build {
        let result = try await StoreProcess.run(
            .gogdl, ["info", id, "--platform", "windows", "--lang", language], timeout: .seconds(120),
        )
        guard result.succeeded, let build = build(inInfo: result.stdout) else { throw StoreFailure(result.failure) }
        return build
    }

    static func build(inInfo text: String) -> Build? {
        struct Info: Decodable {
            struct Size: Decodable {
                let diskSize: Int64?
                enum CodingKeys: String, CodingKey { case diskSize = "disk_size" }
            }

            let size: [String: Size]?
            let buildId: String?
            let versionName: String?
            let folderName: String?

            enum CodingKeys: String, CodingKey {
                case size
                case buildId
                case versionName
                case folderName = "folder_name"
            }
        }
        guard let info = try? JSONDecoder().decode(Info.self, from: Data(text.utf8)), let id = info.buildId else {
            return nil
        }
        let sizes = [info.size?["*"]?.diskSize, info.size?[language]?.diskSize].compactMap(\.self)
        return Build(
            id: id, name: info.versionName, folder: info.folderName,
            size: sizes.isEmpty ? nil : sizes.reduce(0, +),
        )
    }

    // MARK: - Installing

    /// Downloads a title into a folder of its own under `base`, or brings
    /// the one there current; `update` and `repair` are the same command.
    static func download(
        _ id: String, verb: String = "download", base: URL, onLine: @escaping @Sendable (String) -> Void,
    ) async throws {
        let arguments = [verb, id, "--platform", "windows", "--path", base.path, "--lang", language, "--skip-dlcs"]
        let result = try await StoreProcess.run(.gogdl, arguments, onLine: onLine)
        guard result.succeeded else { throw StoreFailure(result.failure) }
    }

    /// The installed titles Sevoflurane recorded, whose folders are still
    /// there.
    static func installed() -> [StoreInstall] {
        guard let data = try? Data(contentsOf: installedFile),
              let installs = try? JSONDecoder().decode([StoreInstall].self, from: data) else { return [] }
        return installs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func record(_ install: StoreInstall) throws {
        try save(installed().filter { $0.id != install.id } + [install])
    }

    /// Forgets an installed title and gogdl's manifest of it; its files are
    /// left for the caller.
    static func forget(_ id: String) throws {
        try save(installed().filter { $0.id != id })
        try? FileManager.default.removeItem(at: StoreTool.gogdl.configFolder.appending(path: "heroic_gogdl/manifests/\(id)"))
    }

    private static var installedFile: URL {
        StoreTool.gogdl.folder.appending(path: "installed.json")
    }

    private static func save(_ installs: [StoreInstall]) throws {
        try FileManager.default.createDirectory(at: StoreTool.gogdl.folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(installs).write(to: installedFile, options: .atomic)
    }

    // MARK: - Starting

    /// What starts an installed title, from the `goggame-<id>.info` its
    /// build puts in the game's folder: the primary play task's executable,
    /// working folder and arguments. GOG's games need no sign-in to start.
    static func launchPlan(_ id: String, folder: URL) -> StoreLaunchPlan? {
        let info = folder.appending(path: "goggame-\(id).info")
        guard let text = try? String(contentsOf: info, encoding: .utf8) else { return nil }
        return launchPlan(inInfo: text, folder: folder)
    }

    static func launchPlan(inInfo text: String, folder: URL) -> StoreLaunchPlan? {
        struct Info: Decodable {
            struct Task: Decodable {
                let isPrimary: Bool?
                let path: String?
                let workingDir: String?
                let arguments: String?
                let category: String?
            }

            let playTasks: [Task]?
        }
        guard let tasks = try? JSONDecoder().decode(Info.self, from: Data(text.utf8)).playTasks,
              let task = tasks.first(where: { $0.isPrimary == true && $0.path != nil })
              ?? tasks.first(where: { $0.category == "game" && $0.path != nil }),
              let path = task.path else { return nil }
        let executable = folder.appending(path: macPath(path)).standardizedFileURL.path
        let directory = task.workingDir.flatMap { $0.isEmpty ? nil : $0 }
            .map { folder.appending(path: macPath($0)).standardizedFileURL.path }
            ?? URL(fileURLWithPath: executable).deletingLastPathComponent().path
        return StoreLaunchPlan(
            executable: executable, workingDirectory: directory,
            arguments: StoreOutput.splitArguments(task.arguments ?? ""),
        )
    }

    private static func macPath(_ windows: String) -> String {
        windows.replacingOccurrences(of: #"\"#, with: "/")
    }
}
