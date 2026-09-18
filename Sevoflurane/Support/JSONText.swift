import Foundation

/// JSON as text, the way every face of the project writes it: sorted keys,
/// so two renderings of the same value diff clean.
nonisolated enum JSONText {
    static func string(_ value: Any, pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }
}
