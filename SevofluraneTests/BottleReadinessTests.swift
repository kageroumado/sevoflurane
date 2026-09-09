import Foundation
import Testing
@testable import Sevoflurane

/// The record a failed setup pass leaves behind, and what it holds down.
/// These read and write nothing: the live suite is the one the running app
/// reads, and a test must never tell it the bottle failed to provision.
struct BottleReadinessTests {
    private func failure(
        engine: String = "Dormison r4", bottle: String = "Steam",
        blocksClientStart: Bool = true,
    ) -> BottleReadiness.ProvisionOutcome {
        BottleReadiness.ProvisionOutcome(
            succeeded: false, reason: "Steam installer failed (exit 1)", date: .now,
            engine: engine, bottle: bottle, blocksClientStart: blocksClientStart,
        )
    }

    @Test
    func `a failed installer holds the client down for that pair`() {
        let block = BottleReadiness.block(
            from: failure(), engine: "Dormison r4", bottle: "Steam",
        )
        #expect(block == "Steam installer failed (exit 1)")
    }

    /// The record names the pair it was made for: switching back to an engine
    /// and bottle that work must not inherit the other one's failure.
    @Test
    func `a failure recorded for another pair holds nothing down`() {
        #expect(BottleReadiness.block(
            from: failure(), engine: "CrossOver 26.3", bottle: "Steam",
        ) == nil)
        #expect(BottleReadiness.block(
            from: failure(), engine: "Dormison r4", bottle: "Steam Test",
        ) == nil)
    }

    @Test
    func `a failure the user overrode holds nothing down`() {
        #expect(BottleReadiness.block(
            from: failure(blocksClientStart: false),
            engine: "Dormison r4", bottle: "Steam",
        ) == nil)
    }

    @Test
    func `a finished pass holds nothing down`() {
        let done = BottleReadiness.ProvisionOutcome(
            succeeded: true, reason: "the bottle is complete", date: .now,
            engine: "Dormison r4", bottle: "Steam", blocksClientStart: false,
        )
        #expect(BottleReadiness.block(
            from: done, engine: "Dormison r4", bottle: "Steam",
        ) == nil)
        #expect(BottleReadiness.block(from: nil, engine: "e", bottle: "b") == nil)
    }

    @Test
    func `the record survives the trip through the preference suite`() {
        let outcome = failure()
        let read = BottleReadiness.outcome(from: BottleReadiness.stored(outcome))
        #expect(read?.succeeded == false)
        #expect(read?.reason == outcome.reason)
        #expect(read?.engine == "Dormison r4")
        #expect(read?.bottle == "Steam")
        #expect(read?.blocksClientStart == true)
        #expect(
            read.map { abs($0.date.timeIntervalSince(outcome.date)) < 0.001 } == true,
        )
        #expect(BottleReadiness.outcome(from: ["succeeded": true]) == nil)
    }

    @Test
    func `the incomplete sentence names what is missing`() {
        #expect(BottleReadiness.incompleteSummary(missing: []) == nil)
        #expect(
            BottleReadiness.incompleteSummary(missing: ["Core fonts"])
                == "Core fonts is required and not installed",
        )
        #expect(
            BottleReadiness.incompleteSummary(missing: ["Core fonts", "Direct3D shader compiler"])
                == "Core fonts and Direct3D shader compiler are required and not installed",
        )
    }

    /// Nothing is gated on the fonts and the legacy runtime: a bottle without
    /// them launches games, and a gate would have blocked the playtest that
    /// found this.
    @Test
    func `only the two runtimes are required`() {
        let required = BottleDependencies.catalog.filter(\.required).map(\.id)
        #expect(required == ["vcredist", "d3dcompiler"])
    }
}
