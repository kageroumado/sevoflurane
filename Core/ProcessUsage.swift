import Darwin
import Foundation

/// One process's resource use from `proc_pid_rusage` (`RUSAGE_INFO_V6`).
///
/// One system call, readable for any process of the same user, which every
/// bottle process is. The stall watchdog samples it every two seconds, and a
/// run record's `energy` comes from it.
nonisolated struct ProcessUsage: Sendable, Equatable {
    let pid: pid_t
    /// User plus system time, nanoseconds.
    let cpuTimeNanoseconds: UInt64
    /// The part of ``cpuTimeNanoseconds`` spent on performance cores.
    let pCoreTimeNanoseconds: UInt64
    /// Mach physical footprint in bytes, as Activity Monitor shows it.
    let footprintBytes: UInt64
    /// Energy billed to the process, nanojoules.
    let energyNanojoules: UInt64
    let instructions: UInt64
    /// When the process started, in `mach_absolute_time` units.
    let startAbsoluteTime: UInt64

    var cpuSeconds: Double {
        Double(cpuTimeNanoseconds) / 1e9
    }

    /// 0 to 1.
    var pCoreShare: Double {
        guard cpuTimeNanoseconds > 0 else { return 0 }
        return min(1, Double(pCoreTimeNanoseconds) / Double(cpuTimeNanoseconds))
    }

    /// The rusage times are Mach time units, NOT nanoseconds as on Intel: on
    /// Apple silicon a unit is 125/3 ns, so a second of work reads as 0.024 s
    /// unconverted.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func nanoseconds(_ machTime: UInt64) -> UInt64 {
        machTime * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
    }

    /// The process's accounting right now, or `nil` when there is no such
    /// process or it belongs to another user.
    static func read(pid: pid_t) -> ProcessUsage? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return nil }
        return ProcessUsage(
            pid: pid,
            cpuTimeNanoseconds: nanoseconds(info.ri_user_time + info.ri_system_time),
            pCoreTimeNanoseconds: nanoseconds(info.ri_user_ptime + info.ri_system_ptime),
            footprintBytes: info.ri_phys_footprint,
            energyNanojoules: info.ri_billed_energy,
            instructions: info.ri_instructions,
            startAbsoluteTime: info.ri_proc_start_abstime,
        )
    }

    /// The direct children of a process.
    ///
    /// Never use `proc_listchildpids`: for a caller that is not root it answers
    /// EPERM and one byte, so every tree reads as childless (macOS 27).
    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: maximumChildren)
        let bytes = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return [] }
        let count = min(maximumChildren, Int(bytes) / MemoryLayout<pid_t>.size)
        return buffer.prefix(count).filter { $0 > 0 }
    }

    /// Caps the allocation on a sampling path; a game's loader spawns a handful.
    private static let maximumChildren = 256

    /// Every process under `roots`, the roots included, each once.
    static func tree(under roots: some Sequence<pid_t>) -> [pid_t] {
        var seen: Set<pid_t> = []
        var queue = Array(roots)
        var order: [pid_t] = []
        while let pid = queue.first {
            queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            order.append(pid)
            queue += children(of: pid)
        }
        return order
    }

    /// Whether the process is stopped (`SIGSTOP`, a debugger), which a
    /// sampler would otherwise read as zero CPU.
    static func isStopped(pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        return read == size && info.pbi_status == UInt32(SSTOP)
    }

    /// The executable's file name, which for a bottle process is the engine's
    /// loader rather than the Windows program inside it.
    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process's parent, or `nil` when it is gone.
    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        return read == size ? pid_t(info.pbi_ppid) : nil
    }

    static func exists(pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
