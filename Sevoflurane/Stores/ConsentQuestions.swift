import Digoxin
import Foundation
import Observation

/// The two questions the popover asks once each: whether to share runs with
/// the community database, then whether to be counted among users.
///
/// Read once, when the popover is first built; an answer takes its card away
/// at once, and the next question waits for the next launch.
@MainActor
@Observable
final class ConsentQuestions {
    private(set) var asksSharing: Bool
    private(set) var asksUsage: Bool

    init(asksSharing: Bool, asksUsage: Bool) {
        self.asksSharing = asksSharing
        self.asksUsage = asksUsage
    }

    /// The questions this Mac's answers leave open.
    static func current() -> ConsentQuestions {
        let open = open(
            sharesRunStats: Preferences.sharesRunStats,
            usageCounting: Preferences.usageCounting,
            hasRuns: RunLog.hasRecords(),
        )
        return ConsentQuestions(asksSharing: open.sharing, asksUsage: open.usage)
    }

    /// The sharing question waits for a first run, so it has something to
    /// share; the usage question waits until the sharing one is off the
    /// screen.
    nonisolated static func open(
        sharesRunStats: Bool?, usageCounting: ConsentTier?, hasRuns: Bool,
    ) -> (sharing: Bool, usage: Bool) {
        let sharing = sharesRunStats == nil && hasRuns
        return (sharing, usageCounting == nil && !sharing)
    }

    func answerSharing(_ shares: Bool) {
        Preferences.sharesRunStats = shares
        EventLog.shared.log(.app, shares ? "run statistics: sharing" : "run statistics: not sharing")
        if shares {
            Task.detached(name: "Send queued shared runs") { await StatsUploader.shared.flush() }
        }
        asksSharing = false
    }

    func answerUsage(_ tier: ConsentTier) {
        UsageCounting.choose(tier)
        asksUsage = false
    }
}
