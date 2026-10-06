import Foundation

/// JavaScript string literals, escaped once for the whole app. The escaping
/// is JSON's — a strict subset of JS syntax since ES2019 — so any content is
/// safe, including quotes, newlines, and control characters.
nonisolated enum JSLiteral {
    static func string(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed],
        ), let text = String(data: data, encoding: .utf8) else {
            // Unreachable for a Swift String; keep a lossless fallback anyway.
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        return text
    }

    /// ``string(_:)`` that is also safe inside an HTML `<script>` or
    /// `<style>` element: every `<` is written as an escape, so no
    /// `</script>`, `</style>` or `<!--` in the value can end or reshape the
    /// element around it.
    static func inlineString(_ value: String) -> String {
        string(value).replacingOccurrences(of: "<", with: "\\u003C")
    }
}
