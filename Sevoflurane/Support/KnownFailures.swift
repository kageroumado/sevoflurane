import Foundation

/// The failures this project has already diagnosed, matched against a run
/// record.
///
/// There are not many failure modes, only many ways to print them: a game
/// that dies before it draws, a fatal error in an engine's own runtime, a
/// renderer refusing a call. Each entry turns a run record into the sentence
/// a person can act on, and carries the fix where one exists.
nonisolated enum KnownFailures {
    struct Entry: Sendable {
        /// Stable across versions: an issue can name it.
        let id: String
        /// What happened, in one sentence.
        let summary: String
        /// What to do about it, when there is something to do.
        let fix: String?
        let matches: @Sendable (RunRecord) -> Bool
    }

    /// The first entry that recognizes this run.
    static func match(_ record: RunRecord) -> Entry? {
        all.first { $0.matches(record) }
    }

    /// Ordered: a run's own ending is more useful than a renderer's
    /// complaints during it, so the exit entries come first.
    static let all: [Entry] = [
        Entry(
            id: "unity-exit-1-no-window",
            summary: "The Unity player exited with status 1 without ever putting a window on "
                + "screen, so it failed inside its own start-up — graphics device or Mono.",
            fix: "Its own Player.log says which; the report zip carries it under games/.",
            matches: { record in
                record.runtime == "unity" && record.exit?.code == 1
                    && record.windowAfterSeconds == nil
            },
        ),
        Entry(
            id: "unreal-exit-3",
            summary: "Unreal took the C runtime's abort() path — status 3 is what an uncaught "
                + "C++ exception ends in, and Unreal writes its own crash report first.",
            fix: "Saved/Logs and Saved/Crashes in the game's directory carry the callstack; "
                + "the report zip carries both under games/.",
            matches: { $0.runtime == "unreal" && $0.exit?.code == 3 },
        ),
        Entry(
            id: "dxmt-dropped-compute",
            summary: "DXMT dropped compute dispatches: converting the shader to Metal failed, "
                + "nothing was bound, and the pass did not run. What that costs depends on "
                + "what the pass did — often a black screen or a missing effect.",
            fix: "Try another renderer for this game: Settings › Games › the game › Renderer.",
            matches: { note($0, contains: "Shader not found?") },
        ),
        Entry(
            id: "dxmt-unsupported-feature",
            summary: "DXMT answers three Direct3D 11 feature queries with E_INVALIDARG "
                + "(instancing, markers, D3D9 options). Every well-behaved caller reads that "
                + "as \"no\", so it is cosmetic.",
            fix: nil,
            matches: { note($0, contains: "Not supported feature:") },
        ),
    ]

    private static func note(_ record: RunRecord, contains marker: String) -> Bool {
        record.notes?.contains { $0.contains(marker) } ?? false
    }
}
