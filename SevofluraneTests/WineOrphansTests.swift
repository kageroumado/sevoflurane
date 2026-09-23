import Foundation
import Testing
@testable import Sevoflurane

/// Finding Wine processes whose wineserver is gone: naming the prefix, naming its server
/// directory the way ntdll does, reading the server's lock, and the two-sighting rule.
struct WineOrphansTests {
    @Test
    func `a working directory inside drive_c names the prefix above it`() {
        #expect(WineOrphans.prefix(containing: "/Users/k/pfx/drive_c/windows/system32") == "/Users/k/pfx")
        #expect(WineOrphans.prefix(containing: "/Users/k/Bottles/Steam/dosdevices/c:") == "/Users/k/Bottles/Steam")
        #expect(WineOrphans.prefix(containing: "/drive_c") == nil)
    }

    @Test
    func `a working directory beside system reg names that directory`() throws {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphans-\(UUID().uuidString)")
        let inner = prefix.appendingPathComponent("some/where")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        try Data().write(to: prefix.appendingPathComponent("system.reg"))

        #expect(WineOrphans.prefix(containing: inner.path) == prefix.standardizedFileURL.path)
        #expect(WineOrphans.prefix(containing: "/usr/bin") == nil)
    }

    @Test
    func `the server directory is lowercase hex without padding`() {
        #expect(WineOrphans.serverDirectory(device: 0x100000D, inode: 0x10057EF5, uid: 501)
            == "/tmp/.wine-501/server-100000d-10057ef5")
        // A negative dev_t reaches Wine's %llx sign-extended.
        #expect(WineOrphans.serverDirectory(device: UInt64(bitPattern: -2), inode: 1, uid: 0)
            == "/tmp/.wine-0/server-fffffffffffffffe-1")
    }

    @Test
    func `a missing prefix has no live server`() {
        #expect(!WineOrphans.isServerAlive(forPrefix: "/nonexistent/prefix/\(UUID().uuidString)"))
    }

    @Test
    func `a lock held by another process reads as held, and a free one as free`() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!WineOrphans.isLockHeld(at: file.path))

        // fcntl locks belong to a process, so the holder has to be another one. Darwin's
        // struct flock is l_start, l_len, l_pid, l_type, l_whence.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-MFcntl", "-e",
            #"open(F, "+<", $ARGV[0]) or die; my $l = pack("q q i s s", 0, 1, 0, F_WRLCK, 0); fcntl(F, F_SETLK, $l) or die; $|=1; print "held\n"; sleep 30"#,
            file.path,
        ]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer { holder.terminate() }
        let line = output.fileHandleForReading.availableData
        #expect(String(decoding: line, as: UTF8.self).contains("held"))

        #expect(WineOrphans.isLockHeld(at: file.path))
        holder.terminate()
        holder.waitUntilExit()
        #expect(!WineOrphans.isLockHeld(at: file.path))
    }

    @Test
    func `an orphan is ended only on its second sighting in a row`() {
        func orphan(_ pid: pid_t) -> WineOrphans.Orphan {
            .init(pid: pid, executable: "/e/wine", prefix: "/p", command: "C:\\x.exe")
        }
        var reaper = WineOrphanReaper()
        #expect(reaper.confirm([orphan(1), orphan(2)]).isEmpty)
        #expect(reaper.confirm([orphan(2), orphan(3)]).map(\.pid) == [2])
        // A pass without 3 forgets it: the next sighting starts over.
        #expect(reaper.confirm([]).isEmpty)
        #expect(reaper.confirm([orphan(3)]).isEmpty)
    }
}
