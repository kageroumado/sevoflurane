import ArgumentParser
import Foundation

// MARK: - setup

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Headless onboarding: engine, bottle, Steam client.",
        discussion: "Runs the same provisioning state machine as the app's "
            + "first-run assistant, so the two cannot drift. Every stage is "
            + "idempotent — anything already present is kept, and an "
            + "interrupted run continues where it left off.",
    )

    @Option(
        name: .customLong("engine"),
        help: "builtin | crossover. Default: CrossOver when usable, else built-in.",
    ) var engine: String?
    @Option(
        name: .customLong("manifest"),
        help: "Manifest URL override, for installing the built-in engine offline.",
    ) var manifest: String?

    func run() async throws {
        try await provision()
    }

    @MainActor
    private func provision() async throws {
        if let manifest {
            guard let url = URL(string: manifest) else {
                Sevo.printError("not a URL: \(manifest)")
                throw SevoExit.badInvocation
            }
            EngineManifest.overrideURL = url
        }
        let provisioner = Provisioner()
        await provisioner.refreshDetection()
        guard let detection = provisioner.detection else {
            Sevo.printError("detection failed")
            throw SevoExit.failed
        }
        Engine.active = try resolveEngine(from: detection)
        guard provisioner.needsSetup else {
            print("already provisioned — engine \(Engine.active.description), "
                + "Steam in bottle '\(SteamBottle.name)'")
            return
        }
        await provisioner.provisionAndConfigure()
        switch provisioner.activity {
        case .done:
            print("setup complete — engine \(Engine.active.description), "
                + "Steam in bottle '\(SteamBottle.name)'")
        case let .failed(reason):
            Sevo.printError("setup failed: \(reason)")
            throw SevoExit.failed
        default:
            Sevo.printError("setup ended in an unexpected state")
            throw SevoExit.failed
        }
    }

    /// `--engine` is a deliberate override of the detection default, so an
    /// impossible choice is an error rather than a silent fallback.
    private func resolveEngine(from detection: SetupDetection) throws -> Engine {
        switch engine {
        case nil:
            return Engine.resolve(from: detection)
        case "crossover":
            guard detection.usableCrossOver != nil else {
                Sevo.printError("no usable CrossOver on this machine")
                throw SevoExit.notProvisioned
            }
            return .crossover
        case "builtin":
            guard let version = detection.managedEngineVersions.last else {
                Sevo.printError("no built-in engine installed — run: sevo engine install")
                throw SevoExit.notProvisioned
            }
            return .managed(version: version)
        default:
            Sevo.printError("--engine must be builtin or crossover")
            throw SevoExit.badInvocation
        }
    }
}

// MARK: - storage

struct StorageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "storage",
        abstract: "What Sevoflurane and its bottle occupy on disk.",
    )

    @Flag(name: .customLong("games"), help: "List installed games instead of the summary.")
    var listGames = false
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        if listGames {
            let games = StorageInventory.installedGames()
            if asJSON {
                let rows = games.map {
                    #"{"appid":\#($0.id),"name":\#(JSLiteral.string($0.name)),"bytes":\#($0.bytes)}"#
                }
                print("[\(rows.joined(separator: ","))]")
                return
            }
            for game in games {
                print("\(Self.size(game.bytes).padded(to: 10))  \(game.name)")
            }
            return
        }
        var sized: [(StorageInventory.Entry, Int64)] = []
        for entry in StorageInventory.entries() {
            await sized.append((entry, StorageInventory.size(of: entry)))
        }
        if asJSON {
            let rows = sized.map {
                #"{"id":\#(JSLiteral.string($0.0.id)),"bytes":\#($0.1)}"#
            }
            print("[\(rows.joined(separator: ","))]")
            return
        }
        for (entry, bytes) in sized where bytes > 0 {
            print("\(Self.size(bytes).padded(to: 10))  \(entry.name)")
        }
        print("\(Self.size(sized.map(\.1).reduce(0, +)).padded(to: 10))  total")
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
