import Darwin
import Foundation
import Testing
@testable import Sevoflurane

/// The two meters a run carries beside its logs: what the kernel billed the
/// game's process, and whether macOS ran a Game Mode session during it.
///
/// The process facts are read against this test's own process and against a
/// `/bin/sleep` it starts, which is a real tree with a real parent — the same
/// calls the stall watchdog makes, against processes whose shape is known.
struct RunMetersTests {
    private let manager = FileManager.default

    // MARK: - The kernel's accounting

    @Test
    func `this process's usage carries cpu time, energy and a p-core share`() throws {
        let usage = try #require(ProcessUsage.read(pid: getpid()))
        #expect(usage.pid == getpid())
        #expect(usage.cpuTimeNanoseconds > 0)
        #expect(usage.cpuSeconds > 0)
        // Energy and instructions come off hardware performance counters, so
        // a virtualized Mac reports neither: assert they are read together
        // rather than asserting this host has the counters.
        #expect((usage.energyNanojoules > 0) == (usage.instructions > 0))
        #expect(usage.footprintBytes > 0)
        #expect(usage.startAbsoluteTime > 0)
        #expect(usage.pCoreShare >= 0 && usage.pCoreShare <= 1)
    }

    @Test
    func `cpu time grows between two readings of a process that is working`() throws {
        let first = try #require(ProcessUsage.read(pid: getpid()))
        var sum = 0
        for value in 0 ..< 2_000_000 { sum &+= value }
        #expect(sum != 0)
        let second = try #require(ProcessUsage.read(pid: getpid()))
        #expect(second.cpuTimeNanoseconds > first.cpuTimeNanoseconds)
    }

    @Test
    func `a pid nothing is running has no usage to read`() {
        // The kernel's own maximum plus one: no process can hold it.
        #expect(ProcessUsage.read(pid: pid_t.max) == nil)
        #expect(!ProcessUsage.exists(pid: pid_t.max))
    }

    @Test
    func `a share with no cpu time is zero rather than a division by it`() {
        let usage = ProcessUsage(
            pid: 1, cpuTimeNanoseconds: 0, pCoreTimeNanoseconds: 0, footprintBytes: 0,
            energyNanojoules: 0, instructions: 0, startAbsoluteTime: 0,
        )
        #expect(usage.pCoreShare == 0)
    }

    /// `ri_user_ptime` counts performance-core time, which the kernel bills
    /// separately from the total; a share over one would mean the two came
    /// from different accounts.
    @Test
    func `a p-core time larger than the total still reads as a full share`() {
        let usage = ProcessUsage(
            pid: 1, cpuTimeNanoseconds: 100, pCoreTimeNanoseconds: 400, footprintBytes: 0,
            energyNanojoules: 0, instructions: 0, startAbsoluteTime: 0,
        )
        #expect(usage.pCoreShare == 1)
    }

    // MARK: - A real process tree

    @Test
    func `a child process is in this process's tree, named, and stoppable`() async throws {
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let pid = child.processIdentifier

        #expect(ProcessUsage.children(of: getpid()).contains(pid))
        #expect(ProcessUsage.tree(under: [getpid()]).contains(pid))
        #expect(ProcessUsage.tree(under: [getpid()]).first == getpid())
        #expect(ProcessUsage.parent(of: pid) == getpid())
        #expect(ProcessUsage.name(of: pid) == "sleep")
        #expect(ProcessUsage.exists(pid: pid))
        #expect(!ProcessUsage.isStopped(pid: pid))

        kill(pid, SIGSTOP)
        try await stopped(pid, is: true)
        kill(pid, SIGCONT)
        try await stopped(pid, is: false)
    }

