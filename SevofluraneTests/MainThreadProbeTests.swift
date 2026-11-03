import Foundation
import JavaScriptCore
import Testing
@testable import Sevoflurane

/// The supervisor's main-thread probe: what it asks and how it reads the answer.
struct MainThreadProbeTests {
    @Test
    func `the expression parses and asks every question`() throws {
        let context = try #require(JSContext())
        context.setObject(MainThreadProbe.expression, forKeyedSubscript: "source" as NSString)
        let result = context.evaluateScript("try { new Function('return ' + source); 'ok' } catch (e) { String(e) }")?.toString()
        #expect(result == "ok")
        for question in MainThreadProbe.questions {
            #expect(MainThreadProbe.expression.contains("ask(\"\(question)\""))
        }
    }

    @Test
    func `one unanswered question is a stall and an unaskable one is not`() {
        let fine = MainThreadProbe.answer(from: #"{"install":"answered","proxy":"answered","details":"answered"}"#)
        #expect(fine == MainThreadProbe.Answer())
        #expect(fine?.stuck == false)
        let parked = MainThreadProbe.answer(from: #"{"install":"answered","proxy":"silent","details":"silent"}"#)
        #expect(parked?.silent == ["proxy", "details"])
        #expect(parked?.stuck == true)
        let renamed = MainThreadProbe.answer(from: #"{"install":"answered","proxy":"n/a"}"#)
        #expect(renamed?.unavailable == ["proxy", "details"])
        #expect(renamed?.stuck == false)
        #expect(MainThreadProbe.answer(from: nil) == nil)
        #expect(MainThreadProbe.answer(from: "silent") == nil)
        #expect(MainThreadProbe.answer(from: #""silent""#) == nil)
    }

    @Test
    func `the answer is read as the bridge sends it, a JSON string holding the object`() throws {
        let verdicts = #"{"install":"answered","proxy":"silent","details":"silent"}"#
        let wire = try #require(SteamBridge.jsonText(verdicts))
        let parked = MainThreadProbe.answer(from: wire)
        #expect(parked?.silent == ["proxy", "details"])
        #expect(parked?.stuck == true)
    }

    @Test
    func `the probe outlasts the bridge's own deadline so a stalled call is classed by its rejection`() {
        #expect(MainThreadProbe.timeout > CDPBudget.callCap)
    }
}
