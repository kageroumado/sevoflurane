import Foundation

/// The query strings the control and app-link ports speak: `name=value`
/// pairs joined by `&`, each side percent-encoded, so a bottle named
/// `A&B` or a reason with `=` in it arrives as sent.
nonisolated enum QueryString {
    /// What a name or value keeps as-is: the query-safe characters, less the
    /// ones that delimit pairs or mean something to a form decoder.
    private static let unreserved = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#;"))

    static func encode(_ items: [(name: String, value: String)]) -> String {
        items.map { "\(escape($0.name))=\(escape($0.value))" }.joined(separator: "&")
    }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// One parameter's decoded value, or the empty string when it is absent.
    static func value(of name: String, in query: String) -> String {
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, String(key).removingPercentEncoding == name else { continue }
            guard parts.count == 2 else { return "" }
            return String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return ""
    }
}
