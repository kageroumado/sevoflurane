import Darwin
import Foundation

/// Wine processes whose wineserver is gone.
///
/// Every handle, window and object a Wine process holds lives in its server, so without one
/// it is parked forever unless its engine ends it (dormison's dead-name watch on the msync
/// port). A crashed server or a killed harness can leave hundreds.
///
/// A process counts as Wine's when its executable lies under an engine root. Its prefix is
/// read from its working directory, which Wine keeps inside the prefix's `drive_c` (or
/// `dosdevices`) tree; a process whose prefix cannot be named is left alone. The server is
/// alive while it holds the write lock on `lock` in `/tmp/.wine-<uid>/server-<dev>-<inode>`,
/// the loader's own test.
nonisolated enum WineOrphans {
    struct Orphan: Sendable, Equatable, Codable {
        var pid: pid_t
        var executable: String
        var prefix: String
        /// What `ps` shows: the Windows command line the engine writes over `argv`.
        var command: String
    }

    static let defaultRoots = [Engine.managedRoot.path]

    /// Every process under `roots` whose prefix has no live wineserver.
    static func find(roots: [String] = defaultRoots) -> [Orphan] {
        var serverAlive: [String: Bool] = [:]
        return allProcessIDs().compactMap { pid -> Orphan? in
            guard pid != getpid(), let executable = executablePath(of: pid),
                  roots.contains(where: { !$0.isEmpty && executable.hasPrefix($0 + "/") }),
                  !executable.hasSuffix("/wineserver")
            else { return nil }
            // Every prefix the process can be read as: a game linked in from
            // another bottle has its working directory resolved through the
            // link into that bottle, while its environment names its own. It
            // is an orphan only when none of them has a live server.
            let candidates = prefixes(of: pid)
            guard let prefix = candidates.first else { return nil }
            for candidate in candidates {
                let alive = serverAlive[candidate] ?? isServerAlive(forPrefix: candidate)
                serverAlive[candidate] = alive
                if alive { return nil }
            }
            return Orphan(
                pid: pid, executable: executable, prefix: prefix,
                command: commandLine(of: pid) ?? (executable as NSString).lastPathComponent,
            )
        }
    }

    /// `SIGKILL`s the orphans, since no server can ask for an orderly exit, and returns the
    /// ones that were still there.
    @discardableResult
    static func end(_ orphans: [Orphan]) -> [Orphan] {
        orphans.filter { kill($0.pid, SIGKILL) == 0 }
    }

    // MARK: - The prefix and its server

    /// The process's `WINEPREFIX` when it names a prefix on disk, then the prefix its
    /// working directory lies in, without repeats.
    static func prefixes(of pid: pid_t) -> [String] {
        var found: [String] = []
        if let named = environmentValue("WINEPREFIX", of: pid),
           FileManager.default.fileExists(atPath: (named as NSString).appendingPathComponent("system.reg")) {
            found.append((named as NSString).standardizingPath)
        }
        if let directory = workingDirectory(of: pid), let prefix = prefix(containing: directory),
           !found.contains(prefix) {
            found.append(prefix)
        }
        return found
    }

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

    /// `/tmp/.wine-<uid>/server-<dev>-<inode>` of the prefix, lowercase unpadded hex
    /// (`init_server_dir` in ntdll).
    static func serverDirectory(forPrefix prefix: String, uid: uid_t = getuid()) -> String? {
        var info = stat()
        guard stat(prefix, &info) == 0 else { return nil }
        // Wine formats the signed `dev_t` through `unsigned long long`, which sign-extends.
        return serverDirectory(device: UInt64(bitPattern: Int64(info.st_dev)), inode: info.st_ino, uid: uid)
    }

    static func serverDirectory(device: UInt64, inode: UInt64, uid: uid_t) -> String {
        "/tmp/.wine-\(uid)/server-\(String(device, radix: 16))-\(String(inode, radix: 16))"
    }

    static func isServerAlive(forPrefix prefix: String) -> Bool {
        guard let directory = serverDirectory(forPrefix: prefix) else { return false }
        return isLockHeld(at: directory + "/lock")
    }

    /// Whether another process holds a write lock on the file; `F_GETLK` takes none.
    static func isLockHeld(at path: String) -> Bool {
        // `/tmp` is every account's: only this account's own plain file
        // counts, opened without following a link or waiting on a FIFO.
        let descriptor = open(path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            return false
        }
        var request = flock()
        request.l_type = Int16(F_WRLCK)
        request.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &request) == 0 else { return true }
        return request.l_type != Int16(F_UNLCK)
    }

    // MARK: - Processes

    static func allProcessIDs() -> [pid_t] {
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
        guard let arguments = processArguments(of: pid)?.arguments else { return nil }
        let line = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    /// One variable of the process's environment, as `KERN_PROCARGS2` holds it. Wine
    /// writes the Windows command line over `argv`, which can run into this area,
    /// so a caller checks the value before trusting it.
    static func environmentValue(_ name: String, of pid: pid_t) -> String? {
        let key = name + "="
        return processArguments(of: pid)?.environment
            .first { $0.hasPrefix(key) }
            .map { String($0.dropFirst(key.count)) }
    }

    /// `argv` and `envp` from `KERN_PROCARGS2`: argc, the executable path, NUL
    /// padding, then the arguments and the environment, one NUL apart.
    static func processArguments(of pid: pid_t) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var strings: [String] = []
        while index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            // The environment ends at the first empty string.
            if index == start, strings.count >= Int(argc) { break }
            strings.append(String(decoding: buffer[start ..< index], as: UTF8.self))
            index += 1
        }
        let count = min(Int(argc), strings.count)
        return (Array(strings.prefix(count)), Array(strings.dropFirst(count)))
    }

    /// The vnode paths of the process's open files, read through `libproc`. Never `lsof`: it
    /// walks every mount and blocks uninterruptibly on a wedged file system.
    static func openFilePaths(of pid: pid_t) -> [String] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.size
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, bufferSize)
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
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

/// Ends orphans seen on two passes in a row, so a client caught between its start and its
/// server's lock is spared.
nonisolated struct WineOrphanReaper: Sendable {
    private var suspects: Set<pid_t> = []

    init() {}

    /// Returns the orphans the previous pass also saw, and remembers `found` for the next.
    mutating func confirm(_ found: [WineOrphans.Orphan]) -> [WineOrphans.Orphan] {
        let confirmed = found.filter { suspects.contains($0.pid) }
        suspects = Set(found.map(\.pid))
        return confirmed
    }
}
