import Darwin
import Foundation

/// How many of a process's threads are keeping a core busy, from the kernel's
/// own per-thread accounting (`proc_pidinfo` with `PROC_PIDLISTTHREADS`, then
/// `PROC_PIDTHREADINFO` for each thread).
///
/// A game that starts one worker per processor and never parks them (Unity 5's
/// JobQueue under Rosetta) reads as a dozen threads each near a full core; a
/// game that plays well reads as one or two.
nonisolated enum ThreadActivity {
    /// The kernel's usage scale: `pth_cpu_usage` counts per mille of one core
    /// (`TH_USAGE_SCALE`), so 1000 is a core kept fully busy.
    static let usageScale = 1000

    /// The usage at which a thread counts as busy: 60 % of one core.
    static let busyThreshold = 600

    /// The most thread handles one read lists.
    static let maximumThreads = 1024

    /// How many of `pid`'s threads are at or above `threshold` right now, or
    /// `nil` when the process is gone or belongs to another user.
    static func busyThreads(pid: pid_t, threshold: Int = busyThreshold) -> Int? {
        guard let usages = usages(pid: pid) else { return nil }
        return busyCount(usages, threshold: threshold)
    }

    /// How many of `usages` (per mille of one core, as ``usageScale`` counts)
    /// are at or above `threshold`.
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
