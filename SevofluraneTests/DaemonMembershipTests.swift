import Foundation
import Testing

/// Three targets compile one source tree: the app, and `sevo` and
/// `SevofluraneDaemon`, each of which takes the app's folder minus an
/// exception list in the Xcode project.
///
/// Two lists that have to agree are a list that drifts, so these are the
/// assertions that make the disagreement fail a build rather than a playtest:
/// the daemon compiles everything `sevo` does, and it compiles nothing that
/// draws.
struct DaemonMembershipTests {
    /// The repository root, from this file's own path — the tests run with a
    /// working directory of the harness's choosing.
    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// What a target leaves out of the app's synchronized group, as paths
    /// relative to `Sevoflurane/`.
    private static func exceptions(for target: String) -> Set<String> {
        let text = (try? String(
            contentsOf: root.appending(path: "Sevoflurane.xcodeproj/project.pbxproj"),
            encoding: .utf8,
        )) ?? ""
        guard let start = text.range(
            of: "Exceptions for \"Sevoflurane\" folder in \"\(target)\" target */ = {",
        ),
            let listStart = text.range(of: "membershipExceptions = (", range: start.upperBound ..< text.endIndex),
            let listEnd = text.range(of: ");", range: listStart.upperBound ..< text.endIndex)
        else { return [] }
        return Set(
            text[listStart.upperBound ..< listEnd.lowerBound]
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasSuffix(",") }
                // The project file quotes a path holding anything outside its
                // bare-word characters, a `+` among them.
                .map { $0.dropLast().trimmingCharacters(in: ["\""]) },
        )
    }

    private static let daemonExceptions = exceptions(for: "SevofluraneDaemon")
    private static let cliExceptions = exceptions(for: "sevo")

    /// Every file under `Sevoflurane/`, relative to it — the universe both
    /// lists partition.
    private static let appTreeFiles: [String] = {
        let tree = root.appending(path: "Sevoflurane")
        guard let walk = FileManager.default.enumerator(
            at: tree, includingPropertiesForKeys: [.isRegularFileKey],
        ) else { return [] }
        return walk.compactMap { entry in
            guard let url = entry as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.pathExtension == "swift" else { return nil }
            return String(url.path.dropFirst(tree.path.count + 1))
        }
    }()

    private static func compiled(_ relativePath: String, despite exceptions: Set<String>) -> Bool {
        !exceptions.contains { exception in
            relativePath == exception || relativePath.hasPrefix(exception + "/")
        }
    }

    private func compiledByDaemon(_ relativePath: String) -> Bool {
        Self.compiled(relativePath, despite: Self.daemonExceptions)
    }

    @Test
    func `the daemon compiles everything the CLI compiles`() {
        #expect(!Self.cliExceptions.isEmpty)
        let cliSources = Self.appTreeFiles.filter { Self.compiled($0, despite: Self.cliExceptions) }
        #expect(!cliSources.isEmpty)
        for source in cliSources.sorted() {
            #expect(
                compiledByDaemon(source),
                "the daemon excludes \(source), which sevo compiles",
            )
        }
    }

    @Test
    func `the daemon compiles nothing that draws`() {
        #expect(!Self.appTreeFiles.isEmpty)
        let drawing = ["import SwiftUI", "import WebKit", "import Propofol"]
        for file in Self.appTreeFiles.sorted() where compiledByDaemon(file) {
            let text = (try? String(
                contentsOf: Self.root.appending(path: "Sevoflurane/\(file)"), encoding: .utf8,
            )) ?? ""
            let imported = drawing.filter { text.contains($0 + "\n") }
            #expect(
                imported.isEmpty,
                "the daemon compiles \(file), which imports \(imported.joined(separator: ", "))",
            )
        }
    }
}
