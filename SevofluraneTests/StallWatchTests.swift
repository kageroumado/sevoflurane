import Foundation
import Testing
@testable import Sevoflurane

/// The stall watchdog, driven against a process tree that exists only in this
/// test: a clock that jumps, CPU counters that stop, a `SIGSTOP` that is not
/// one, and a game whose frames nothing counts.
///
/// Every rung of the ladder is checked by what it signalled, because the
/// signals are the only thing about the ladder that a person would notice.
@MainActor
struct StallWatchTests {
    /// A fake bottle: processes with CPU counters a test moves by hand.
    final class Machine: @unchecked Sendable {
        var cpuNanoseconds: [pid_t: UInt64] = [:]
        var stopped: Set<pid_t> = []
        var children: [pid_t: [pid_t]] = [:]
        var names: [pid_t: String] = [:]
        var presents: [pid_t: UInt64] = [:]
        var mainThreadSilence: [pid_t: TimeInterval] = [:]
        var signals: [(pid: pid_t, signal: Int32)] = []
        var lines: [String] = []
        var now: TimeInterval = 1000

        func probes() -> StallWatch.Probes {
            var probes = StallWatch.Probes()
            probes.usage = { [self] pid in
                guard let cpu = cpuNanoseconds[pid] else { return nil }
                return ProcessUsage(
                    pid: pid, cpuTimeNanoseconds: cpu, pCoreTimeNanoseconds: cpu,
                    footprintBytes: 1 << 20, energyNanojoules: 0, instructions: 0,
                    startAbsoluteTime: 0,
                )
            }
            probes.isStopped = { [self] in stopped.contains($0) }
            probes.children = { [self] in children[$0] ?? [] }
            probes.name = { [self] in names[$0] }
            probes.presents = { [self] in presents[$0] }
            probes.mainThreadSilence = { [self] in mainThreadSilence[$0] }
            probes.signal = { [self] pid, signal in
                signals.append((pid, signal))
                if signal == SIGCONT { stopped.remove(pid) }
                if signal == SIGKILL { cpuNanoseconds[pid] = nil }
            }
            probes.now = { [self] in now }
            probes.log = { [self] in lines.append($0) }
            return probes
        }

        /// Moves the clock on and burns `cpu` nanoseconds on each of `busy`.
        func advance(_ seconds: TimeInterval, busy: [pid_t] = []) {
            now += seconds
            for pid in busy {
                cpuNanoseconds[pid, default: 0] += UInt64(seconds * 1e9)
            }
        }
    }

    /// A recorder writing into a scratch directory, with one run armed and
    /// its process named — the shape the watchdog reads.
    private func recorder(in root: URL, appID: Int, pid: pid_t) throws -> RunRecorder {
        let wine = root.appendingPathComponent("wine.log")
        try Data().write(to: wine)
        let recorder = RunRecorder(
            runs: root, wineLog: wine,
            processLog: root.appendingPathComponent("gameprocess_log.txt"),
        )
        recorder.arm(appID: appID)
        recorder.noteExecutable("game.exe", pid: pid, forApp: appID)
        return recorder
    }

    /// An empty chronicle. The watch's tail opens at the file's end, the way
    /// it does on a running Mac, so its lines are appended after the watch
    /// exists rather than before.
    private func chronicle(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("Sevoflurane-windows.log")
        try Data().write(to: url)
        return url
    }

    /// A chronicle line as the dock shim writes it, naming one bottle
    /// process's Unix pid and Windows executable.
    private func arm(_ processes: [(pid: pid_t, exe: String)], in url: URL) throws {
        let text = processes.map { process in
            "03:12:45.123 armed pid=\(process.pid) \(process.exe)  \"\" 0x0"
        }.joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stall-watch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Judging

    @Test
    func `a busy game whose main thread went silent is not answering, said once, and killed only at the user's word`()
        throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0]
        machine.names = [900: "game.exe"]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        watch.recorder = try recorder(in: root, appID: 480, pid: 900)
        var reported: [StallWatch.Process] = []
        watch.onNotAnswering = { reported.append($0) }

        watch.sample()
        machine.advance(2, busy: [900])
        machine.mainThreadSilence[900] = 1
        watch.sample()
        #expect(watch.processes.first?.state == .running)

        // Still burning a core, which is why the stall ladder would leave it alone.
        machine.advance(2, busy: [900])
        machine.mainThreadSilence[900] = StallWatch.Rules.notAnsweringAfter
        watch.sample()
        machine.advance(2, busy: [900])
        watch.sample()
        #expect(watch.processes.first?.state == .notAnswering)
        #expect(reported.map(\.pid) == [900])
        #expect(machine.signals.isEmpty)

