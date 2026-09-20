import Foundation
import Testing
@testable import Sevoflurane

/// When the process monitor says a game holds one core: every sample inside the band, for
/// as long as the rule asks, and one sample outside starts the count again.
struct OneCoreTests {
    @Test
    func `a share inside the band keeps the first moment it was seen there`() {
        let since = StallWatch.oneCoreSince(nil, share: 1.0, at: 100)
        #expect(since == 100)
        #expect(StallWatch.oneCoreSince(since, share: 0.98, at: 102) == 100)
    }

    @Test
    func `a game at work, over or under one core, starts the count again`() {
        #expect(StallWatch.oneCoreSince(100, share: 2.05, at: 102) == nil)
        #expect(StallWatch.oneCoreSince(100, share: 0.4, at: 102) == nil)
        #expect(StallWatch.oneCoreSince(100, share: 0, at: 102) == nil)
    }
}
