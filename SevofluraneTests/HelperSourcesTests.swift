import Foundation
import Testing

/// Each target compiles whole folders, so where a file lives decides who
/// compiles it: `Core/` goes into the app, the helper and `sevo`, and
/// `Supervision/` into the app and the helper. Neither of those has a window
/// to draw in, so nothing in either folder may import a UI framework.
struct HelperSourcesTests {
    /// The repository root, from this file's own path — the tests run with a
    /// working directory of the harness's choosing.
    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every Swift file under the folders the helper and `sevo` compile,
    /// relative to the repository root.
    private static let helperFiles: [String] = ["Core", "Supervision"].flatMap { folder in
        let tree = root.appending(path: folder)
        guard let walk = FileManager.default.enumerator(
            at: tree, includingPropertiesForKeys: [.isRegularFileKey],
        ) else { return [String]() }
        return walk.compactMap { entry in
            guard let url = entry as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.pathExtension == "swift" else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        }
    }

    @Test
    func `the helper folders import nothing that draws`() {
        #expect(!Self.helperFiles.isEmpty)
        let drawing = ["import SwiftUI", "import WebKit", "import Propofol"]
        for file in Self.helperFiles.sorted() {
            let text = (try? String(contentsOf: Self.root.appending(path: file), encoding: .utf8)) ?? ""
            let imported = drawing.filter { text.contains($0 + "\n") }
            #expect(imported.isEmpty, "\(file) imports \(imported.joined(separator: ", "))")
        }
    }
}
