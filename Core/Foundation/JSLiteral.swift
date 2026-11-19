import Foundation

/// JavaScript string literals, escaped as JSON (a strict subset of JS since
/// ES2019), so quotes, newlines and control characters are safe.
nonisolated enum JSLiteral {
    static func string(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed],
        ), let text = String(data: data, encoding: .utf8) else {
            // Unreachable for a Swift String.
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        return text
    }

    /// ``string(_:)`` that is also safe inside an HTML `<script>` or `<style>`
    /// element: every `<` is escaped, so `</script>` or `<!--` cannot end it.
    static func inlineString(_ value: String) -> String {
        string(value).replacingOccurrences(of: "<", with: "\\u003C")
    }
}
