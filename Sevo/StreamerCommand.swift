import ArgumentParser
import Foundation

/// `sevo streamer` — Streamer Mode from the terminal, for a recording script
/// that flips it before it starts.
///
/// The switch lives in the shared suite, so it holds without the app; a
/// running app is asked on its own link port to reload Steam's pages with the
/// new state, which is the whole of applying it.
struct StreamerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "streamer",
        abstract: "Streamer Mode: hides the Steam account, wallet and friends in every Steam window.",
        subcommands: [On.self, Off.self, Status.self],
        defaultSubcommand: Status.self,
    )

    struct On: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "on", abstract: "Turn Streamer Mode on.")
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async {
            await StreamerCommand.set(true, asJSON: asJSON)
        }
    }

    struct Off: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "off", abstract: "Turn Streamer Mode off.")
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async {
            await StreamerCommand.set(false, asJSON: asJSON)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status", abstract: "Whether Streamer Mode is on, and the name it shows.",
        )
        @Flag(name: .customLong("json")) var asJSON = false

        func run() {
            StreamerCommand.report(note: nil, asJSON: asJSON)
        }
    }

    private static func set(_ on: Bool, asJSON: Bool) async {
        StreamerMode.isOn = on
        let reply = await AppControl.appLinkPost("/streamer/apply?on=\(on ? 1 : 0)", timeout: 10)
        let applied = reply.map { (200 ..< 300).contains($0.status) } ?? false
        report(
            note: applied
                ? "Steam's windows are reloading"
                : "the app is not running; Steam's windows follow it when the app next opens",
            asJSON: asJSON,
        )
    }

    private static func report(note: String?, asJSON: Bool) {
        let on = StreamerMode.isOn
        let name = StreamerMode.displayName
        let picture = FileManager.default.fileExists(atPath: StreamerMode.avatarURL.path)
            ? StreamerMode.avatarURL.path
            : "monogram"
        if asJSON {
            var payload: [String: Any] = ["on": on, "name": name, "picture": picture]
            payload["note"] = note
            print(Sevo.json(payload, pretty: true))
            return
        }
        let line = "streamer mode \(on ? "on" : "off") — shows \"\(name)\" with the \(picture == "monogram" ? "monogram" : "picture at \(picture)")"
        print(note.map { "\(line); \($0)" } ?? line)
    }
}
