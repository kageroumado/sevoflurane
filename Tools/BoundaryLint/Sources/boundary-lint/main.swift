import BoundaryLintCore
import Foundation

// boundary-lint [--root DIR] [--baseline FILE] [--write-baseline]
// Prints `file:line:column: severity: message [rule]`, the form Xcode marks in
// the editor, and exits 1 when anything is an error.

let arguments = Array(CommandLine.arguments.dropFirst())
@MainActor
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let root = URL(filePath: option("--root") ?? FileManager.default.currentDirectoryPath)
let baselineURL = option("--baseline").map { URL(filePath: $0) }
    ?? root.appending(path: "Tools/BoundaryLint/baseline.json")
let violations = Runner.lint(Runner.sources(root: root))

if arguments.contains("--write-baseline") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Baseline(violations: violations)).write(to: baselineURL)
    print("boundary-lint: wrote \(violations.count) violations to \(baselineURL.path)")
    exit(0)
}

let baseline = (try? Data(contentsOf: baselineURL))
    .flatMap { try? JSONDecoder().decode(Baseline.self, from: $0) } ?? Baseline(entries: [])
let report = Runner.judge(violations, against: baseline)
for line in report.lines {
    let path = root.appending(path: line.file).path
    print("\(path):\(line.line):\(line.column): \(line.severity.rawValue): \(line.message) [\(line.rule.rawValue)]")
}
for entry in report.shrunk {
    print("\(root.appending(path: entry.file).path):1:1: note: fewer \(entry.rule.rawValue) than the baseline's \(entry.count); run boundary-lint --write-baseline to lock it in")
}
exit(report.failed ? 1 : 0)
