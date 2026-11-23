import Foundation

/// The helper's word to the app that it is starting an added program, sent
/// just before the program's process is spawned, whoever asked for the launch:
/// the popover, a Dock tile, the adoption panel, `sevo program launch` or the
/// MCP server. The app opens the program's run from it, so every launch the
/// helper makes has one run and the app's own launches open none themselves.
nonisolated struct ProgramStartNotice: Equatable, Sendable {
    /// The app link's route for the notice.
    static let path = "/program/starting"

    /// The program's id in ``AdoptedPrograms``.
    let programID: Int

    init(programID: Int) {
        self.programID = programID
    }

    /// The notice a request's query carries, or `nil` when it names no added
    /// program: a Steam app id never opens a run this way.
    init?(query: String) {
        guard let id = Int(QueryString.value(of: "id", in: query)), AdoptedPrograms.isAdopted(id) else { return nil }
        programID = id
    }

    /// The request target the helper posts.
    var target: String {
        "\(Self.path)?id=\(programID)"
    }
}

/// What the helper's `/program/launch` answers for a program it started.
nonisolated struct ProgramLaunchReply: Codable, Equatable, Sendable {
    var ok = true
    var note = "program started"
    /// Whether the app took the start notice and opened the program's run.
    /// The run recorder lives in the app, so a launch made while no app is
    /// attached to the helper has no run record, panel or frame trace.
    let recorded: Bool

    /// What `sevo` says of the started program.
    func summary(of name: String) -> String {
        recorded ? "\(name) started" : "\(name) started, with no run record: the app was not there to open one"
    }
}
