import Foundation
import Testing
@testable import Sevoflurane

/// The Storage pane's bar: which entries earn a color of their own, what is
/// folded together, and how the rest of the volume is accounted for.
@MainActor
struct StorageBreakdownTests {
    private static let gigabyte: Int64 = 1_000_000_000

    private func entry(_ id: String, gigabytes: Int64) -> StorageInventory.Entry {
        StorageInventory.Entry(
            id: id, name: id.capitalized, detail: "",
            url: URL(fileURLWithPath: "/demo/\(id)"),
            bytes: gigabytes < 0 ? gigabytes : gigabytes * Self.gigabyte,
            removal: nil,
        )
    }

    @Test
    func `the four largest entries are ranked, largest first`() {
        let entries = [
            entry("logs", gigabytes: 1), entry("games", gigabytes: 200), entry("bottle", gigabytes: 3),
            entry("client", gigabytes: 20), entry("engines", gigabytes: 7), entry("caches", gigabytes: 2),
        ]
        let breakdown = StorageBreakdown.make(
            entries: entries, volumeUsed: 600 * Self.gigabyte, volumeTotal: 1000 * Self.gigabyte,
        )
        #expect(breakdown.segments.prefix(4).map(\.id) == ["games", "client", "engines", "bottle"])
        #expect(breakdown.segments.prefix(4).map(\.kind) == (0 ..< 4).map { .entry(rank: $0) })
    }

    @Test
    func `the entries past the ranked ones are one grouped segment`() throws {
        let entries = [
            entry("games", gigabytes: 200), entry("client", gigabytes: 20), entry("engines", gigabytes: 7),
            entry("bottle", gigabytes: 3), entry("caches", gigabytes: 2), entry("logs", gigabytes: 1),
        ]
        let breakdown = StorageBreakdown.make(
            entries: entries, volumeUsed: 600 * Self.gigabyte, volumeTotal: 1000 * Self.gigabyte,
        )
        let grouped = try #require(breakdown.segments.first { $0.kind == .grouped })
        #expect(grouped.bytes == 3 * Self.gigabyte)
        #expect(grouped.name == "Other Sevoflurane data")
        #expect(breakdown.kind(of: entries[4]) == .grouped)
        #expect(breakdown.kind(of: entries[5]) == .grouped)
        #expect(breakdown.kind(of: entries[0]) == .entry(rank: 0))
    }

    @Test
    func `other is the volume's used bytes less everything of ours`() throws {
        let entries = [entry("games", gigabytes: 200), entry("client", gigabytes: 20)]
        let breakdown = StorageBreakdown.make(
            entries: entries, volumeUsed: 600 * Self.gigabyte, volumeTotal: 1000 * Self.gigabyte,
        )
        let other = try #require(breakdown.segments.last)
        #expect(other.kind == .other)
        #expect(other.bytes == 380 * Self.gigabyte)
        #expect(breakdown.available == 400 * Self.gigabyte)
        #expect(breakdown.capacity == 1000 * Self.gigabyte)
    }

    @Test
    func `other never goes negative when linked games pass the volume's used figure`() {
        let breakdown = StorageBreakdown.make(
            entries: [entry("games", gigabytes: 700)],
            volumeUsed: 600 * Self.gigabyte, volumeTotal: 1000 * Self.gigabyte,
        )
        #expect(breakdown.segments.map(\.id) == ["games"])
        #expect(breakdown.segments.allSatisfy { $0.bytes > 0 })
    }

    @Test
    func `empty and unmeasured entries take no part`() {
        let entries = [
            entry("games", gigabytes: -1), entry("client", gigabytes: 0), entry("engines", gigabytes: 7),
        ]
        let breakdown = StorageBreakdown.make(
            entries: entries, volumeUsed: 600 * Self.gigabyte, volumeTotal: 1000 * Self.gigabyte,
        )
        #expect(breakdown.segments.map(\.id) == ["engines", StorageBreakdown.otherID])
        #expect(breakdown.segments.last?.bytes == 593 * Self.gigabyte)
        #expect(breakdown.kind(of: entries[0]) == nil)
        #expect(breakdown.kind(of: entries[1]) == nil)
    }

    @Test
    func `four entries or fewer leave no grouped segment`() {
        let entries = (1 ... 4).map { entry("entry\($0)", gigabytes: Int64($0)) }
        let breakdown = StorageBreakdown.make(
            entries: entries, volumeUsed: 600 * Self.gigabyte, volumeTotal: 1000 * Self.gigabyte,
        )
        #expect(!breakdown.segments.contains { $0.kind == .grouped })
    }

    // MARK: - Bar geometry

    @Test
    func `a segment takes its share of the bar's width`() {
        let widths = StorageCapacityBar.widths(of: [250, 500], capacity: 1000, in: 400)
        #expect(widths == [100, 200])
    }

    @Test
    func `a sliver of an entry still draws at the minimum width`() {
        let widths = StorageCapacityBar.widths(of: [1, 500_000], capacity: 1_000_000, in: 400)
        #expect(widths[0] == StorageCapacityBar.Metrics.minimumSegmentWidth)
    }

    @Test
    func `segments that fill the volume stay inside the bar, gaps included`() {
        let bytes: [Int64] = [1, 1, 499_999, 499_999]
        let widths = StorageCapacityBar.widths(of: bytes, capacity: 1_000_000, in: 400)
        let drawn = widths.reduce(0, +) + StorageCapacityBar.Metrics.gap * CGFloat(bytes.count)
        #expect(drawn <= 400 + 0.001)
        #expect(widths.allSatisfy { $0 >= StorageCapacityBar.Metrics.minimumSegmentWidth })
    }
}

/// What the Storage pane may reclaim while the bottle runs.
struct StorageReclaimTests {
    private func entry(_ id: String) -> StorageInventory.Entry {
        StorageInventory.Entry(
            id: id, name: id, detail: "", url: URL(fileURLWithPath: "/demo/\(id)"), bytes: 0,
            removal: .regenerated(""),
        )
    }

    @Test
    func `what the running bottle reads is refused until it stops`() {
        for id in ["caches", "engines", "renderers", "toolkits"] {
            #expect(StorageInventory.isRefused(entry(id), bottleRunning: true))
            #expect(!StorageInventory.isRefused(entry(id), bottleRunning: false))
        }
    }

    @Test
    func `logs and shader downloads are reclaimed while it runs`() {
        #expect(!StorageInventory.isRefused(entry("logs"), bottleRunning: true))
        #expect(!StorageInventory.isRefused(entry("shaders"), bottleRunning: true))
    }
}
