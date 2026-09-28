import Foundation

/// Whether a closed run kept so many threads busy that telling the game of
/// fewer processors would help, and to how many.
///
/// A game that starts one worker per processor and keeps them all spinning
/// under Rosetta starves its own frame thread: Higurashi Hou on a 16-core Mac
/// ran 15 busy threads at 54 fps, and 117 fps when told of 8 processors.
nonisolated enum ThreadSpinDiagnosis {
    /// What the run showed, and the cap that lets its workers sleep.
    struct Suggestion: Equatable, Sendable {
        let busy: Int
        let processors: Int
        let cap: Int
    }

    /// The fewest busy threads that count as spinning workers.
    static let minimumBusy = 6
    /// The share of the processors the busy threads must reach: one worker per
    /// processor, less the ones that happened to rest.
    static let minimumShare = 0.4
    /// The focused samples a run needs before its threads say anything: ten, two
    /// seconds apart. The thread count is its own evidence, so it is measured over
    /// the time the game was in front, which starts before the frame trace's
    /// gameplay does.
    static let minimumSamples = 10
    /// The largest cap offered: what Higurashi Hou ran well at on a 16-core Mac.
    static let largestCap = 8
    /// The smallest cap offered.
    static let smallestCap = 2

    /// The suggestion for `record`, or nil when its threads were quiet, the game
    /// already has a cap, the run was short, or the user asked not to hear it.
    ///
    /// - Parameters:
    ///   - currentCap: The game's processors setting as it resolves now; `0` or
    ///     nil is every processor.
    ///   - asks: Whether the offer is still wanted for this game.
    static func suggestion(for record: RunRecord, currentCap: Int?, asks: Bool = true) -> Suggestion? {
        guard asks, (currentCap ?? 0) <= 0, let threads = record.threads,
              threads.samples >= minimumSamples,
              threads.busy >= minimumBusy,
              Double(threads.busy) >= minimumShare * Double(threads.processors) else { return nil }
        return Suggestion(busy: threads.busy, processors: threads.processors, cap: cap(for: threads.processors))
    }

    /// The processors to tell a game of on a Mac with `processors` of them: half,
    /// within ``smallestCap`` and ``largestCap``.
    static func cap(for processors: Int) -> Int {
        min(largestCap, max(smallestCap, processors / 2))
    }
}
