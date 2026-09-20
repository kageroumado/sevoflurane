import Foundation
import Testing
@testable import Sevoflurane

/// What the Mac's load says, when it says it, and how much patience it buys.
struct HostPressureTests {
    @Test
    func `an ordinary Mac says nothing and changes no clock`() {
        let calm = HostPressure(otherProcessorShare: 0.3, temperature: 62)
        #expect(!calm.isElevated)
        #expect(calm.sentence == nil)
        #expect(calm.patience == 1)
    }

    @Test
    func `other apps taking half the processor double the clocks, and most of it triples them`() {
        let busy = HostPressure(otherProcessorShare: 0.55, busiestProcess: "xcodebuild")
        #expect(busy.patience == 2)
        #expect(busy.sentence == "Other apps have the CPU at 55%, mostly xcodebuild.")
        #expect(HostPressure(otherProcessorShare: 0.85).patience == 3)
    }

    @Test
    func `heat counts from the nineties or when macOS throttles, never at a game's ordinary warmth`() {
        #expect(!HostPressure(temperature: 84).isHot)
        #expect(HostPressure(temperature: 96).isHot)
        let throttled = HostPressure(temperature: 88, isThrottling: true)
        #expect(throttled.sentence == "The Mac is hot (88 °C) and macOS is slowing it down.")
        #expect(throttled.patience == 2)
    }

    @Test
    func `short memory and Low Power Mode are causes too, and the causes join`() {
        let pressure = HostPressure(otherProcessorShare: 0.6, memory: .critical, isLowPowerMode: true)
        #expect(pressure.patience == 3)
        #expect(pressure.sentence
            == "Other apps have the CPU at 60%; memory is critically short; Low Power Mode is on.")
    }

    @Test
    func `the gauge follows the busiest signal`() {
        #expect(HostPressure(otherProcessorShare: 0.3, temperature: 55).level == 0.3)
        #expect(HostPressure(otherProcessorShare: 0.2, temperature: 95).level == 0.9)
        #expect(HostPressure(memory: .critical).level == 1)
    }

    @Test
    func `readings that would be worded alike compare equal once rounded`() {
        let a = HostPressure(otherProcessorShare: 0.61, temperature: 96.2)
        let b = HostPressure(otherProcessorShare: 0.59, temperature: 94.9)
        #expect(a.rounded == b.rounded)
    }

    @Test
    func `the reading survives the link`() throws {
        let pressure = HostPressure(otherProcessorShare: 0.7, busiestProcess: "clang", memory: .warning, temperature: 91)
        let decoded = try JSONDecoder().decode(HostPressure.self, from: JSONEncoder().encode(pressure))
        #expect(decoded == pressure)
    }

    @Test
    func `the sampler's second reading is a share between zero and one, and this test host is not the bottle`() {
        let sampler = HostPressureSampler(ownRoots: [])
        _ = sampler.sample()
        let deadline = Date().addingTimeInterval(0.7)
        var spin = 0.0
        while Date() < deadline { spin += sin(spin + 1) }
        let second = sampler.sample()
        #expect(second.otherProcessorShare > 0)
        #expect(second.otherProcessorShare <= 1)
    }

    @Test
    func `a process's cpu time is in seconds that agree with getrusage`() throws {
        let deadline = Date().addingTimeInterval(0.3)
        var spin = 0.0
        while Date() < deadline { spin += sin(spin + 1) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let expected = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let read = try #require(ProcessUsage.read(pid: getpid())).cpuSeconds
        // Mach time units read as nanoseconds come out 42 times too small.
        #expect(read > expected * 0.7 && read < expected * 1.3, "\(read) s against getrusage's \(expected) s")
    }
}
