import Foundation

/// Whether this process is a test bundle's host.
///
/// `xctest` loads `SevofluraneTests` into the app itself, so running the tests
/// runs Sevoflurane — under the shipping bundle identifier, over the live
/// install's preferences, one call away from the daemon that owns a Steam
/// client somebody is playing on. Every path that reaches the machine asks
/// this first.
///
/// It is not `#if DEBUG`: the configuration a test action builds is the
/// scheme's to choose, and this project has no scheme in it to read, so a
/// Release test run is as likely as a Debug one and the guard has to hold in
/// both.
nonisolated enum TestHost {
    /// `xctest` puts its configuration path in the environment of the process
    /// it loads the bundle into, which is this one.
    static let isHosting = ProcessInfo.processInfo
        .environment["XCTestConfigurationFilePath"] != nil
}