        watch.end(reported[0])
        #expect(machine.signals.contains { $0.pid == 900 && $0.signal == SIGKILL })
    }

    @Test
    func `an engine that writes no beat has no opinion`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0]
        machine.names = [900: "game.exe"]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        watch.recorder = try recorder(in: root, appID: 480, pid: 900)
        watch.sample()
        machine.advance(60, busy: [900])
        watch.sample()
        #expect(watch.processes.first?.state == .running)
    }

    @Test
    func `a busy process is running and a quiet one only goes stalled after fifteen seconds`()
        throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0]
        machine.names = [900: "game.exe"]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        watch.recorder = try recorder(in: root, appID: 480, pid: 900)

        watch.sample()
        machine.advance(2, busy: [900])
        watch.sample()
        #expect(watch.processes.first?.state == .running)
        #expect(watch.processes.first?.cpuShare ?? 0 > 0.9)

        // Quiet, but not for long enough to be anything but idle.
        machine.advance(4)
        watch.sample()
        #expect(watch.processes.first?.state == .idle)

        machine.advance(StallWatch.Rules.candidateAfter)
        watch.sample()
        #expect(watch.processes.first?.state == .stalled)
    }

    @Test
    func `a stopped process is stopped, never stalled`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0]
        machine.names = [900: "game.exe"]
        machine.stopped = [900]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        watch.recorder = try recorder(in: root, appID: 480, pid: 900)

        watch.sample()
        machine.advance(60)
        watch.sample()
        #expect(watch.processes.first?.state == .stopped)
    }

    @Test
    func `a process that only presents counts as moving`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0]
        machine.names = [900: "game.exe"]
        machine.presents = [900: 0]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        watch.recorder = try recorder(in: root, appID: 480, pid: 900)

        watch.sample()
        for _ in 0 ..< 12 {
            machine.advance(2)
            machine.presents[900, default: 0] += 120
            watch.sample()
        }
        #expect(watch.processes.first?.state == .running)
    }

    // MARK: - The ladder

    @Test
    func `a stalled tree with a stopped process in it is continued, not killed`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0, 901: 0]
        machine.names = [900: "game.exe", 901: "helper.exe"]
        machine.children = [900: [901]]
        machine.stopped = [901]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        let recorder = try recorder(in: root, appID: 480, pid: 900)
        watch.recorder = recorder

        watch.sample()
        machine.advance(StallWatch.Rules.candidateAfter + 2)
        watch.sample()

        #expect(machine.signals.contains { $0.signal == SIGCONT && $0.pid == 900 })
        #expect(machine.signals.contains { $0.signal == SIGCONT && $0.pid == 901 })
        #expect(!machine.signals.contains { $0.signal == SIGKILL })
        // And the run record says what was done about it.
        let stalls = try #require(RunLog.armedRuns(in: root).first?.record.stalls)
        #expect(stalls.contains { $0.unwedged == "sigcont" })
    }

    @Test
    func `a game nothing counts frames for is named and left alone`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0]
        machine.names = [900: "game.exe"]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        watch.recorder = try recorder(in: root, appID: 480, pid: 900)

        watch.sample()
        machine.advance(StallWatch.Rules.candidateAfter + 2)
        watch.sample()
        machine.advance(StallWatch.Rules.killAfter + 2)
        watch.sample()

        #expect(!machine.signals.contains { $0.signal == SIGKILL })
        #expect(machine.lines.contains { $0.contains("nothing counts its frames") })
        #expect(!StallWatch.killsOnCPUAlone)
    }

    @Test
    func `a game whose frames stopped is killed and its run ends as a watchdog kill`()
        async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0, 901: 0]
        machine.names = [900: "game.exe", 901: "child.exe"]
        machine.children = [900: [901]]
        // The counter exists and has stopped moving, which is the evidence the
        // kill rung waits for.
        machine.presents = [900: 4242]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        let recorder = try recorder(in: root, appID: 480, pid: 900)
        watch.recorder = recorder

        watch.sample()
        machine.advance(StallWatch.Rules.candidateAfter + 2)
        watch.sample()
        machine.advance(StallWatch.Rules.killAfter + 2)
        watch.sample()

        #expect(machine.signals.contains { $0.signal == SIGKILL && $0.pid == 900 })
        #expect(machine.signals.contains { $0.signal == SIGKILL && $0.pid == 901 })

        let record = try #require(await records(in: root, waitingFor: 1).first)
        #expect(record.exit?.kind == .watchdog)
        let stalls = try #require(record.stalls)
        #expect(stalls.contains { $0.unwedged == "sigkill" })
        // The rung is placed in the run, not at its end.
        #expect(stalls.allSatisfy { $0.at >= 0 })
    }

    @Test
    func `a quiet client process is left alone`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [800: 0]
        let log = try chronicle(in: root)
        let watch = StallWatch(probes: machine.probes(), chronicleURL: log)
        try arm([(800, "steamwebhelper.exe")], in: log)
        watch.recorder = try recorder(in: root, appID: 480, pid: 900)

        watch.sample()
        machine.advance(StallWatch.Rules.candidateAfter + StallWatch.Rules.killAfter + 4)
        watch.sample()
        machine.advance(4)
        watch.sample()

        #expect(machine.signals.isEmpty)
    }

    @Test
    func `a quiet helper is left alone`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [700: 0]
        machine.presents = [700: 0]
        let log = try chronicle(in: root)
        let watch = StallWatch(probes: machine.probes(), chronicleURL: log)
        try arm([(700, "services.exe")], in: log)
        watch.recorder = try recorder(in: root, appID: 480, pid: 900)

        watch.sample()
        machine.advance(120)
        watch.sample()
        #expect(watch.processes.first?.role == .helper)
        #expect(machine.signals.isEmpty)
    }

    // MARK: - A process the client lost

    @Test
    func `a run whose process vanished with no word from the client closes after the grace`()
        async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0]
        machine.names = [900: "game.exe"]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        let recorder = try recorder(in: root, appID: 480, pid: 900)
        watch.recorder = recorder
        var ended: [Int] = []
        watch.onGameProcessGone = { ended.append($0) }

        watch.sample()
        machine.cpuNanoseconds[900] = nil
        machine.advance(2)
        watch.sample()
        #expect(ended.isEmpty)
        #expect(recorder.isRecording)

        machine.advance(StallWatch.Rules.clientStopGrace)
        watch.sample()
        #expect(ended == [480])
        #expect(!recorder.isRecording)
        #expect(machine.lines.contains { $0.contains("gone") })
        let record = try #require(await records(in: root, waitingFor: 1).first)
        #expect(record.exit?.kind == .user)

        // Said once: the run is closed, and nothing is left to end again.
        machine.advance(2)
        watch.sample()
        #expect(ended == [480])
    }

    @Test
    func `a run the engine says was ended while not responding keeps that ending`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0]
        machine.names = [900: "game.exe"]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        watch.recorder = try recorder(in: root, appID: 480, pid: 900)
        watch.onGameProcessGone = { _ in }

        watch.sample()
        try Data("sevo:exit pid=900 ended by the user while not responding\n".utf8)
            .write(to: root.appendingPathComponent("wine.log"))
        machine.cpuNanoseconds[900] = nil
        machine.advance(2)
        watch.sample()
        machine.advance(StallWatch.Rules.clientStopGrace)
        watch.sample()

        let record = try #require(await records(in: root, waitingFor: 1).first)
        #expect(record.exit?.kind == .endedNotResponding)
    }

    @Test
    func `the client's own stop edge inside the grace wins`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [900: 0]
        machine.names = [900: "game.exe"]
        let watch = try StallWatch(probes: machine.probes(), chronicleURL: chronicle(in: root))
        let recorder = try recorder(in: root, appID: 480, pid: 900)
        watch.recorder = recorder
        var ended: [Int] = []
        watch.onGameProcessGone = { ended.append($0) }

        watch.sample()
        machine.cpuNanoseconds[900] = nil
        machine.advance(2)
        watch.sample()
        recorder.noteStopped(appID: 480)
        machine.advance(StallWatch.Rules.clientStopGrace)
        watch.sample()
        #expect(ended.isEmpty)
        #expect(!machine.lines.contains { $0.contains("gone") })
    }

    // MARK: - Roles

    @Test
    func `each process is named for what it is to us`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine()
        machine.cpuNanoseconds = [800: 0, 700: 0, 900: 0, 901: 0]
        machine.names = [901: "wineserver"]
        machine.children = [900: [901]]
        let log = try chronicle(in: root)
        let watch = StallWatch(probes: machine.probes(), chronicleURL: log)
        try arm([
            (800, "steamwebhelper.exe"), (700, "winedevice.exe"), (900, "game.exe"),
        ], in: log)
        watch.recorder = try recorder(in: root, appID: 480, pid: 900)

        watch.sample()
        let byPID = Dictionary(uniqueKeysWithValues: watch.processes.map { ($0.pid, $0.role) })
        #expect(byPID[800] == .client)
        #expect(byPID[700] == .helper)
        #expect(byPID[900] == .game)
        // The recorder named 900 as the run's; 901 is under it and is not.
        #expect(byPID[901] == .driver)
        #expect(watch.processes.first { $0.pid == 900 }?.appID == 480)
    }

    // MARK: - Scratch

    private func records(in root: URL, waitingFor count: Int) async -> [RunRecord] {
        for _ in 0 ..< 100 {
            let records = RunLog.records(inMonth: .now, in: root)
            if records.count >= count { return records }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return RunLog.records(inMonth: .now, in: root)
    }
}
