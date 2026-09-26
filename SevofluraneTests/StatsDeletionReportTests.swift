import Foundation
import Testing
@testable import Sevoflurane

/// What `sevo stats delete` says about each way ``StatsUploader/deleteShared()`` can end.
struct StatsDeletionReportTests {
    private typealias Outcome = Result<StatsUploader.DeleteOutcome, any Error>

    @Test
    func `a delete names the install, the dropped queue and that sharing stays on`() {
        let report = StatsDeletionReport(outcome: Outcome.success(.deleted(install: "m5a5fa")), sharing: true, queued: 2)
        #expect(report.succeeded)
        #expect(report.text == """
        deleted every run install m5a5fa shared; this Mac's key and registration are gone
        2 queued runs dropped unsent
        sharing is still on: the next run shared registers a new, unrelated install \
        (Settings › General › Community turns it off)
        """)
        #expect(report.json as NSDictionary == [
            "result": "deleted", "install": "m5a5fa", "sharing": "on", "dropped_queued": 2,
        ])
    }

    @Test
    func `an unregistered Mac says why the database holds nothing`() {
        let neverAsked = StatsDeletionReport(outcome: Outcome.success(.notRegistered), sharing: nil, queued: 0)
        #expect(neverAsked.succeeded)
        #expect(neverAsked.text == "nothing to delete: sharing was never turned on, so the database holds nothing from this Mac")
        #expect(neverAsked.json as NSDictionary == [
            "result": "not_registered", "sharing": "not asked yet", "dropped_queued": 0,
        ])
        let off = StatsDeletionReport(outcome: Outcome.success(.notRegistered), sharing: false, queued: 1)
        #expect(off.text == """
        nothing to delete: this Mac never registered with the database, so it holds nothing from it
        1 queued run dropped unsent
        """)
    }

    @Test
    func `a key that no longer opens fails and says the runs stay`() {
        let report = StatsDeletionReport(outcome: Outcome.success(.keyUnavailable(install: "abc")), sharing: false, queued: 0)
        #expect(!report.succeeded)
        #expect(report.text.hasPrefix("not deleted: install abc is registered, but its key no longer opens on this Mac"))
        #expect(report.json["result"] as? String == "key_unavailable")
        #expect(report.json["install"] as? String == "abc")
    }

    @Test
    func `a refused request carries its status and keeps the install`() {
        let refused = StatsDeletionReport(
            outcome: Outcome.failure(StatsUploader.Failure.refused(status: 503, reason: "maintenance")),
            sharing: true, queued: 3,
        )
        #expect(!refused.succeeded)
        #expect(refused.text == """
        not deleted: the database answered HTTP 503: maintenance
        this Mac's key and registration are kept; try again later
        """)
        #expect(refused.json as NSDictionary == [
            "result": "failed", "status": 503, "error": "maintenance", "sharing": "on", "dropped_queued": 0,
        ])
        let offline = StatsDeletionReport(
            outcome: Outcome.failure(StatsUploader.Failure.unreachable("offline")), sharing: true, queued: 0,
        )
        #expect(offline.text.hasPrefix("not deleted: the database is unreachable (offline)\n"))
        #expect(offline.json["status"] == nil)
    }
}
