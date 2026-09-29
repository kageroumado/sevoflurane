import ArgumentParser
import Foundation

/// `sevo sync` — msync+ from the terminal.
struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "msync+: find and wake threads left asleep on an object that is available.",
        subcommands: [Sweep.self],
    )

    struct Sweep: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sweep",
            abstract: "Ask the booted bottle's wineserver for a lost-wake sweep and print what it woke.",
            discussion: """
            A thread that dies between setting an object and waking its sleepers leaves them \
            asleep on an object that reads available, which is how a game's exit can leave \
            steam.exe stuck on its main thread. The sweep looks twice, 100 ms apart, wakes every \
            thread parked on an object that stayed available and unchanged, and names the object \
            and the processes that share it. Waking a thread that had nothing to wait for costs \
            it one look at its object, so the sweep is safe with a game running. It needs an \
            msync+ wineserver (Dormison b1 and later); exit 1 when the engine has none or no \
            wineserver is running.
            """,
        )
        @Flag(name: .customLong("json"), help: "Machine-readable report.")
        var asJSON = false

        func run() async throws {
            let outcome = await MsyncSweep.run()
            switch outcome {
            case let .swept(report):
                if asJSON {
                    print(Sevo.json(["lost_wakes": report.lostWakes, "summary": report.summary, "lines": report.lines], pretty: true))
                    return
                }
                print(report.lostWakes == 0 ? "no lost wakes: \(report.summary)" : report.summary)
                for line in report.lines { print(line) }
            case let .unsupported(reason):
                Sevo.printError(reason)
                throw SevoExit.failed
            case .noServer:
                Sevo.printError("no wineserver is running in the booted bottle")
                throw SevoExit.failed
            case .noReport:
                Sevo.printError("the wineserver wrote no sweep report within 2 s")
                throw SevoExit.failed
            }
        }
    }
}
