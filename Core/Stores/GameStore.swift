import Foundation

/// A game store besides Steam whose Windows library Sevoflurane installs and
/// starts through that store's open-source command-line client.
nonisolated enum GameStore: String, CaseIterable, Codable, Sendable, Identifiable {
    case epic
    case gog

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .epic: "Epic Games"
        case .gog: "GOG"
        }
    }

    /// The client that talks to the store for Sevoflurane.
    var tool: StoreTool {
        switch self {
        case .epic: .legendary
        case .gog: .gogdl
        }
    }

    /// The folder in the Steam bottle new installs go to.
    var defaultInstallBase: URL {
        let driveC = SteamBottle.root.appending(path: "drive_c")
        return switch self {
        case .epic: driveC.appending(path: "Program Files/Epic Games")
        case .gog: driveC.appending(path: "GOG Games")
        }
    }
}

/// The store title an adopted program was installed as.
nonisolated struct StoreLink: Codable, Equatable, Sendable {
    let store: GameStore
    /// The store's own id: Epic's app name, GOG's product id.
    let id: String
}

/// One of the store clients, pinned to a release and its digest.
///
/// Each is a GPLv3 program from the Heroic Games Launcher project, fetched
/// from its GitHub release the first time it is needed and run as a process
/// of its own, so it is never part of Sevoflurane's own binary.
nonisolated enum StoreTool: String, CaseIterable, Sendable {
    case legendary
    case gogdl

    var version: String {
        switch self {
        case .legendary: "0.20.43"
        case .gogdl: "1.3.0"
        }
    }

    var download: URL {
        switch self {
        case .legendary:
            URL(string: "https://github.com/Heroic-Games-Launcher/legendary/releases/download/0.20.43/legendary_macOS_arm64")!
        case .gogdl:
            URL(string: "https://github.com/Heroic-Games-Launcher/heroic-gogdl/releases/download/v1.3.0/gogdl_macos_arm64")!
        }
    }

    var sha256: String {
        switch self {
        case .legendary: "fce325ca0c6c7edd7aaed559ed3f09772689f7f259965ca9ba5fb90f4b5108eb"
        case .gogdl: "a85ae9ef80a3e7840b19a416dd4b3c5db2054508c6147315f1c22faa63a29b38"
        }
    }

    /// Where its source lives, which the interface names beside the license.
    var source: URL {
        switch self {
        case .legendary: URL(string: "https://github.com/Heroic-Games-Launcher/legendary")!
        case .gogdl: URL(string: "https://github.com/Heroic-Games-Launcher/heroic-gogdl")!
        }
    }

    static let license = "GPLv3"

    /// `Application Support/<app>/Stores/<tool>`: the binary under its
    /// version, and the tool's own configuration and sign-in beside it.
    var folder: URL {
        AppIdentity.supportFolder.appending(path: "Stores").appending(path: rawValue)
    }

    var executable: URL {
        folder.appending(path: version).appending(path: rawValue)
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    /// The folder the tool keeps its sign-in, metadata and manifests in.
    var configFolder: URL {
        folder.appending(path: "config")
    }

    /// gogdl's sign-in file, which it is told about on every call.
    var authFile: URL {
        configFolder.appending(path: "auth.json")
    }

    /// The variables that point the tool at ``configFolder``.
    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        switch self {
        case .legendary: environment["LEGENDARY_CONFIG_PATH"] = configFolder.path
        case .gogdl: environment["GOGDL_CONFIG_PATH"] = configFolder.path
        }
        return environment
    }

    /// The arguments every call starts with.
    var leadingArguments: [String] {
        switch self {
        case .legendary: []
        case .gogdl: ["--auth-config-path", authFile.path]
        }
    }

    /// Downloads the pinned release, checks its digest and puts it in place.
    func install(session: URLSession = .shared) async throws {
        let (downloaded, response) = try await session.download(from: download)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StoreFailure("\(rawValue) could not be downloaded: HTTP \(http.statusCode)")
        }
        let actual = try FileDigest.sha256(of: downloaded)
        guard actual == sha256 else {
            throw StoreFailure("\(rawValue) \(version) did not match its pinned digest")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: configFolder, withIntermediateDirectories: true)
        try? manager.removeItem(at: executable)
        try manager.moveItem(at: downloaded, to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        removexattr(executable.path, "com.apple.quarantine", 0)
    }
}

/// Why a store or its client did not do what was asked, in words for the
/// interface and the event log.
nonisolated struct StoreFailure: Error, CustomStringConvertible, Equatable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
