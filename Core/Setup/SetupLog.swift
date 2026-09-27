import Foundation

/// Where provisioning narrates itself. The app points this at ``EventLog`` so
/// setup shares the one trail; the `sevo` CLI leaves it on stderr, where a
/// terminal or an agent reads it live. Same contract as
/// ``ClientLifecycle/log``: set once at process start, before any call.
nonisolated enum SetupLog {
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }
}
