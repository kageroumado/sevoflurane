import Foundation

/// Where provisioning narrates itself: ``EventLog`` in the app, stderr in
/// `sevo`. Set once at process start, before any call.
nonisolated enum SetupLog {
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }
}
