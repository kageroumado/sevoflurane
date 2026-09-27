import Foundation

/// One cookie from the bottled client's jar, as CDP reports it — the typed
/// form that crosses the bridge actor's boundary.
nonisolated struct SteamWebCookie: Sendable, Equatable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    /// Hidden from `document.cookie`: Steam's session token is one.
    let httpOnly: Bool
    /// CDP's `Strict`, `Lax` or `None`, or nil when the client set none.
    let sameSite: String?
    /// Seconds since the epoch, or nil for a session cookie — CDP reports
    /// those as `-1`, which would otherwise become an expiry in 1969.
    let expires: Double?

    init?(cdp: [String: Any]) {
        guard let name = cdp["name"] as? String,
              let value = cdp["value"] as? String,
              let domain = cdp["domain"] as? String else { return nil }
        self.name = name
        self.value = value
        self.domain = domain
        path = cdp["path"] as? String ?? "/"
        secure = cdp["secure"] as? Bool ?? false
        httpOnly = cdp["httpOnly"] as? Bool ?? false
        sameSite = cdp["sameSite"] as? String
        expires = (cdp["expires"] as? Double).flatMap { $0 > 0 ? $0 : nil }
    }
}
