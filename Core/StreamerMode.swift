import Foundation

/// Streamer Mode: every Steam window shows a chosen name and picture in place
/// of the signed-in account, friends as AI models, and no wallet balance.
///
/// The choice lives in the shared suite, so `sevo streamer` and the app read
/// one switch; the picture is a small image in the support folder
/// (``avatarURL``), or a monogram of the name when none was chosen.
nonisolated enum StreamerMode {
    /// The name shown when the field is left empty.
    static let defaultDisplayName = "Player"

    /// The edge, in pixels, of the stored picture: Steam's largest avatar.
    static let avatarPixels = 184

    /// Whether the Steam pages are masked.
    static var isOn: Bool {
        get { Preferences.shared.object(forKey: isOnKey) as? Bool ?? false }
        set { Preferences.shared.set(newValue, forKey: isOnKey) }
    }

    static let isOnKey = "streamerMode"

    /// The name shown in place of the account's persona and account names.
    static var displayName: String {
        get { resolvedName(Preferences.shared.string(forKey: displayNameKey)) }
        set { Preferences.shared.set(newValue, forKey: displayNameKey) }
    }

    static let displayNameKey = "streamerDisplayName"

    /// A stored name with surrounding whitespace dropped, or the default when
    /// nothing is left.
    static func resolvedName(_ stored: String?) -> String {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultDisplayName : trimmed
    }

    /// The picture the user chose, already downscaled to ``avatarPixels``.
    static var avatarURL: URL {
        AppIdentity.supportFolder.appendingPathComponent("Streamer Avatar.png")
    }

    /// The chosen picture as a `data:` URI, or the name's monogram.
    static func avatarDataURI(name: String = displayName, file: URL = avatarURL) -> String {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else {
            return Monogram.dataURI(for: name)
        }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    /// Everything the mask script is built from, read once.
    struct Settings: Equatable, Sendable {
        var isOn: Bool
        var displayName: String
        var avatarDataURI: String
        /// Account and persona names the bottle's Steam has signed in with,
        /// masked from the first frame rather than once the page reveals them.
        var knownNames: [String] = []

        static var current: Settings {
            let name = StreamerMode.displayName
            return Settings(
                isOn: StreamerMode.isOn,
                displayName: name,
                avatarDataURI: StreamerMode.avatarDataURI(name: name),
                knownNames: SteamAccounts.names(),
            )
        }
    }
}

// MARK: - Monogram

/// A square picture of one or two letters on a color taken from the name, as
/// an SVG `data:` URI. The mask script draws friends' pictures with the same
/// letters and color rule (``StreamerMask``), so a name looks the same
/// wherever it is drawn.
nonisolated enum Monogram {
    /// The picture's viewBox edge.
    private static let edge = 64
    /// Saturation and lightness of the background, in percent; the hue comes
    /// from the name.
    static let saturation = 45
    static let lightness = 42
    /// FNV-1a, 32-bit.
    private static let fnvOffset: UInt32 = 2_166_136_261
    private static let fnvPrime: UInt32 = 16_777_619
    private static let hues: UInt32 = 360

    /// The first letter of the first two words, or of one word the letter
    /// after it that is a capital or a digit ("ChatGPT" → "CG", "o3" → "O3").
    static func letters(of name: String) -> String {
        let words = name.split { $0 == " " || $0 == "-" || $0 == "_" }
        guard let first = words.first?.first else { return "?" }
        if words.count > 1, let second = words[1].first {
            return String([first, second]).uppercased()
        }
        let next = words[0].dropFirst().first { $0.isUppercase || $0.isNumber }
        return (String(first) + (next.map(String.init) ?? "")).uppercased()
    }

    /// The background's hue: FNV-1a over the name's UTF-16 code units, which
    /// is what the page's JavaScript iterates, so both sides agree.
    static func hue(of name: String) -> Int {
        var hash = fnvOffset
        for unit in name.utf16 {
            hash = (hash ^ UInt32(unit)) &* fnvPrime
        }
        return Int(hash % hues)
    }

    /// The CSS color of the background.
    static func color(of name: String) -> String {
        "hsl(\(hue(of: name)),\(saturation)%,\(lightness)%)"
    }

    static func svg(for name: String) -> String {
        let text = letters(of: name)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 \(edge) \(edge)'>"
            + "<rect width='\(edge)' height='\(edge)' fill='\(color(of: name))'/>"
            + "<text x='32' y='32' dy='.35em' text-anchor='middle' fill='#fff' font-size='28' "
            + "font-weight='600' font-family='-apple-system,Helvetica,Arial,sans-serif'>\(text)</text></svg>"
    }

    static func dataURI(for name: String) -> String {
        let encoded = svg(for: name).addingPercentEncoding(withAllowedCharacters: uriSafe) ?? ""
        return "data:image/svg+xml," + encoded
    }

    /// What `encodeURIComponent` leaves alone.
    private static let uriSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()",
    )
}
