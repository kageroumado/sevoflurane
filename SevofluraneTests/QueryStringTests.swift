import Foundation
import Testing
@testable import Sevoflurane

/// The control port's query strings: what is encoded comes back decoded, and
/// a delimiter inside a value stays inside it.
struct QueryStringTests {
    @Test
    func `a value holding delimiters round-trips`() {
        let query = QueryString.encode([
            (name: "version", value: "r16 perf"),
            (name: "bottle", value: "A&B=C+D#1"),
        ])
        #expect(!query.contains("&B"))
        #expect(QueryString.value(of: "version", in: query) == "r16 perf")
        #expect(QueryString.value(of: "bottle", in: query) == "A&B=C+D#1")
    }

    @Test
    func `an absent or bare parameter is empty`() {
        #expect(QueryString.value(of: "missing", in: "a=1&b=2").isEmpty)
        #expect(QueryString.value(of: "flag", in: "flag&b=2").isEmpty)
        #expect(QueryString.value(of: "b", in: "flag&b=2") == "2")
    }

    @Test
    func `an encoding the app sends is decoded`() {
        #expect(QueryString.value(of: "name", in: "appid=1&name=Half%2DLife%202") == "Half-Life 2")
    }
}
