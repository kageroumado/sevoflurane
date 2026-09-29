import ArgumentParser
import Foundation

/// `sevo hoyo`: installs, updates and checks HoYoverse games from HoYoPlay's
/// own servers, so a game never needs HoYoPlay to be brought current.
///
/// Genshin Impact and Zenless Zone Zero join Quick Launch once installed.
/// Star Rail is downloaded and kept current like the others and is never
/// added: its protection ends it under Wine.
struct HoYoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hoyo",
        abstract: "Install, update and verify HoYoverse games without HoYoPlay.",
        discussion: """
        Games: genshin, starrail, zzz. A folder is a game's install folder, the \
        one its .exe sits in. Downloads resume: running the same install or \
        update again keeps every file already in place.
        """,
        subcommands: [List.self, Status.self, Install.self, Update.self, Verify.self],
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "Each game's current build and the folders Sevoflurane keeps.",
        )
        @Flag(name: .customLong("json"), help: "Machine-readable listing.") var asJSON = false

        func run() async throws {
            let api = HoYoAPI()
            var games: [[String: Any]] = []
            for game in HoYoGame.allCases {
                let branch = try? await api.branch(game)
                games.append([
                    "game": game.slug, "name": game.displayName,
                    "latest": branch?.tag ?? NSNull(), "patches_from": branch?.diffTags ?? [],
                    "quick_launch": game.launches,
                ])
            }
            let folders = HoYoLibrary.installations().map { installation in
                [
                    "game": installation.game.slug, "folder": installation.folder.path,
                    "version": installation.version ?? NSNull(),
                ] as [String: Any]
            }
            if asJSON {
                print(Sevo.json(["games": games, "installations": folders], pretty: true))
                return
            }
            for game in games {
                let latest = game["latest"] as? String ?? "unknown (the servers did not answer)"
                let from = (game["patches_from"] as? [String] ?? []).joined(separator: ", ")
                print("\(game["name"] ?? "")  \(latest)\(from.isEmpty ? "" : "  (patches from \(from))")")
            }
            print(folders.isEmpty ? "\nno installations yet — sevo hoyo install <game> <folder>" : "")
            for folder in folders {
                print("\(folder["game"] ?? "")  \(folder["version"] as? String ?? "no build recorded")  \(folder["folder"] ?? "")")
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status", abstract: "What bringing a folder to the current build takes.",
        )
        @Argument(help: "The game's install folder.") var folder: String
        @Flag(name: .customLong("json"), help: "Machine-readable plan.") var asJSON = false

        func run() async throws {
            let installation = try HoYoCommand.installation(at: folder)
            let plan = try await HoYoCommand.failing { try await SophonDownloader().plan(game: installation.game, folder: installation.folder) }
            let kind = switch plan.kind {
            case .upToDate: "up-to-date"
            case .patch: "patch"
            case .download: "download"
            }
            if asJSON {
                print(Sevo.json([
                    "game": plan.game.slug, "folder": installation.folder.path,
                    "installed": plan.installed ?? NSNull(), "latest": plan.latest, "action": kind,
                    "voices": plan.voices, "download_bytes": plan.downloadSize,
                ], pretty: true))
                return
            }
            let size = ByteCountFormatter.string(fromByteCount: plan.downloadSize, countStyle: .file)
            switch plan.kind {
            case .upToDate:
                print("\(plan.game.displayName) \(plan.latest) — up to date")
            case let .patch(from):
                print("\(plan.game.displayName) \(from) → \(plan.latest): a patch of up to \(size)")
            case .download:
                print("\(plan.game.displayName) \(plan.installed ?? "unknown build") → \(plan.latest): too old for a patch; files that differ are downloaded (up to \(size))")
            }
            if !plan.voices.isEmpty { print("  voice packs: \(plan.voices.map(HoYoVoice.name).joined(separator: ", "))") }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install", abstract: "Download a game's current build into a folder.",
        )
        @Argument(help: "genshin, starrail or zzz.") var game: String
        @Argument(help: "The folder to install into; created if it does not exist.") var folder: String
        @Option(name: .customLong("voice"), help: "A voice pack: en-us, ja-jp, zh-cn, ko-kr; repeatable (default en-us).")
        var voices: [String] = ["en-us"]
        @Flag(name: .customLong("no-quick-launch"), help: "Leave the game out of Quick Launch.")
        var skipQuickLaunch = false

        func run() async throws {
            guard let game = HoYoGame.named(game) else {
                Sevo.printError("no game named \(game) — genshin, starrail or zzz")
                throw SevoExit.badInvocation
            }
            let url = URL(fileURLWithPath: folder).standardizedFileURL
            if let other = HoYoGame.identify(folder: url), other != game {
                Sevo.printError("\(url.path) holds \(other.displayName)")
                throw SevoExit.badInvocation
            }
            let meter = ProgressLine()
            let tag = try await HoYoCommand.failing {
                try await SophonDownloader().install(game: game, into: url, voices: voices, progress: meter.show)
            }
            meter.end()
            HoYoLibrary.remember(url)
            print("installed \(game.displayName) \(tag) in \(url.path)")
            HoYoCommand.offerQuickLaunch(HoYoInstallation(game: game, folder: url), skip: skipQuickLaunch)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update", abstract: "Bring a folder to its game's current build.",
        )
        @Argument(help: "The game's install folder.") var folder: String

        func run() async throws {
            let installation = try HoYoCommand.installation(at: folder)
            let meter = ProgressLine()
            let outcome = try await HoYoCommand.failing { try await SophonDownloader().update(installation, progress: meter.show) }
            meter.end()
            HoYoLibrary.remember(installation.folder)
            switch outcome {
            case let .upToDate(tag):
                print("\(installation.game.displayName) \(tag) is up to date")
            case let .patched(from, to, files, current, whole):
                var detail = ["\(files) files patched"]
                if current > 0 { detail.append("\(current) already current") }
                if whole > 0 { detail.append("\(whole) downloaded whole") }
                print("updated \(installation.game.displayName) \(from) → \(to): \(detail.joined(separator: ", "))")
            case let .downloaded(to):
                print("brought \(installation.game.displayName) to \(to)")
            }
        }
    }

    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify", abstract: "Check a folder's files against its pkg_version lists.",
        )
        @Argument(help: "The game's install folder.") var folder: String
        @Flag(name: .customLong("quick"), help: "Check sizes only, not checksums.") var quick = false
        @Flag(name: .customLong("repair"), help: "Download every file that is missing or damaged.") var repair = false
        @Flag(name: .customLong("json"), help: "Machine-readable result.") var asJSON = false

        func run() async throws {
            let installation = try HoYoCommand.installation(at: folder)
            let meter = asJSON ? nil : ProgressLine()
            let problems = installation.verify(quick: quick) { done, total in
                meter?.show(SophonProgress(phase: .checking, bytesDone: done, bytesTotal: total))
            }
            meter?.end()
            if asJSON {
                print(Sevo.json([
                    "folder": installation.folder.path, "checked": installation.expectedFiles().count,
                    "problems": problems.map { ["path": $0.path, "kind": $0.kind.rawValue] },
                ], pretty: true))
            } else if problems.isEmpty {
                print("every file of \(installation.game.displayName) \(installation.version ?? "") checks out")
            } else {
                for problem in problems.prefix(20) { print("  \(problem.kind.rawValue)  \(problem.path)") }
                if problems.count > 20 { print("  … and \(problems.count - 20) more") }
                print("\(problems.count) files missing or damaged\(repair ? "" : " — sevo hoyo verify --repair downloads them")")
            }
            guard repair, !problems.isEmpty else {
                if !problems.isEmpty { throw SevoExit.failed }
                return
            }
            let repairMeter = ProgressLine()
            try await HoYoCommand.failing {
                try await SophonDownloader().repair(installation, paths: Set(problems.map(\.path)), progress: repairMeter.show)
            }
            repairMeter.end()
            print("repaired \(problems.count) files")
        }
    }

    // MARK: - Shared

    static func installation(at path: String) throws -> HoYoInstallation {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let installation = HoYoInstallation(folder: url) else {
            Sevo.printError("no HoYoverse game in \(url.path) — the folder its .exe sits in")
            throw SevoExit.badInvocation
        }
        return installation
    }

    /// Runs a download step, reporting its failure on stderr.
    static func failing<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ExitCode {
            throw error
        } catch {
            print("")
            Sevo.printError("\(error)")
            throw SevoExit.failed
        }
    }

    static func offerQuickLaunch(_ installation: HoYoInstallation, skip: Bool) {
        guard installation.game.launches else {
            print("  \(installation.game.displayName) does not start under Wine, so it is not added to Quick Launch")
            return
        }
        guard !skip, let id = HoYoLibrary.addToQuickLaunch(installation, bottle: SteamBottle.name) else { return }
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        print("  in Quick Launch as \(id) — sevo program launch \(id)")
    }
}

/// One progress line that rewrites itself on a terminal and prints a line a
/// second otherwise.
private final class ProgressLine: @unchecked Sendable {
    private let lock = NSLock()
    private let terminal = isatty(STDOUT_FILENO) != 0
    private var last = Date.distantPast
    private var drawn = false

    func show(_ progress: SophonProgress) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= (terminal ? 0.2 : 5) else { return }
        last = now
        let line = Self.describe(progress)
        if terminal {
            FileHandle.standardOutput.write(Data("\r\u{1B}[K\(line)".utf8))
            drawn = true
        } else {
            FileHandle.standardOutput.write(Data("\(line)\n".utf8))
        }
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        if drawn { print("") }
        drawn = false
    }

    static func describe(_ progress: SophonProgress) -> String {
        var line = progress.phase.rawValue
        if progress.bytesTotal > 0 {
            let done = ByteCountFormatter.string(fromByteCount: progress.bytesDone, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: progress.bytesTotal, countStyle: .file)
            line += String(format: " %.1f%%  %@ of %@", 100 * (progress.fraction ?? 0), done, total)
        }
        if progress.filesTotal > 0 { line += "  \(progress.filesDone)/\(progress.filesTotal) files" }
        return line
    }
}
