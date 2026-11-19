import Foundation

/// Whether this process is a test bundle's host: `xctest` loads the tests into
/// the app, under the shipping bundle id and live preferences, so every path
/// that reaches the machine asks this first. A runtime check, never
/// `#if DEBUG`: a test run may build Release.
nonisolated enum TestHost {
    /// Set by `xctest` in the host's environment.
    static let isHosting = ProcessInfo.processInfo
        .environment["XCTestConfigurationFilePath"] != nil
}
