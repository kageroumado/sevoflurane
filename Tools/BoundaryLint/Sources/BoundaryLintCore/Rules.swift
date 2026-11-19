import SwiftParser
import SwiftSyntax

/// One rule of the boundary between what draws and what works.
public enum Rule: String, Codable, CaseIterable, Comparable, Sendable {
    /// A folder compiled into the helper or `sevo` imports a UI framework.
    case uiImport = "ui-import"
    /// A store or service imports SwiftUI.
    case storeSwiftUI = "store-swiftui"
    /// A view does I/O.
    case viewIO = "view-io"
    /// `.onAppear { Task { … } }`, which never cancels.
    case viewTaskOnAppear = "view-task-on-appear"
    /// A view holds more `@State` than one view should.
    case viewStateCount = "view-state-count"
    /// An `@State` that is not private.
    case viewStatePrivate = "view-state-private"
    /// A view init, or a stored property's initial value, calls something
    /// other than a type's own initializer.
    case viewInit = "view-init"
    /// A view body longer than a screen.
    case viewBodyLength = "view-body-length"

    public static func < (lhs: Rule, rhs: Rule) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum Severity: String, Sendable { case warning, error }

public struct Violation: Hashable, Sendable {
    /// Relative to the repository root.
    public let file: String
    public let line: Int
    public let column: Int
    public let rule: Rule
    public let severity: Severity
    public let message: String
}

public enum Limits {
    /// More `@State` than this warns; more than ``stateError`` fails.
    public static let stateWarning = 6
    public static let stateError = 10
    /// Lines a view body or `some View` property may span.
    public static let bodyLines = 60
}

/// The folders each path rule covers, relative to the repository root.
public enum Folders {
    /// Compiled into the helper or `sevo`, which have no window.
    public static let headless = ["Core/", "Supervision/", "Shared/", "Sevo/", "SevofluraneDaemon/"]
    public static let uiFrameworks: Set<String> = ["SwiftUI", "WebKit", "Propofol"]
    /// Hold state and do work; SwiftUI belongs to `Views/`.
    public static let nonUI = ["Sevoflurane/Stores/", "Sevoflurane/Services/"]
}

/// The identifiers a view may not name: each one is disk, network, process or
/// log work that belongs in a store.
enum IO {
    static let types: Set<String> = [
        "FileManager", "URLSession", "Subprocess", "JSONDecoder", "JSONSerialization", "UserDefaults", "EventLog",
    ]
    static let functions: Set<String> = ["sysctl", "sysctlbyname"]
    static let functionPrefix = "proc_"
    /// Called as a type, `Process(…)` starts a process; `Data(contentsOf:)` and
    /// `String(contentsOf:)` read a file.
    static let readingInits: Set<String> = ["Data", "String"]
}

public enum Linter {
    /// The names of every type that conforms to `View` in `sources`, so an
    /// extension of one elsewhere is checked as view code too.
    public static func viewTypes(in sources: [String]) -> Set<String> {
        var names: Set<String> = []
        for source in sources {
            let finder = ViewTypeFinder(viewMode: .sourceAccurate)
            finder.walk(Parser.parse(source: source))
            names.formUnion(finder.names)
        }
        return names
    }

    /// Every violation in one file. `path` is relative to the repository root.
    public static func lint(source: String, path: String, viewTypes: Set<String>) -> [Violation] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        var found: [Violation] = []

        func note(_ node: some SyntaxProtocol, _ rule: Rule, _ severity: Severity, _ message: String) {
            let location = node.startLocation(converter: converter)
            found.append(Violation(
                file: path, line: location.line, column: location.column,
                rule: rule, severity: severity, message: message,
            ))
        }

        for statement in tree.statements {
            guard let declaration = statement.item.as(ImportDeclSyntax.self),
                  let module = declaration.path.first?.name.text else { continue }
            if Folders.headless.contains(where: path.hasPrefix), Folders.uiFrameworks.contains(module) {
                note(declaration, .uiImport, .error,
                     "\(path.split(separator: "/").first ?? "") compiles into the helper or sevo, which draw nothing: no import \(module)")
            }
            if Folders.nonUI.contains(where: path.hasPrefix), module == "SwiftUI" {
                note(declaration, .storeSwiftUI, .error,
                     "stores and services hold state and do work; SwiftUI belongs in Views/")
            }
        }

        guard path.hasPrefix("Sevoflurane/") else { return found }
        let checker = ViewChecker(viewTypes: viewTypes, converter: converter) { node, rule, severity, message in
            note(node, rule, severity, message)
        }
        checker.walk(tree)
        return found
    }
}

