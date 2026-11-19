import Foundation

/// The violations a file and rule had when the rules arrived. Up to that many
/// stay warnings; one more fails the build, so the baseline only shrinks.
public struct Baseline: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let file: String
        public let rule: Rule
        public let count: Int
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public init(violations: [Violation]) {
        let counts = Dictionary(grouping: violations) { Key(file: $0.file, rule: $0.rule) }.mapValues(\.count)
        entries = counts.map { Entry(file: $0.key.file, rule: $0.key.rule, count: $0.value) }
            .sorted { ($0.file, $0.rule) < ($1.file, $1.rule) }
    }

    func allowance(file: String, rule: Rule) -> Int {
        entries.first { $0.file == file && $0.rule == rule }?.count ?? 0
    }
}

struct Key: Hashable {
    let file: String
    let rule: Rule
}

public struct Report: Sendable {
    /// Each violation with the severity it is reported at.
    public var lines: [Violation] = []
    /// Baseline entries whose file now has fewer violations than allowed.
    public var shrunk: [Baseline.Entry] = []

    public var failed: Bool { lines.contains { $0.severity == .error } }
}

public enum Runner {
    /// The folders whose Swift sources are linted, relative to the root.
    public static let folders = [
        "Core", "Supervision", "Shared", "Sevo", "SevofluraneDaemon",
        "Sevoflurane", "SevofluraneDockTile", "SevofluraneThumbnail",
    ]

    public static func sources(root: URL) -> [(path: String, text: String)] {
        var found: [(String, String)] = []
        for folder in folders {
            let base = root.appending(path: folder)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                found.append((String(url.path.dropFirst(root.path.count + 1)), text))
            }
        }
        return found.sorted { $0.0 < $1.0 }
    }

    public static func lint(_ sources: [(path: String, text: String)]) -> [Violation] {
        let views = Linter.viewTypes(in: sources.map(\.text))
        return sources.flatMap { Linter.lint(source: $0.text, path: $0.path, viewTypes: views) }
    }

    /// Within its file and rule's allowance a violation is a warning; past it,
    /// every violation of that file and rule keeps its own severity.
    public static func judge(_ violations: [Violation], against baseline: Baseline) -> Report {
        var report = Report()
        let groups = Dictionary(grouping: violations) { Key(file: $0.file, rule: $0.rule) }
        for (key, group) in groups.sorted(by: { ($0.key.file, $0.key.rule) < ($1.key.file, $1.key.rule) }) {
            let allowed = baseline.allowance(file: key.file, rule: key.rule)
            let within = group.count <= allowed
            for violation in group.sorted(by: { $0.line < $1.line }) {
                report.lines.append(within ? Violation(
                    file: violation.file, line: violation.line, column: violation.column,
                    rule: violation.rule, severity: .warning, message: violation.message,
                ) : violation)
            }
        }
        report.shrunk = baseline.entries.filter { entry in
            (groups[Key(file: entry.file, rule: entry.rule)]?.count ?? 0) < entry.count
        }
        return report
    }
}
