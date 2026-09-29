import ArgumentParser
import Foundation

/// `sevo` — one management surface, three consumers: us (testing and
/// debugging), terminal-comfortable end users, and AI agents (via `sevo mcp`
/// or by just running the CLI).
@main
struct SevoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sevo",
        abstract: "Manage Sevoflurane: its Steam client, games and added Windows programs, engines, and diagnostics.",
        version: Sevo.version,
        subcommands: [
            DoctorCommand.self, StatusCommand.self, WaitCommand.self, SetupCommand.self,
            EngineCommand.self, UpdateCommand.self, ShadersCommand.self, BottleCommand.self,
            StorageCommand.self,
            ClientCommand.self, RecoverCommand.self, DaemonCommand.self,
            AppCommand.self, ProgramCommand.self, NWJSCommand.self, DownloadsCommand.self,
            EvalCommand.self, BenchmarkCommand.self, CDPCommand.self, LogsCommand.self,
            RunsCommand.self, PerfCommand.self, StatsCommand.self, ReportCommand.self, OrphansCommand.self, HoldsCommand.self,
            DiagCommand.self, DebugCommand.self, StreamerCommand.self, SyncCommand.self,
            RunCommand.self,
            MCPCommand.self, InstallCLICommand.self, VersionCommand.self,
        ],
    )
}

/// Maps operation failures onto the exit contract with the message on stderr.
nonisolated func handlingFailures(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let failure as ClientOps.Failure {
        switch failure {
        case let .message(message):
            Sevo.printError(message)
            throw SevoExit.failed
        case let .unprovisioned(message):
            Sevo.printError(message)
            throw SevoExit.notProvisioned
        }
    } catch let failure as CDPClient.Failure {
        switch failure {
        case let .unreachable(detail):
            Sevo.printError("client unreachable: \(detail) — try: sevo client start")
            throw SevoExit.unreachable
        case let .unanswered(detail):
            Sevo.printError("client too busy to answer: \(detail) — try again shortly")
            throw SevoExit.unreachable
        case .closed, .badReply, .protocolError, .scriptThrew:
            Sevo.printError("client eval failed: \(failure)")
            throw SevoExit.failed
        }
    }
}

// MARK: - housekeeping

struct InstallCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-cli",
        abstract: "Symlink sevo into /usr/local/bin.",
    )

    func run() async throws {
        let target = URL(fileURLWithPath: "/usr/local/bin/\(AppIdentity.commandName)")
        guard let source = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw SevoExit.failed
        }
        let manager = FileManager.default
        do {
            // Replace only something that is itself a symlink; anything else
            // at that path is not ours to overwrite.
            if let existing = try? manager.destinationOfSymbolicLink(atPath: target.path) {
                if existing == source.path {
                    print("already installed: \(target.path) → \(source.path)")
                    return
                }
                try manager.removeItem(at: target)
            }
            try manager.createSymbolicLink(at: target, withDestinationURL: source)
            print("installed: \(target.path) → \(source.path)")
        } catch {
            Sevo.printError("could not install (\(error.localizedDescription)) — run:")
            Sevo.printError("  sudo ln -sf '\(source.path)' \(target.path)")
            throw SevoExit.failed
        }
    }
}

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version", abstract: "Print the sevo version.",
    )

    func run() async throws {
        print("sevo \(Sevo.version)")
    }
}
