import Foundation
import Testing

/// Three build products compile one source tree: the app from the Xcode
/// project, `sevo` from `Package.swift`, and `SevofluraneDaemon` from the
/// Xcode project again with an exception list saying what it leaves out.
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

    /// The app sources `sevo` compiles, as `Package.swift` lists them.
    private static let cliSources: Set<String> = {
        let text = (try? String(
            contentsOf: root.appending(path: "Package.swift"), encoding: .utf8,
        )) ?? ""
        guard let start = text.range(of: "sources: ["),
              let end = text.range(of: "],\n            swiftSettings") else { return [] }
        return Set(
            text[start.upperBound ..< end.lowerBound]
                .split(separator: "\n")
                .compactMap { line in
                    let quoted = line.split(separator: "\"")
                    guard quoted.count > 1 else { return nil }
                    let path = String(quoted[1])
                    return path.hasPrefix("Sevoflurane/") ? path : nil
                },
        )
    }()

    /// What the daemon target leaves out of the app's synchronized group,
    /// as paths relative to `Sevoflurane/`.
    private static let daemonExceptions: Set<String> = {
        let text = (try? String(
            contentsOf: root.appending(path: "Sevoflurane.xcodeproj/project.pbxproj"),
            encoding: .utf8,
        )) ?? ""
        guard let start = text.range(
            of: #"Exceptions for "Sevoflurane" folder in "SevofluraneDaemon" target */ = {"#,
        ),
            let listStart = text.range(of: "membershipExceptions = (", range: start.upperBound ..< text.endIndex),
            let listEnd = text.range(of: ");", range: listStart.upperBound ..< text.endIndex)
        else { return [] }
        return Set(
            text[listStart.upperBound ..< listEnd.lowerBound]
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasSuffix(",") }
                .map { String($0.dropLast()) },
        )
    }()

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

    private func compiledByDaemon(_ relativePath: String) -> Bool {
        !Self.daemonExceptions.contains { exception in
            relativePath == exception || relativePath.hasPrefix(exception + "/")
        }
    }

    @Test
    func `the daemon compiles everything the CLI compiles`() {
        #expect(!Self.cliSources.isEmpty)
        for source in Self.cliSources.sorted() {
            let relative = String(source.dropFirst("Sevoflurane/".count))
            #expect(
                compiledByDaemon(relative),
                "the daemon excludes \(relative), which sevo compiles",
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
