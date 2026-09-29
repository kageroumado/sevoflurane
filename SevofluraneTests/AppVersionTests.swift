import Foundation
import Testing
@testable import Sevoflurane

/// The marketing version as a person reads it, and how two versions order —
/// the order the daemon's staleness check and the updater's tags agree on.
struct AppVersionTests {
    @Test
    func `a beta version reads as words`() {
        #expect(AppVersion.display("1.0-beta.1") == "1.0 beta 1")
        #expect(AppVersion.display("1.0.0-beta.1") == "1.0 beta 1")
        #expect(AppVersion.display("1.2.3-beta.4") == "1.2.3 beta 4")
        #expect(AppVersion.display("1.2.3-beta.14") == "1.2.3 beta 14")
    }

    @Test
    func `any other version reads as it is`() {
        #expect(AppVersion.display("1.0") == "1.0")
        #expect(AppVersion.display("1.14") == "1.14")
        #expect(AppVersion.display("dev") == "dev")
        #expect(AppVersion.display("1.0b1") == "1.0b1")
        #expect(AppVersion.display("1.0-rc.1") == "1.0-rc.1")
    }

    @Test
    func `the bundle's version is displayed, or the fallback when it has none`() {
        #expect(AppVersion.displayed(from: ["CFBundleShortVersionString": "1.0-beta.1"], fallback: "dev") == "1.0 beta 1")
        #expect(AppVersion.displayed(from: [:], fallback: "dev") == "dev")
        #expect(AppVersion.displayed(from: nil, fallback: "0") == "0")
    }

    @Test
    func `versions compare component by component`() {
        #expect(AppVersion.isOlder("1.5", than: "1.6"))
        #expect(AppVersion.isOlder("1.6", than: "1.6.1"))
        #expect(!AppVersion.isOlder("1.6", than: "1.6.0"))
        #expect(!AppVersion.isOlder("1.6.0", than: "1.6"))
        #expect(!AppVersion.isOlder("1.10", than: "1.9"))
        #expect(AppVersion.isOlder("1.9", than: "1.10"))
        // A non-numeric or empty version counts as zero, so it never reads as
        // newer than a numbered release.
        #expect(AppVersion.isOlder("dev", than: "1.6"))
        #expect(AppVersion.isOlder("0", than: "1.6"))
    }

    @Test
    func `a beta comes after the release before it and before its own release`() {
        #expect(AppVersion.isOlder("1.0-beta.1", than: "1.0"))
        #expect(!AppVersion.isOlder("1.0", than: "1.0-beta.1"))
        #expect(AppVersion.isOlder("1.0-beta.1", than: "1.0-beta.2"))
        #expect(AppVersion.isOlder("1.0-beta.9", than: "1.0-beta.10"))
        #expect(AppVersion.isOlder("1.0", than: "1.1-beta.1"))
        #expect(AppVersion.isOlder("0.9", than: "1.0-beta.1"))
        #expect(!AppVersion.isOlder("1.0-beta.1", than: "1.0-beta.1"))
        #expect(!AppVersion.isOlder("1.0-beta.1", than: "1.0.0-beta.1"))
    }
}
