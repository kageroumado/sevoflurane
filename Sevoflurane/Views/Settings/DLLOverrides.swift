import Foundation

/// The libraries the active engine ships: the names winecfg's Libraries tab
/// offers for overrides.
enum BuiltinLibraries {
    /// Names without `.dll`, sorted, read from the engine's 64-bit modules.
    static func names(engine: Engine = .active) -> [String] {
        // A managed engine keeps Wine under `wine/`; CrossOver's tree is Wine's own.
        let files = ["wine/lib/wine/x86_64-windows", "lib/wine/x86_64-windows"]
            .lazy
            .compactMap { try? FileManager.default.contentsOfDirectory(atPath: engine.root.appendingPathComponent($0).path) }
            .first ?? []
        return files
            .filter { $0.hasSuffix(".dll") }
            .map { String($0.dropLast(".dll".count)) }
            .sorted()
    }

    /// A typed name as the registry spells it: lower case, no extension.
    static func normalized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasSuffix(".dll") ? String(trimmed.dropLast(".dll".count)) : trimmed
    }
}

/// A DLL override table as ``KeyValueEditor`` edits it, for a bottle and for
/// a game: the same words over each level's own spelling of a load order.
enum DLLOverrideEditing {
    /// A game's load orders as the registry spells them, so the editor and
    /// `sevo app config <id> dll` name the same values.
    static let gameOrders = [
        SettingChoice(value: "n,b", label: "Native, then built-in"),
        SettingChoice(value: "b,n", label: "Built-in, then native"),
        SettingChoice(value: "n", label: "Native only"),
        SettingChoice(value: "b", label: "Built-in only"),
        SettingChoice(value: "", label: "Disabled"),
    ]

    /// The bottle's, spelled the way ``BottleDependencies/overrideModes`` are.
    static let bottleOrders = [
        SettingChoice(value: "native,builtin", label: "Native, then built-in"),
        SettingChoice(value: "native", label: "Native only"),
        SettingChoice(value: "builtin", label: "Built-in only"),
        SettingChoice(value: "disabled", label: "Disabled"),
    ]

    static let rules = KeyValueEditor.Rules(
        normalize: { BuiltinLibraries.normalized($0) },
        removeLabel: { String(localized: "Remove the override for \($0)") },
    )

    static var prompt: String { String(localized: "Library, like dinput8") }
}
