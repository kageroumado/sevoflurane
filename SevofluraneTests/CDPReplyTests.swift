import Foundation
import Testing
@testable import Sevoflurane

/// How a `Runtime.evaluate` reply becomes a value or an error.
struct CDPReplyTests {
    private func reply(_ result: [String: Any]) -> [String: Any] {
        ["id": 1, "result": result]
    }

    @Test
    func `a returned string is the value`() throws {
        let value = try CDPClient.value(fromEvaluateReply: reply(["result": ["type": "string", "value": "ok"]]))
        #expect(value == "ok")
    }

    @Test
    func `undefined is nil and a number is its JSON text`() throws {
        #expect(try CDPClient.value(fromEvaluateReply: reply(["result": ["type": "undefined"]])) == nil)
        #expect(try CDPClient.value(fromEvaluateReply: reply(["result": ["type": "number", "value": 3]])) == "3")
    }

    @Test
    func `a script that throws is an error, not a nil`() {
        let thrown = reply([
            "result": ["type": "object", "subtype": "error"],
            "exceptionDetails": [
                "text": "Uncaught",
                "exception": ["type": "object", "description": "ReferenceError: SteamClient is not defined"],
            ],
        ])
        #expect(throws: CDPClient.Failure.scriptThrew("ReferenceError: SteamClient is not defined")) {
            try CDPClient.value(fromEvaluateReply: thrown)
        }
    }

    @Test
    func `a rejected promise with a plain value names that value`() {
        let rejected = reply([
            "result": ["type": "string", "value": "nope"],
            "exceptionDetails": ["text": "Uncaught (in promise)", "exception": ["type": "string", "value": "nope"]],
        ])
        #expect(throws: CDPClient.Failure.scriptThrew("nope")) {
            try CDPClient.value(fromEvaluateReply: rejected)
        }
    }
}
