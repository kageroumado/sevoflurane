import Foundation

/// The one place the answer to "share how each game ran" is stored, with
/// what follows from it: a yes sends the runs that waited for it, a no
/// drops them.
nonisolated enum SharingConsent {
    static func store(_ shares: Bool) {
        Preferences.sharesRunStats = shares
        if shares {
            Task.detached(name: "Send queued shared runs") { await StatsUploader.shared.flush() }
        } else {
            StatsStore.writeQueue([])
        }
    }
}