/// Collects the names of types that declare `View` conformance.
final class ViewTypeFinder: SyntaxVisitor {
    var names: Set<String> = []

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if conformsToView(node.inheritanceClause) { names.insert(node.name.text) }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if conformsToView(node.inheritanceClause) { names.insert(node.name.text) }
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if conformsToView(node.inheritanceClause) { names.insert(node.extendedType.trimmedDescription) }
        return .visitChildren
    }
}

func conformsToView(_ clause: InheritanceClauseSyntax?) -> Bool {
    clause?.inheritedTypes.contains { inherited in
        let name = inherited.type.trimmedDescription
        return name == "View" || name == "SwiftUI.View"
    } ?? false
}

/// Applies the view rules to every view type and every extension of one.
final class ViewChecker: SyntaxVisitor {
    typealias Note = (Syntax, Rule, Severity, String) -> Void
    private let viewTypes: Set<String>
    private let converter: SourceLocationConverter
    private let note: Note

    init(
        viewTypes: Set<String>, converter: SourceLocationConverter,
        note: @escaping (Syntax, Rule, Severity, String) -> Void,
    ) {
        self.viewTypes = viewTypes
        self.converter = converter
        self.note = note
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if viewTypes.contains(node.name.text) { check(node.memberBlock, named: node.name.text, declaresType: true) }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if viewTypes.contains(node.name.text) { check(node.memberBlock, named: node.name.text, declaresType: true) }
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.trimmedDescription
        if viewTypes.contains(name) { check(node.memberBlock, named: name, declaresType: false) }
        return .visitChildren
    }

    private func check(_ members: MemberBlockSyntax, named name: String, declaresType: Bool) {
        var states: [VariableDeclSyntax] = []
        for member in members.members {
            let item = member.decl
            // A nested type is checked on its own when it is a view.
            if item.is(StructDeclSyntax.self) || item.is(ClassDeclSyntax.self) || item.is(EnumDeclSyntax.self)
                || item.is(ActorDeclSyntax.self) { continue }
            if let variable = item.as(VariableDeclSyntax.self) {
                if variable.attributes.contains(where: { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "State" }) {
                    states.append(variable)
                    let isPrivate = variable.modifiers.contains { ["private", "fileprivate"].contains($0.name.text) }
                    if !isPrivate {
                        note(Syntax(variable), .viewStatePrivate, .error,
                             "@State \(variable.bindings.first?.pattern.trimmedDescription ?? "") in \(name) must be private: its initial value is honored once, from inside the view")
                    }
                }
                checkStoredInitializers(variable, in: name)
                checkBodyLength(variable, in: name)
            }
            if let initializer = item.as(InitializerDeclSyntax.self), let body = initializer.body {
                for call in outermostWork(in: Syntax(body)) {
                    note(Syntax(call), .viewInit, .error,
                         "\(name).init calls \(call.calledExpression.trimmedDescription)(…): a view init runs on every parent render; assign only, and do the work in a store or in .task")
                }
            }
            if let function = item.as(FunctionDeclSyntax.self), returnsSomeView(function.signature.returnClause),
               let body = function.body {
                checkLength(Syntax(body), label: "\(name).\(function.name.text)()", in: name)
            }
            checkIO(Syntax(item), in: name)
            checkOnAppearTask(Syntax(item), in: name)
        }
        if declaresType, states.count > Limits.stateWarning {
            let severity: Severity = states.count > Limits.stateError ? .error : .warning
            note(Syntax(states[Limits.stateWarning]), .viewStateCount, severity,
                 "\(name) holds \(states.count) @State (over \(Limits.stateWarning)): it is more than one view, or its state belongs in a store")
        }
    }

    private func checkStoredInitializers(_ variable: VariableDeclSyntax, in name: String) {
        for binding in variable.bindings where binding.accessorBlock == nil {
            guard let value = binding.initializer?.value else { continue }
            for call in outermostWork(in: Syntax(value)) {
                note(Syntax(call), .viewInit, .error,
                     "\(name).\(binding.pattern.trimmedDescription) starts as \(call.calledExpression.trimmedDescription)(…), which runs on every parent render; read it in a store or in .task")
            }
        }
    }

    private func checkBodyLength(_ variable: VariableDeclSyntax, in name: String) {
        for binding in variable.bindings {
            guard let accessors = binding.accessorBlock else { continue }
            let label = binding.pattern.trimmedDescription
            let isView = label == "body" || binding.typeAnnotation.map { isSomeView($0.type) } == true
            if isView { checkLength(Syntax(accessors), label: "\(name).\(label)", in: name) }
        }
    }

    private func checkLength(_ node: Syntax, label: String, in name: String) {
        let first = node.startLocation(converter: converter).line
        let last = node.endLocation(converter: converter).line
        let lines = last - first + 1
        if lines > Limits.bodyLines {
            note(node, .viewBodyLength, .warning, "\(label) spans \(lines) lines (over \(Limits.bodyLines)): extract a subview")
        }
    }

