import Foundation
import Testing
@testable import Sevoflurane

/// The control port's door to the supervisor. A request that names no verb
/// leaves what the supervisor wants exactly as it was: a `GET /client/start`
/// that asked for a client before its refusal would let any read wake an idle
/// supervisor and launch Steam.
struct ClientVerbTests {
    /// Routes one request and records what the supervisor was told.
    private func admit(_ method: String, _ path: String) -> (admission: ClientVerb.Admission, wanted: [String]) {
        var wanted: [String] = []
        let admission = ClientVerb.admit(method: method, path: path) { wanted.append($0) }
        return (admission, wanted)
    }

    private func status(_ admission: ClientVerb.Admission) -> Int? {
        guard case let .refused(response) = admission else { return nil }
        return response.status
    }

    @Test
    func `a GET of client start asks for nothing and is refused`() {
        let (admission, wanted) = admit("GET", "/client/start")
        #expect(wanted.isEmpty)
        #expect(status(admission) == 405)
        guard case let .refused(response) = admission else { return }
        #expect(response.headers.contains { $0 == ("Allow", "POST") })
    }

    @Test
    func `no method but POST reaches any verb`() {
        for path in ClientVerb.paths.keys {
            for method in ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "post"] {
                let (admission, wanted) = admit(method, path)
                #expect(wanted.isEmpty, "\(method) \(path)")
                #expect(status(admission) == 405, "\(method) \(path)")
            }
        }
    }

    @Test
    func `a POST of client start asks for a client once`() {
        let (admission, wanted) = admit("POST", "/client/start")
        guard case .verb(.start) = admission else {
            Issue.record("expected the start verb")
            return
        }
        #expect(wanted == ["/client/start was asked for"])
    }

    @Test
    func `only the verbs that need a client ask for one`() {
        let asking = ClientVerb.paths.filter(\.value.asksForAClient).keys
        #expect(Set(asking) == [
            "/client/start", "/client/restart", "/client/forcequit", "/game/launch", "/library/show-when-healthy",
        ])
        let (admission, wanted) = admit("POST", "/bottle/run")
        guard case .verb(.runInBottle) = admission else {
            Issue.record("expected the bottle run verb")
            return
        }
        #expect(wanted.isEmpty)
    }

    @Test
    func `a path that is no verb's answers 404 and asks for nothing`() {
        let (admission, wanted) = admit("POST", "/client/launch-everything")
        #expect(wanted.isEmpty)
        #expect(status(admission) == 404)
    }
}
