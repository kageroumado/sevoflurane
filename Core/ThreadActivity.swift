import Darwin
import Foundation

/// How many of a process's threads are keeping a core busy, from
/// `proc_pidinfo` (`PROC_PIDLISTTHREADS`, then `PROC_PIDTHREADINFO` per thread).
///
/// A game that never parks its per-processor workers (Unity 5's JobQueue under
/// Rosetta) reads as a dozen busy threads; a game that plays well, one or two.
nonisolated enum ThreadActivity {
    /// `pth_cpu_usage` counts per mille of one core (`TH_USAGE_SCALE`).
    static let usageScale = 1000

    /// 60 % of one core.
    static let busyThreshold = usageScale * 6 / 10

    /// The most thread handles one read lists.
    static let maximumThreads = 1024

    /// How many of `pid`'s threads are at or above `threshold` right now, or
    /// `nil` when the process is gone or belongs to another user.
    static func busyThreads(pid: pid_t, threshold: Int = busyThreshold) -> Int? {
        guard let usages = usages(pid: pid) else { return nil }
        return busyCount(usages, threshold: threshold)
    }

    /// How many of `usages` are at or above `threshold`.
    static func busyCount(_ usages: [Int], threshold: Int = busyThreshold) -> Int {
        usages.count { $0 >= threshold }
    }

    /// Every thread's usage, per mille of one core.
    static func usages(pid: pid_t) -> [Int]? {
        var handles = [UInt64](repeating: 0, count: maximumThreads)
        let bytes = handles.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return nil }
        let count = min(Int(bytes) / MemoryLayout<UInt64>.stride, maximumThreads)
        let infoSize = Int32(MemoryLayout<proc_threadinfo>.stride)
        return handles.prefix(count).compactMap { handle in
            var info = proc_threadinfo()
            let read = proc_pidinfo(pid, PROC_PIDTHREADINFO, handle, &info, infoSize)
            return read == infoSize ? Int(info.pth_cpu_usage) : nil
        }
    }
}
