import Foundation

/// The variables a person sets by name for the bottle or for one game — the
/// Environment rows, `sevo app config <id> env`, and the `KEY=VALUE` words of
/// Steam's launch options (``SteamLaunchCommand``).
///
/// They ride in the same env files as every other setting, after the lines the
/// level's own rows write, so a variable set here wins over a row of the same
/// level that writes the same name. The rows then name what they no longer
/// decide (``managingSetting(of:)``). An empty value is written as `KEY=`,
/// which the engine reads as "remove the variable".
nonisolated enum UserEnvironment {
    /// Why a variable cannot be stored.
    enum Problem: Equatable, Sendable {
        case invalidName
        /// The bottle itself depends on the name, and a row of its own sets it.
        case reserved
        /// Characters an env file line cannot carry.
        case invalidValue
        case tooLong

        var message: String {
            let value = switch self {
            case .invalidName:
                "A name is letters, digits and underscores, and starts with a letter or an underscore."
            case .reserved:
                "Sevoflurane needs this one for the bottle itself."
            case .invalidValue:
                "A value is one line."
            case .tooLong:
                "The value is too long."
            }
            return InterfaceCopy.localized(value)
        }
    }

    /// Whether `name` is a shell variable name: `[A-Za-z_][A-Za-z0-9_]*`.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isNameStart(first) else { return false }
        return name.unicodeScalars.allSatisfy { isNameStart($0) || ("0" ... "9").contains($0) }
    }

    private static func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
        ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || scalar == "_"
    }

    /// What stands between a pair and the env file, or `nil` when it can be
    /// stored.
    static func problem(name: String, value: String) -> Problem? {
        guard isValidName(name) else { return .invalidName }
        guard !isReserved(name) else { return .reserved }
        guard !value.contains(where: \.isNewline), !value.unicodeScalars.contains("\0") else {
            return .invalidValue
        }
        // The engine reads a line into 4096 bytes; a longer one would be cut
        // and its tail read as a line of its own.
        guard name.utf8.count + value.utf8.count + 2 < lineLimit else { return .tooLong }
        return nil
    }

    private static let lineLimit = 4000

    /// The names the bottle's own machinery owns. Each one either has to be the
    /// same for every process of the wineserver (the engine ignores it in a
    /// game's file), or carries the app's own wiring to the engine — the
    /// loader bundle, the native runner, the owner a bottle dies with, the
    /// shim's window suppression.
    static func isReserved(_ name: String) -> Bool {
        reserved.contains(name) || reservedPrefixes.contains { name.hasPrefix($0) }
    }

    private static let reserved: Set<String> = [
        "WINEPREFIX", "WINESERVER", "WINEARCH", "WINEMSYNC", "WINEESYNC", "WINEFSYNC",
        "SEVO_ENV_FILES", "SEVO_LOADER", "SEVO_RUNNER", "SEVO_SUPPRESS_WINDOWS", "SEVO_QUIET",
        "SEVO_ENGINE_NAME", "SEVO_CLI", BottleOwner.variable,
    ]

    private static let reservedPrefixes = ["DYLD_", "SEVO_NWJS", "SEVO_STEAM_"]

    /// The env file lines for a level's table, by name, so the file reads the
    /// same whatever order the table was built in.
    static func lines(_ table: [String: String]?) -> [String] {
        (table ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// The table as one line for a log: `DXVK_HUD=1 FOO="a b"`.
    static func summary(_ table: [String: String]) -> String {
        table.sorted { $0.key < $1.key }.map { key, value in
            value.contains(where: \.isWhitespace) || value.isEmpty ? "\(key)=\"\(value)\"" : "\(key)=\(value)"
        }.joined(separator: " ")
    }

    // MARK: - Names a row writes

    /// The setting whose row writes `name` itself, for the note under a
    /// variable that now decides that value in its place.
    static func managingSetting(of name: String) -> String? {
        if let setting = SettingCatalog.all.first(where: { setting in
            if case let .environment(keys) = setting.carrier { keys.contains(name) } else { false }
        }) {
            return setting.title
        }
        return rendererKeys.contains(name) ? SettingCatalog.setting(.renderer).title : nil
    }

    /// What a game's renderer writes into its file (``ConfigMaterializer``).
    private static let rendererKeys: Set<String> = [
        "WINEDLLPATH_PREPEND", "WINEDLLOVERRIDES", "SEVO_LIBD3DSHARED_PATH", "D3DM_WINE_UNIX_CALL",
    ]
}
