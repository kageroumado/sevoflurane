import Foundation

/// Diagnosed failures matched against a run record, each turned into a
/// sentence a person can act on, with the fix where one exists.
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

    /// Exit entries come first: a run's ending says more than a renderer's
    /// complaints during it.
    static let all: [Entry] = [
        Entry(
            id: "unity-exit-1-no-window",
            summary: "The Unity game quit with status 1 and never drew a window. It "
                + "failed during start-up, in its graphics device or in Mono.",
            fix: "Its own Player.log says which. The report zip carries it under games/.",
            matches: { record in
                record.runtime == "unity" && record.exit?.code == 1
                    && record.windowAfterSeconds == nil
            },
        ),
        Entry(
            id: "unreal-exit-3",
            summary: "Unreal quit with status 3, the ending of an uncaught C++ exception. "
                + "It writes its own crash report first.",
            fix: "Saved/Logs and Saved/Crashes in the game's folder carry the callstack. "
                + "The report zip carries both under games/.",
            matches: { $0.runtime == "unreal" && $0.exit?.code == 3 },
        ),
        Entry(
            id: "dxmt-dropped-compute",
            summary: "DXMT dropped compute work. A shader failed to convert to Metal, so "
                + "the pass never ran. Expect a black screen or a missing effect.",
            fix: "Try another renderer in Settings › Games › the game › Renderer.",
            matches: { note($0, contains: "Shader not found?") },
        ),
        Entry(
            id: "dxmt-unsupported-feature",
            summary: "DXMT refuses three Direct3D 11 feature queries with E_INVALIDARG. "
                + "They cover instancing, markers, and D3D9 options. Callers read the "
                + "answer as a no, so the effect is cosmetic.",
            fix: nil,
            matches: { note($0, contains: "Not supported feature:") },
        ),
    ]

    private static func note(_ record: RunRecord, contains marker: String) -> Bool {
        record.notes?.contains { $0.contains(marker) } ?? false
    }
}
