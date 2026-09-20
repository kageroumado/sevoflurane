import Testing
@testable import Sevoflurane

/// Which of the Steam UI's reported errors are the ones every session makes.
struct PageErrorTriageTests {
    @Test
    func `a SteamVR call the client has no interface for is expected`() {
        let detail = #"{"message":"SteamClient.OpenVR.PathProperties.SetBoolPathProperty rejected: CVRPathHelpers not found","stack":"","kind":"rejection"}"#
        #expect(PageErrorTriage.verdict(for: detail) != .error)
    }

    @Test
    func `a call refused by a closing client is expected`() {
        let detail = #"{"message":"SteamClient.Storage.SetString rejected: closed","stack":"@http://127.0.0.1:8762/index.html:215:56","kind":"rejection"}"#
        #expect(PageErrorTriage.verdict(for: detail) != .error)
    }

    @Test
    func `anything else is an error`() {
        let crash = #"{"message":"undefined is not an object (evaluating 'e.removeEventListener')","kind":"uncaught"}"#
        #expect(PageErrorTriage.verdict(for: crash) == .error)
        #expect(PageErrorTriage.verdict(for: "SteamClient.Apps.RunGame rejected: timeout") == .error)
    }
}
