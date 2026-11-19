import Foundation
import Testing
@testable import Sevoflurane

/// The app link port's reading of a request's query.
struct AppLinkServerTests {
    @Test
    func `a query value arrives decoded, with any equals sign it holds`() {
        let query = "label=boss%20fight%20%231&expr=a%3Db=c&force=1"
        #expect(AppLinkServer.value(of: "label", in: query) == "boss fight #1")
        #expect(AppLinkServer.value(of: "expr", in: query) == "a=b=c")
        #expect(AppLinkServer.value(of: "force", in: query) == "1")
        #expect(AppLinkServer.value(of: "missing", in: query) == "")
    }
}
