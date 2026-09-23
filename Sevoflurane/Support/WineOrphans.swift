import Darwin
import Foundation

/// Wine processes whose wineserver is gone.
///
/// A Wine process cannot outlive its wineserver usefully: every handle, window and object it
/// holds lives in the server. An engine that notices the death ends the process itself
/// (dormison's dead-name watch on the msync port); an engine that does not leaves it parked
/// forever, and a crashed server, a killed harness or an older engine can leave hundreds of
/// them. This finds them and ends them.
///
/// A process counts as Wine's when its executable lies under one of the engine roots. Its
/// prefix is read from its working directory, which Wine keeps inside the prefix's `drive_c`
/// (or `dosdevices`) tree; a process whose prefix cannot be named is left alone. The prefix's
/// wineserver is alive while it holds the write lock on `lock` in its server directory,
/// `/tmp/.wine-<uid>/server-<dev>-<inode>`, which is the same test the loader makes before
/// starting a server of its own.
nonisolated enum WineOrphans {
    /// One process running an engine binary with no server behind it.
    struct Orphan: Sendable, Equatable, Codable {
        var pid: pid_t
        var executable: String
        var prefix: String
        /// What `ps` shows: the Windows command line the engine writes over `argv`.
        var command: String
    }

    /// Where engine binaries live: every managed engine.
    static let defaultRoots = [Engine.managedRoot.path]

    /// Every process under `roots` whose prefix has no live wineserver, found in one pass.
    static func find(roots: [String] = defaultRoots) -> [Orphan] {
        var serverAlive: [String: Bool] = [:]
        return allProcessIDs().compactMap { pid -> Orphan? in
            guard pid != getpid(), let executable = executablePath(of: pid),
                  roots.contains(where: { !$0.isEmpty && executable.hasPrefix($0 + "/") }),
                  !executable.hasSuffix("/wineserver"),
                  let directory = workingDirectory(of: pid),
                  let prefix = prefix(containing: directory)
            else { return nil }
            let alive = serverAlive[prefix] ?? isServerAlive(forPrefix: prefix)
            serverAlive[prefix] = alive
            guard !alive else { return nil }
            return Orphan(
                pid: pid, executable: executable, prefix: prefix,
                command: commandLine(of: pid) ?? (executable as NSString).lastPathComponent,
            )
        }
    }

    /// Ends the orphans. There is no server to ask for an orderly exit, so it is `SIGKILL`.
    /// Returns the ones that were still there to end.
    @discardableResult
    static func end(_ orphans: [Orphan]) -> [Orphan] {
        orphans.filter { kill($0.pid, SIGKILL) == 0 }
    }

    // MARK: - The prefix and its server

    /// The prefix a working directory lies in: the nearest ancestor holding `system.reg`, or
    /// the parent of a `drive_c` or `dosdevices` component.
    static func prefix(containing directory: String) -> String? {
        var components = (directory as NSString).standardizingPath.split(separator: "/").map(String.init)
        if let index = components.lastIndex(where: { $0 == "drive_c" || $0 == "dosdevices" }) {
            components = Array(components.prefix(index))
            return components.isEmpty ? nil : "/" + components.joined(separator: "/")
        }
        while !components.isEmpty {
            let candidate = "/" + components.joined(separator: "/")
            if FileManager.default.fileExists(atPath: candidate + "/system.reg") { return candidate }
            components.removeLast()
        }
        return nil
    }

    /// The directory the prefix's wineserver works in: `server-<dev>-<inode>` of the prefix,
    /// lowercase hex without padding, under `/tmp/.wine-<uid>` (`init_server_dir` in ntdll).
    static func serverDirectory(forPrefix prefix: String, uid: uid_t = getuid()) -> String? {
        var info = stat()
        guard stat(prefix, &info) == 0 else { return nil }
        // Wine formats the signed `dev_t` through `unsigned long long`, which sign-extends.
        return serverDirectory(device: UInt64(bitPattern: Int64(info.st_dev)), inode: info.st_ino, uid: uid)
    }

    static func serverDirectory(device: UInt64, inode: UInt64, uid: uid_t) -> String {
        "/tmp/.wine-\(uid)/server-\(String(device, radix: 16))-\(String(inode, radix: 16))"
    }

    /// Whether a wineserver holds the prefix's lock. A prefix that no longer exists has no
    /// server either.
    static func isServerAlive(forPrefix prefix: String) -> Bool {
        guard let directory = serverDirectory(forPrefix: prefix) else { return false }
        return isLockHeld(at: directory + "/lock")
    }

    /// Whether another process holds a write lock on the file. Asking takes no lock: `F_GETLK`
    /// only reports.
    static func isLockHeld(at path: String) -> Bool {
        let descriptor = open(path, O_RDWR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var request = flock()
        request.l_type = Int16(F_WRLCK)
        request.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &request) == 0 else { return true }
        return request.l_type != Int16(F_UNLCK)
    }

    // MARK: - Processes

    private static func allProcessIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, min(count, capacity))).filter { $0 > 0 }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// The process's `argv`, joined, as `KERN_PROCARGS2` holds it.
    static func commandLine(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        // argc, the executable path, NUL padding, then the arguments one NUL apart.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while index < size, arguments.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start ..< index], as: UTF8.self))
            index += 1
        }
        let line = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}

/// Ends orphans seen on two passes in a row, so a client caught in the moment between its
/// start and its server's lock is never one of them.
nonisolated struct WineOrphanReaper: Sendable {
    private var suspects: Set<pid_t> = []

    init() {}

    /// One pass over `found`: returns the orphans to end now, the ones the previous pass
    /// saw too, and remembers the rest for the next pass.
    mutating func confirm(_ found: [WineOrphans.Orphan]) -> [WineOrphans.Orphan] {
        let confirmed = found.filter { suspects.contains($0.pid) }
        suspects = Set(found.map(\.pid))
        return confirmed
    }
}
