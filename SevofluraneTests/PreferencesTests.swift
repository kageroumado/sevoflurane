import Foundation
import Testing
@testable import Sevoflurane

/// The stored choices a reinstall forgets.
struct PreferencesTests {
    @Test
    func `a reset empties the app's own domain too, so no old key is copied back`() throws {
        let suiteName = "PreferencesTests.suite.\(UUID().uuidString)"
        let appName = "PreferencesTests.app.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        let app = try #require(UserDefaults(suiteName: appName))
        defer {
            suite.removePersistentDomain(forName: suiteName)
            app.removePersistentDomain(forName: appName)
        }
        suite.set("dxmt", forKey: "managedRenderer")
        app.set("d3dmetal", forKey: "managedRenderer")

        Preferences.reset(suite: suite, named: suiteName, app: app, named: appName)

        #expect(suite.object(forKey: "managedRenderer") == nil)
        #expect(app.object(forKey: "managedRenderer") == nil)
    }
}
