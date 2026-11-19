@testable import BoundaryLintCore
import Testing

struct RuleTests {
    private func lint(_ source: String, at path: String = "Sevoflurane/Views/X.swift") -> [Violation] {
        Linter.lint(source: source, path: path, viewTypes: Linter.viewTypes(in: [source]))
    }

    private func rules(_ source: String, at path: String = "Sevoflurane/Views/X.swift") -> [Rule] {
        lint(source, at: path).map(\.rule)
    }

    @Test
    func `headless folders import no UI framework`() {
        #expect(rules("import SwiftUI\n", at: "Core/Engine/X.swift") == [.uiImport])
        #expect(rules("import WebKit\n", at: "Supervision/X.swift") == [.uiImport])
        #expect(rules("import AppKit\nimport Foundation\n", at: "Supervision/X.swift").isEmpty)
        #expect(rules("import SwiftUI\n", at: "Sevoflurane/Views/X.swift").isEmpty)
    }

    @Test
    func `stores and services import no SwiftUI`() {
        #expect(rules("import SwiftUI\n", at: "Sevoflurane/Stores/X.swift") == [.storeSwiftUI])
        #expect(rules("import Observation\n", at: "Sevoflurane/Services/X.swift").isEmpty)
    }

    @Test
    func `a view does no I/O, an extension of it included`() {
        let source = """
        struct Pane: View {
            var body: some View { Text(FileManager.default.currentDirectoryPath) }
        }
        extension Pane {
            func save() { UserDefaults.standard.set(1, forKey: "k") }
            func read() { _ = try? String(contentsOf: url) }
        }
        struct Model {
            func load() { _ = FileManager.default }
        }
        """
        let found = lint(source).filter { $0.rule == .viewIO }
        #expect(found.map(\.line) == [2, 5, 6])
    }

    @Test
    func `onAppear starting a Task is flagged, task is not`() {
        let source = """
        struct Pane: View {
            var body: some View {
                Text("a").onAppear { Task { await load() } }
                Text("b").task { await load() }
                Text("c").onAppear { count += 1 }
            }
        }
        """
        #expect(lint(source).filter { $0.rule == .viewTaskOnAppear }.map(\.line) == [3])
    }

    @Test
    func `state count warns past six and fails past ten`() {
        func view(_ count: Int) -> String {
            "struct Pane: View {\n" + (0 ..< count).map { "    @State private var s\($0) = 0\n" }.joined()
                + "    var body: some View { EmptyView() }\n}\n"
        }
        #expect(lint(view(6)).filter { $0.rule == .viewStateCount }.isEmpty)
        #expect(lint(view(7)).filter { $0.rule == .viewStateCount }.map(\.severity) == [.warning])
        #expect(lint(view(11)).filter { $0.rule == .viewStateCount }.map(\.severity) == [.error])
    }

    @Test
    func `state must be private`() {
        let source = """
        struct Pane: View {
            @State var shown = false
            @State private var kept = false
            var body: some View { EmptyView() }
        }
        """
        #expect(lint(source).filter { $0.rule == .viewStatePrivate }.map(\.line) == [2])
    }

    @Test
    func `a view init assigns and constructs, and calls nothing else`() {
        let source = """
        struct Pane: View {
            @State private var store = SettingsStore(scope: .bottle(SteamBottle.name))
            @State private var asked = RunLog.hasRecords()
            let title: String
            init(title: String) {
                self.title = title
                _flag = State(initialValue: Preferences.load())
            }
            var body: some View { EmptyView() }
        }
        """
        let found = lint(source).filter { $0.rule == .viewInit }
        #expect(found.map(\.line) == [3, 7])
    }

    @Test
    func `a stored closure runs later, a value factory touches nothing, a chain reports once`() {
        let source = """
        struct Pane: View {
            var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }
            private let life = Duration.seconds(30)
            private let rows = SettingGroup.allCases.map { $0 }.filter { $0.isOn }
            private let version: String = { AppVersion.displayed() }()
            var body: some View { EmptyView() }
        }
        """
        let found = lint(source).filter { $0.rule == .viewInit }
        #expect(found.map(\.line) == [4, 5])
    }

    @Test
    func `a static stored property runs once and is no view-init work`() {
        let source = """
        struct Pane: View {
            private static let version: String = { AppVersion.displayed() }()
            private static let sample = Sample.example(version: "1")
            private let rows = Sample.example(version: "1")
            var body: some View { EmptyView() }
        }
        """
        let found = lint(source).filter { $0.rule == .viewInit }
        #expect(found.map(\.line) == [4])
    }

    @Test
    func `a long body warns`() {
        let lines = (0 ..< 70).map { _ in "        Text(\"x\")" }.joined(separator: "\n")
        let source = "struct Pane: View {\n    var body: some View {\n        VStack {\n\(lines)\n        }\n    }\n}\n"
        let found = lint(source).filter { $0.rule == .viewBodyLength }
        #expect(found.map(\.severity) == [.warning])
    }

    @Test
    func `the baseline turns known violations into warnings and fails on more`() {
        let source = "struct Pane: View {\n    var body: some View { Text(FileManager.default.homeDirectoryForCurrentUser.path) }\n}\n"
        let violations = lint(source)
        let baseline = Baseline(violations: violations)
        #expect(!Runner.judge(violations, against: baseline).failed)
        let more = violations + violations
        #expect(Runner.judge(more, against: baseline).failed)
        #expect(Runner.judge([], against: baseline).shrunk.count == 1)
    }
}
