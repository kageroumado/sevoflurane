import Foundation

/// The home directory every path this app keeps under `~` starts from.
///
/// A test run gets a fresh one of its own in the temporary directory. `xctest`
/// hosts the tests inside the app, and the real home holds the installed app's
/// bottles, settings and logs: state that differs from one Mac to the next,
/// which a test must neither read nor change. Setting `HOME` for the test
/// process moves nothing, because Foundation answers the home directory from
/// the user database; the switch has to be here.
nonisolated enum UserHome {
    /// Whether this process hosts the test bundle. The same signal as
    /// ``TestHost/isHosting``, read here because the `sevo` package builds this
    /// file without that one.
    static let isTestRun = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static let url: URL = {
        guard isTestRun else { return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sevoflurane-test-home-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true,
        )
        try? FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true,
        )
        return home
    }()

    static var path: String {
        url.path
    }

    /// A preferences domain stored as a file in the test home, for a test run;
    /// `nil` otherwise. `UserDefaults` takes an absolute path as a suite name
    /// and keeps the domain in that file.
    static func testDefaults(named name: String) -> UserDefaults? {
        guard isTestRun else { return nil }
        return UserDefaults(suiteName: url.appendingPathComponent("Library/Preferences/\(name)").path)
    }
}