    /// The process state moves when the kernel delivers the signal, not when
    /// `kill` returns.
    private func stopped(_ pid: pid_t, is wanted: Bool) async throws {
        for _ in 0 ..< 100 {
            if ProcessUsage.isStopped(pid: pid) == wanted { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ProcessUsage.isStopped(pid: pid) == wanted)
    }

    @Test
    func `a tree walked from two roots that share a child lists it once`() {
        let tree = ProcessUsage.tree(under: [getpid(), getpid()])
        #expect(tree.count == Set(tree).count)
    }

    // MARK: - Game Mode

    /// The notification is registered once and read by state rather than by
    /// callback; whether a session happens to be in force on this Mac is not
    /// something a test can arrange.
    @Test
    func `the game mode session reads without a session in force`() {
        let first = GameModeSignal.isActive()
        #expect(GameModeSignal.isActive() == first)
        #expect(GameModeSignal.notification == "com.apple.gamepolicy.game-mode-session")
    }

    // MARK: - What the record keeps

    @Test
    func `energy rounds the p-core share to two decimals`() {
        let usage = ProcessUsage(
            pid: 1, cpuTimeNanoseconds: 300, pCoreTimeNanoseconds: 100, footprintBytes: 0,
            energyNanojoules: 4096, instructions: 512, startAbsoluteTime: 0,
        )
        let energy = RunRecord.Energy(usage)
        #expect(energy.nanojoules == 4096)
        #expect(energy.instructions == 512)
        #expect(energy.pCoreShare == 0.33)
    }

    @Test
    func `energy and game mode are the keys the diagnostics plan names`() throws {
        var record = Self.record()
        record.gameMode = true
        record.energy = RunRecord.Energy(nanojoules: 12, instructions: 34, pCoreShare: 0.5)
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any],
        )
        #expect(json["game_mode"] as? Bool == true)
        let energy = try #require(json["energy"] as? [String: Any])
        #expect(energy["nj"] as? Int == 12)
        #expect(energy["instructions"] as? Int == 34)
        #expect(energy["p_core_share"] as? Double == 0.5)
    }

    @Test
    func `a record with no meters read leaves both keys out`() throws {
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.record()))
                as? [String: Any],
        )
        #expect(json["game_mode"] == nil)
        #expect(json["energy"] == nil)
    }

    // MARK: - The recorder's own sampling

    @Test
    func `a sampled run carries the meters of the process it was given`() async throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let recorder = try makeRecorder(in: root)
        recorder.arm(appID: 367_520)
        // This test's own process stands in for the game's: it is alive, it
        // has been billed, and its pid is one the recorder can read.
        recorder.noteExecutable("hollow_knight.exe", pid: getpid(), forApp: 367_520)
        recorder.sample()
        recorder.close(appID: 367_520)

        let record = try #require(await records(in: root, waitingFor: 1).first)
        let energy = try #require(record.energy)
        if try #require(ProcessUsage.read(pid: getpid())).energyNanojoules > 0 {
            #expect(energy.nanojoules > 0)
            #expect(energy.instructions > 0)
        }
        #expect(record.gameMode != nil)
    }

    @Test
    func `a run whose process was never named keeps no energy`() async throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let recorder = try makeRecorder(in: root)
        recorder.arm(appID: 367_520)
        recorder.sample()
        recorder.close(appID: 367_520)

        let record = try #require(await records(in: root, waitingFor: 1).first)
        #expect(record.energy == nil)
        // Sampled without a process to read: the session is still known.
        #expect(record.gameMode != nil)
    }

    @Test
    func `sampling a recorder with nothing open touches nothing`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        try makeRecorder(in: root).sample()
        #expect(RunLog.armedRuns(in: root).isEmpty)
        #expect(RunLog.records(inMonth: .now, in: root).isEmpty)
    }

    // MARK: - Scratch

    private static func record() -> RunRecord {
        RunRecord(
            t: "2026-09-18T00:28:14Z", appid: 367_520, engine: "dormison-r11",
            renderer: "dxmt", runner: "wine", windows: "fixed", msync: true,
            macos: "27.0.0", host: RunRecord.Host(thermal: "nominal", load: 1.0),
        )
    }

    private func scratch() throws -> URL {
        let url = manager.temporaryDirectory
            .appendingPathComponent("run-meters-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRecorder(in root: URL) throws -> RunRecorder {
        let wine = root.appendingPathComponent("wine.log")
        if !manager.fileExists(atPath: wine.path) { try Data().write(to: wine) }
        return RunRecorder(
            runs: root, wineLog: wine,
            processLog: root.appendingPathComponent("gameprocess_log.txt"),
        )
    }

    /// The record write leaves the caller's thread, so a test waits for it.
    private func records(in root: URL, waitingFor count: Int) async -> [RunRecord] {
        for _ in 0 ..< 100 {
            let records = RunLog.records(inMonth: .now, in: root)
            if records.count >= count { return records }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return RunLog.records(inMonth: .now, in: root)
    }
}
