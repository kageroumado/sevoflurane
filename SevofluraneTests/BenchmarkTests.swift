import Foundation
import Testing
@testable import Sevoflurane

struct BenchmarkOptionTests {
    @Test
    func `defaults when the query is empty`() {
        let options = SteamWebHost.BenchmarkOptions(query: "")
        #expect(options.iterations == 5)
        #expect(options.target == nil)
        #expect(options.loadThreads == 0)
        #expect(options.loadQualityOfService == .default)
    }

    @Test
    func `parses every field and clamps iterations`() {
        let options = SteamWebHost.BenchmarkOptions(
            query: "iterations=40&target=store&load=6&qos=userInitiated",
        )
        #expect(options.iterations == 10)
        #expect(options.target == "store")
        #expect(options.loadThreads == 6)
        #expect(options.loadQualityOfService == .userInitiated)
    }

    @Test
    func `rejects nonsense without failing`() {
        let options = SteamWebHost.BenchmarkOptions(query: "iterations=x&load=-3&qos=turbo&junk")
        #expect(options.iterations == 5)
        #expect(options.loadThreads == 0)
        #expect(options.loadQualityOfService == .default)
    }
}

struct MainQueueLatencyProbeTests {
    @Test
    func `accounts stalls and resets per snapshot`() {
        let probe = MainQueueLatencyProbe()
        probe.record(delay: .milliseconds(2))
        probe.record(delay: .milliseconds(80))
        probe.record(delay: .milliseconds(120))
        let first = probe.snapshotAndReset()
        #expect(first.pings == 3)
        #expect(first.maxDelayMilliseconds == 120)
        #expect(first.stallsOverThreshold == 2)
        #expect(first.stalledMilliseconds == 200)

        let second = probe.snapshotAndReset()
        #expect(second.pings == 0)
        #expect(second.maxDelayMilliseconds == 0)
        #expect(second.stallsOverThreshold == 0)
    }

    @Test
    func `a delay at the threshold counts as a stall`() {
        let probe = MainQueueLatencyProbe()
        probe.record(delay: MainQueueLatencyProbe.stallThreshold)
        #expect(probe.snapshotAndReset().stallsOverThreshold == 1)
    }
}

struct SyntheticLoadTests {
    @Test
    func `threads start and stop within the deadline`() {
        let load = SyntheticLoad(threads: 2, qualityOfService: .utility)
        #expect(load.threadCount == 2)
        load.start()
        let clock = ContinuousClock()
        let started = clock.now
        load.stop()
        #expect(started.duration(to: clock.now) < .seconds(2))
    }

    @Test
    func `thread count is capped at twice the core count`() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        #expect(SyntheticLoad(threads: cores * 10).threadCount == cores * 2)
        #expect(SyntheticLoad(threads: -1).threadCount == 0)
    }
}

struct HostSnapshotTests {
    @Test
    func `reports plausible figures`() {
        let snapshot = HostSnapshot.take()
        #expect(snapshot.activeProcessors > 0)
        #expect(snapshot.physicalMemoryMB > 1024)
        #expect(snapshot.freeMemoryMB + snapshot.compressedMemoryMB > 0)
        #expect(snapshot.compressedMemoryMB < snapshot.physicalMemoryMB)
        #expect(snapshot.loadAverage1m >= 0)
        #expect(["nominal", "fair", "serious", "critical", "unknown"].contains(snapshot.thermalState))
    }
}
