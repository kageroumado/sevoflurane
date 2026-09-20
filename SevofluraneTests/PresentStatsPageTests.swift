import Foundation
import Testing
@testable import Sevoflurane

/// The engine's stats page as bytes: the layout `struct sevo_stats_page` declares, with and
/// without the main-thread beat at its end.
struct PresentStatsPageTests {
    /// A page for this process, so it reads as alive.
    private func page(beatNanoseconds: UInt64?, length: Int) -> Data {
        var data = Data(count: length)
        func put(_ value: some FixedWidthInteger, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        put(UInt64(0x5345_564F_5354_5331), at: 0)
        put(UInt64(1200), at: 8)
        put(UInt64(5_000_000_000), at: 24)
        put(UInt64(1_000_000_000), at: 32)
        put(UInt32(1), at: 48)
        put(UInt32(getpid()), at: 52)
        put(UInt32(2), at: 56)
        put(UInt32(339_800), at: 60)
        if let beatNanoseconds { put(beatNanoseconds, at: 96) }
        return data
    }

    @Test
    func `a page with a beat says when the main thread last turned`() throws {
        let page = try #require(PresentStats.page(from: page(beatNanoseconds: 7_500_000_000, length: 4096)))
        #expect(page.frames == 1200)
        #expect(page.appid == 339_800)
        #expect(page.mainBeatUptime == 7.5)
    }

    @Test
    func `a page from an engine without the beat has no opinion, whatever its length`() throws {
        #expect(try #require(PresentStats.page(from: page(beatNanoseconds: nil, length: 4096))).mainBeatUptime == nil)
        #expect(try #require(PresentStats.page(from: page(beatNanoseconds: nil, length: 96))).mainBeatUptime == nil)
    }
}
