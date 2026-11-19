import Foundation

/// The variables a person sets by name for the bottle or for one game — the
/// Environment rows, `sevo app config <id> env`, and the `KEY=VALUE` words of
/// Steam's launch options (``SteamLaunchCommand``).
///
/// They follow the level's own rows in the env file, so they win over a row
/// that writes the same name (``managingSetting(of:)``). An empty value is
/// written as `KEY=`, which the engine reads as "remove the variable".
nonisolated enum UserEnvironment {
    enum Problem: Equatable, Sendable {
        case invalidName
        /// The bottle's own machinery sets the name.
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

    /// `[A-Za-z_][A-Za-z0-9_]*`.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isNameStart(first) else { return false }
        return name.unicodeScalars.allSatisfy { isNameStart($0) || ("0" ... "9").contains($0) }
    }

    private static func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
        ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || scalar == "_"
    }

    /// Why a pair cannot be stored, or `nil` when it can.
    static func problem(name: String, value: String) -> Problem? {
        guard isValidName(name) else { return .invalidName }
        guard !isReserved(name) else { return .reserved }
        guard !value.contains(where: \.isNewline), !value.unicodeScalars.contains("\0") else {
            return .invalidValue
        }
        // The engine reads a line into 4096 bytes and would read the tail of a
        // longer one as a line of its own.
        guard name.utf8.count + value.utf8.count + 2 < lineLimit else { return .tooLong }
        return nil
    }

    private static let lineLimit = 4000

    /// Names that must be the same for every process of the wineserver (the
    /// engine ignores them in a game's file) or that carry the app's wiring to
    /// the engine.
    static func isReserved(_ name: String) -> Bool {
        reserved.contains(name) || reservedPrefixes.contains { name.hasPrefix($0) }
    }

    private static let reserved: Set<String> = [
        "WINEPREFIX", "WINESERVER", "WINEARCH", "WINEMSYNC", "WINEESYNC", "WINEFSYNC",
        "SEVO_ENV_FILES", "SEVO_LOADER", "SEVO_RUNNER", "SEVO_SUPPRESS_WINDOWS", "SEVO_QUIET",
        "SEVO_ENGINE_NAME", "SEVO_CLI", BottleOwner.variable,
    ]

    private static let reservedPrefixes = ["DYLD_", "SEVO_NWJS", "SEVO_STEAM_"]

    /// The env file lines for a level's table, sorted by name.
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

    /// The setting whose row writes `name`, for the note under a variable that
    /// overrides it.
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