    private func checkIO(_ node: Syntax, in name: String) {
        for token in node.tokens(viewMode: .sourceAccurate) where token.tokenKind.isIdentifier {
            let text = token.text
            let flagged = IO.types.contains(text) || IO.functions.contains(text) || text.hasPrefix(IO.functionPrefix)
            if flagged {
                note(Syntax(token), .viewIO, .error,
                     "\(text) in view \(name): views send intents, stores do disk, network, process and log work")
            }
        }
        for call in calls(in: node) {
            let callee = call.calledExpression.trimmedDescription
            let readsFile = IO.readingInits.contains(callee)
                && call.arguments.first?.label?.text == "contentsOf"
            if callee == "Process" || readsFile {
                note(Syntax(call), .viewIO, .error,
                     "\(callee)(\(readsFile ? "contentsOf:" : "")…) in view \(name): views send intents, stores do the work")
            }
        }
    }

    private func checkOnAppearTask(_ node: Syntax, in name: String) {
        for call in calls(in: node) {
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "onAppear" else { continue }
            let closures = [call.trailingClosure.map(Syntax.init)]
                + call.arguments.map { Syntax($0.expression) }
            let startsTask = closures.compactMap { $0 }.contains { closure in
                calls(in: closure).contains { $0.calledExpression.trimmedDescription.hasPrefix("Task") }
            }
            if startsTask {
                note(Syntax(call), .viewTaskOnAppear, .error,
                     ".onAppear { Task { … } } in \(name) never cancels; .task cancels when the view goes")
            }
        }
    }
}

/// Every function call under `node`, nested ones included.
func calls(in node: Syntax) -> [FunctionCallExprSyntax] {
    final class Collector: SyntaxVisitor {
        var found: [FunctionCallExprSyntax] = []
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            found.append(node)
            return .visitChildren
        }
    }
    let collector = Collector(viewMode: .sourceAccurate)
    collector.walk(node)
    return collector.found
}

/// The calls that run when `node` is evaluated and are not a type's own
/// construction, outermost only: a closure literal runs later, so its body
/// counts only when it is called on the spot, and inside a reported call
/// nothing more is reported.
func outermostWork(in node: Syntax) -> [FunctionCallExprSyntax] {
    final class Collector: SyntaxVisitor {
        var found: [FunctionCallExprSyntax] = []
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            let calledOnTheSpot = node.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id == node.id
            return calledOnTheSpot ? .visitChildren : .skipChildren
        }
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard !isTypeConstruction(node) else { return .visitChildren }
            found.append(node)
            return .skipChildren
        }
    }
    let collector = Collector(viewMode: .sourceAccurate)
    collector.walk(node)
    return collector.found
}

/// Value types whose static factories compute a value and touch nothing:
/// `Duration.seconds(30)`, `Color.accentColor.opacity(…)`.
let valueTypes: Set<String> = [
    "Duration", "Date", "TimeInterval", "UUID", "URL", "Color", "Font", "Image", "Text", "Animation",
    "CGSize", "CGPoint", "CGRect", "CGFloat", "EdgeInsets", "AnyShapeStyle", "AnyView", "Edge", "Calendar",
]

/// A type's own initializer, an enum case, or `.init`: `Store(…)`,
/// `State(initialValue:)`, `.bottle(name)`, `Foo.init(…)`, `super.init(…)`.
func isTypeConstruction(_ call: FunctionCallExprSyntax) -> Bool {
    let callee = call.calledExpression
    if let reference = callee.as(DeclReferenceExprSyntax.self) {
        return reference.baseName.text.first?.isUppercase == true
    }
    if let member = callee.as(MemberAccessExprSyntax.self) {
        let name = member.declName.baseName.text
        if name == "init" { return true }
        // `.case(…)` with no base names an enum case or a static factory of the
        // contextual type; one that reads disk would be a store's own API.
        if member.base == nil { return true }
        if let base = member.base?.as(DeclReferenceExprSyntax.self), valueTypes.contains(base.baseName.text) {
            return true
        }
        // `Outer.Inner(…)` constructs a nested type.
        return name.first?.isUppercase == true
    }
    if let generic = callee.as(GenericSpecializationExprSyntax.self) {
        return generic.expression.trimmedDescription.first?.isUppercase == true
    }
    return false
}

func returnsSomeView(_ clause: ReturnClauseSyntax?) -> Bool {
    clause.map { isSomeView($0.type) } ?? false
}

func isSomeView(_ type: TypeSyntax) -> Bool {
    let text = type.trimmedDescription
    return text == "some View" || text == "some SwiftUI.View"
}

extension TokenKind {
    var isIdentifier: Bool {
        if case .identifier = self { return true }
        return false
    }
}
