import Foundation
import Testing
@testable import Sevoflurane

/// The staging trees a CrossOver shadow build leaves beside the tree.
struct CrossOverShadowTests {
    @Test
    func `a staging tree another build is assembling is left alone, an abandoned one goes`() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossover-shadow-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let fresh = parent.appendingPathComponent("CrossOverShadow-\(UUID().uuidString)")
        let abandoned = parent.appendingPathComponent("CrossOverShadow-\(UUID().uuidString)")
        let tree = parent.appendingPathComponent("CrossOverShadow")
        for directory in [fresh, abandoned, tree] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let now = Date.now
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-CrossOverShadow.abandonedAfter - 60)],
            ofItemAtPath: abandoned.path,
        )

        CrossOverShadow.discardAbandonedStaging(in: parent, now: now)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: tree.path))
    }
}
