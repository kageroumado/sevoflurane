import Foundation
import Testing
@testable import Sevoflurane

/// What the app recognizes in a run record.
struct KnownFailuresTests {
    private static func record(
        runtime: String? = "unity",
        exit: RunRecord.Exit? = RunRecord.Exit(kind: .crash, code: 1),
        windowAfterSeconds: Double? = nil,
        notes: [String]? = nil,
    ) -> RunRecord {
        RunRecord(
            t: "2026-09-09T00:28:14Z",
            appid: 508_440,
            engine: "dormison-r4",
            renderer: "dxmt",
            runner: "wine",
            windows: "fixed",
            msync: true,
            runtime: runtime,
            macos: "26.5.2",
            windowAfterSeconds: windowAfterSeconds,
            exit: exit,
            notes: notes,
            host: RunRecord.Host(thermal: "nominal", load: 3.1),
        )
    }

    @Test
    func `a Unity player that exits 1 without drawing is recognized`() {
        #expect(KnownFailures.match(Self.record())?.id == "unity-exit-1-no-window")
    }

    @Test
    func `a Unity player that put a window up is a different story`() {
        #expect(KnownFailures.match(Self.record(windowAfterSeconds: 1.2)) == nil)
    }

    @Test
    func `Unreal's fatal-error status is recognized`() {
        let record = Self.record(
            runtime: "unreal", exit: RunRecord.Exit(kind: .crash, code: 3),
        )
        #expect(KnownFailures.match(record)?.id == "unreal-exit-3")
    }

    @Test
    func `a dropped compute dispatch outranks a cosmetic feature query`() {
        let record = Self.record(
            runtime: nil,
            exit: RunRecord.Exit(kind: .user, code: 0),
            notes: ["Not supported feature: 11", "Shader not found? ×16"],
        )
        #expect(KnownFailures.match(record)?.id == "dxmt-dropped-compute")
    }

    @Test
    func `the cosmetic feature query is recognized on its own, with no fix`() {
        let record = Self.record(
            runtime: nil,
            exit: RunRecord.Exit(kind: .user, code: 0),
            notes: ["Not supported feature: 11"],
        )
        let failure = KnownFailures.match(record)
        #expect(failure?.id == "dxmt-unsupported-feature")
        #expect(failure?.fix == nil)
    }

    @Test
    func `a run that ended normally with nothing said matches nothing`() {
        let record = Self.record(runtime: nil, exit: RunRecord.Exit(kind: .user, code: 0))
        #expect(KnownFailures.match(record) == nil)
    }
}
