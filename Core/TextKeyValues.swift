import Foundation

/// Valve's text KeyValues, the format of `config.vdf`, `appmanifest_*.acf`
/// and the compatibility tool files: quoted keys, quoted values, braces for
/// tables, `//` comments.
///
/// Read into a tree for lookups, and as tokens with their ranges for an edit
/// that must leave the rest of a file byte for byte as Steam wrote it.
nonisolated enum TextKeyValues {
    /// A value: a string, or a table of keyed values in file order.
    indirect enum Node: Equatable {
        case string(String)
        case table([(key: String, value: Node)])

        static func == (lhs: Node, rhs: Node) -> Bool {
            switch (lhs, rhs) {
            case let (.string(a), .string(b)): a == b
            case let (.table(a), .table(b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
            default: false
            }
        }

        /// The first value under `key`, compared without case as Steam does.
        subscript(key: String) -> Node? {
            guard case let .table(entries) = self else { return nil }
            return entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }

        /// The value at a path of keys.
        func at(_ path: [String]) -> Node? {
            path.reduce(Optional(self)) { node, key in node?[key] }
        }

        var string: String? {
            if case let .string(value) = self { value } else { nil }
        }

        var entries: [(key: String, value: Node)] {
            if case let .table(entries) = self { entries } else { [] }
        }
    }

    /// One token and where it sits in the text.
    struct Token: Equatable {
        enum Kind: Equatable {
            /// A quoted or bare string, unescaped.
            case string(String)
            case open
            case close
        }

        let kind: Kind
        /// The token's characters in the text, quotes included.
        let range: Range<String.Index>
    }

    /// The text's tokens, comments and conditionals (`[$WIN32]`) skipped.
    static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
            } else if character == "/", text[index...].hasPrefix("//") {
                index = text[index...].firstIndex(of: "\n") ?? text.endIndex
            } else if character == "{" || character == "}" {
                let next = text.index(after: index)
                tokens.append(Token(kind: character == "{" ? .open : .close, range: index ..< next))
                index = next
            } else if character == "[" {
                index = text[index...].firstIndex(of: "]").map { text.index(after: $0) } ?? text.endIndex
            } else if character == "\"" {
                var value = ""
                var cursor = text.index(after: index)
                while cursor < text.endIndex, text[cursor] != "\"" {
                    if text[cursor] == "\\", text.index(after: cursor) < text.endIndex {
                        cursor = text.index(after: cursor)
                        value.append(unescape(text[cursor]))
                    } else {
                        value.append(text[cursor])
                    }
                    cursor = text.index(after: cursor)
                }
                let end = cursor < text.endIndex ? text.index(after: cursor) : text.endIndex
                tokens.append(Token(kind: .string(value), range: index ..< end))
                index = end
            } else {
                let end = text[index...].firstIndex { $0.isWhitespace || $0 == "{" || $0 == "}" || $0 == "\"" }
                    ?? text.endIndex
                tokens.append(Token(kind: .string(String(text[index ..< end])), range: index ..< end))
                index = end
            }
        }
        return tokens
    }

    private static func unescape(_ character: Character) -> Character {
        switch character {
        case "n": "\n"
        case "t": "\t"
        default: character
        }
    }

    /// The text as a tree: the root table holds the file's top-level keys.
    /// `nil` for text whose braces do not balance.
    static func parse(_ text: String) -> Node? {
        var stack: [[(key: String, value: Node)]] = [[]]
        var keys: [String] = []
        var pendingKey: String?
        for token in tokens(text) {
            switch token.kind {
            case let .string(value):
                if let key = pendingKey {
                    stack[stack.count - 1].append((key, .string(value)))
                    pendingKey = nil
                } else {
                    pendingKey = value
                }
            case .open:
                guard let key = pendingKey else { return nil }
                keys.append(key)
                stack.append([])
                pendingKey = nil
            case .close:
                guard stack.count > 1, pendingKey == nil, let key = keys.popLast() else { return nil }
                let table = stack.removeLast()
                stack[stack.count - 1].append((key, .table(table)))
            }
        }
        guard stack.count == 1, pendingKey == nil else { return nil }
        return .table(stack[0])
    }

    /// Quotes a string the way Steam writes one.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
