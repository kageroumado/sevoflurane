import Foundation

/// `sevo stats delete`'s answer: what ``StatsUploader/deleteShared()`` came
/// to, in the words and fields the other `sevo stats` verbs use.
nonisolated struct StatsDeletionReport: Equatable {
    enum Result: String {
        case deleted
        case notRegistered = "not_registered"
        case keyUnavailable = "key_unavailable"
        case failed
    }

    var result: Result
    var install: String?
    /// The HTTP status the database refused with.
    var status: Int?
    var error: String?
    /// ``Preferences/sharesRunStats`` when the command ran.
    var sharing: Bool?
    /// Runs that were waiting to be sent and went with the local state.
    var droppedQueued: Int
    /// Why a failed request failed, as a clause.
    private var failure: String?

    init(outcome: Swift.Result<StatsUploader.DeleteOutcome, any Error>, sharing: Bool?, queued: Int) {
        self.sharing = sharing
        droppedQueued = 0
        switch outcome {
        case let .success(.deleted(install)):
            result = .deleted
            self.install = install
            droppedQueued = queued
        case .success(.notRegistered):
            result = .notRegistered
            droppedQueued = queued
        case let .success(.keyUnavailable(install)):
            result = .keyUnavailable
            self.install = install
            droppedQueued = queued
        case let .failure(thrown):
            result = .failed
            switch thrown as? StatsUploader.Failure {
            case let .refused(status, reason):
                self.status = status
                error = reason
                failure = "the database answered HTTP \(status)\(reason.map { ": \($0)" } ?? "")"
            case let .unreachable(reason):
                error = reason
                failure = "the database is unreachable (\(reason))"
            case .noSecureEnclave:
                error = "this Mac has no Secure Enclave"
                failure = error
            case nil:
                error = thrown.localizedDescription
                failure = error
            }
        }
    }

    /// Whether the command did what was asked: the database holds nothing
    /// from this Mac.
    var succeeded: Bool {
        result == .deleted || result == .notRegistered
    }

    /// The sharing preference as `sevo stats` prints it.
    static func sharingWord(_ sharing: Bool?) -> String {
        switch sharing {
        case true?: "on"
        case false?: "off"
        case nil: "not asked yet"
        }
    }

    var text: String {
        var lines: [String] = switch result {
        case .deleted:
            ["deleted every run install \(install ?? "?") shared; this Mac's key and registration are gone"]
        case .notRegistered where sharing == nil:
            ["nothing to delete: sharing was never turned on, so the database holds nothing from this Mac"]
        case .notRegistered:
            ["nothing to delete: this Mac never registered with the database, so it holds nothing from it"]
        case .keyUnavailable:
            [
                "not deleted: install \(install ?? "?") is registered, but its key no longer opens on this Mac "
                    + "(a backup restored from another Mac), so nothing can sign the request",
                "its runs stay in the database; the local registration was reset",
            ]
        case .failed:
            [
                "not deleted: \(failure ?? "unknown failure")",
                "this Mac's key and registration are kept; try again later",
            ]
        }
        if droppedQueued > 0 {
            lines.append("\(droppedQueued) queued run\(droppedQueued == 1 ? "" : "s") dropped unsent")
        }
        if succeeded, sharing == true {
            lines.append("sharing is still on: the next run shared registers a new, unrelated install "
                + "(Settings › General › Community turns it off)")
        }
        return lines.joined(separator: "\n")
    }

    var json: [String: Any] {
        var report: [String: Any] = [
            "result": result.rawValue,
            "sharing": Self.sharingWord(sharing),
            "dropped_queued": droppedQueued,
        ]
        report["install"] = install
        report["status"] = status
        report["error"] = error
        return report
    }
}
