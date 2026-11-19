import Foundation
import os
import WebKit

/// Mirrors the bottled client's Steam cookies (`steamLoginSecure` among them)
/// into WebKit's jar, so the store, community and help pages render signed
/// in as the client. Minting a session would need the refresh token, which
/// the client never hands out (`Auth.GetRefreshInfo` returns an id).
@MainActor
enum WebSessionCookies {
    /// Steam's web properties: the hosts cookies are mirrored for and
    /// ``WebProxy`` fetches. The jar's `steamloopback.host` entries are left
    /// out.
    nonisolated static let domains = [
        "steampowered.com",
        "steamcommunity.com",
        "steamchina.com",
        "steam-chat.com",
        "csgo.com.cn",
    ]

    /// The live bridge, assigned once at app start.
    static var bridge: SteamBridge?

    private static var inFlight: Task<Void, Never>?

    /// Starts a mirror pass; called at startup and for every new embedded
    /// browser, so a rotated session lands before the page loads.
    static func refresh() {
        let previous = inFlight
        inFlight = Task {
            // Serialized: overlapping `setCookie`s race over which value wins.
            await previous?.value
            await syncNow()
        }
    }

    /// Waits for the current pass; a load racing it renders signed out.
    static func settled() async {
        await inFlight?.value
    }

    /// What earlier passes wrote, so a pass writes only the difference: each
    /// `setCookie` is a network-process round trip on a browser view's load
    /// path.
    private static var lastApplied: [String: SteamWebCookie] = [:]

    /// Copies the client's Steam-domain cookies into the default website data
    /// store. Returns how many landed.
    @discardableResult
    static func syncNow() async -> Int {
        // The critical path before a browser view may load.
        let mirror = PerfProbe.bridge.beginInterval("CookieMirror")
        guard let bridge, let raw = await bridge.clientCookies() else {
            PerfProbe.bridge.endInterval("CookieMirror", mirror, "applied=0")
            return 0
        }
        let fresh = raw.filter { isSteamDomain($0.domain) }
        let delta = changedCookies(in: fresh, since: lastApplied)
        let store = WKWebsiteDataStore.default().httpCookieStore
        var applied = 0
        for cookie in delta {
            guard let httpCookie = httpCookie(from: cookie) else { continue }
            await store.setCookie(httpCookie)
            lastApplied[identity(of: cookie)] = cookie
            applied += 1
        }
        PerfProbe.bridge.endInterval(
            "CookieMirror", mirror,
            "applied=\(applied, privacy: .public),unchanged=\(fresh.count - delta.count, privacy: .public)",
        )
        if applied > 0 {
            EventLog.shared.log(
                .page,
                "web session: \(applied) client cookies mirrored (\(fresh.count - delta.count) unchanged)",
            )
        }
        return applied
    }

    nonisolated static func identity(of cookie: SteamWebCookie) -> String {
        "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
    }

    /// The cookies that differ from what a previous pass applied. Deletions
    /// are not mirrored; WebKit's expiry retires the stale cookie.
    nonisolated static func changedCookies(
        in cookies: [SteamWebCookie], since applied: [String: SteamWebCookie],
    ) -> [SteamWebCookie] {
        cookies.filter { applied[identity(of: $0)] != $0 }
    }

    nonisolated static func isSteamDomain(_ domain: String) -> Bool {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return domains.contains { bare == $0 || bare.hasSuffix("." + $0) }
    }

    /// The key `HTTPCookie` reads `isHTTPOnly` from; Foundation has no
    /// constant for it.
    private nonisolated static let httpOnlyKey = HTTPCookiePropertyKey("HttpOnly")

    /// One client cookie as an `HTTPCookie`; nil outside Steam's domains.
    nonisolated static func httpCookie(from cookie: SteamWebCookie) -> HTTPCookie? {
        guard isSteamDomain(cookie.domain) else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: cookie.path,
        ]
        if cookie.secure {
            properties[.secure] = "TRUE"
        }
        if cookie.httpOnly {
            properties[httpOnlyKey] = "TRUE"
        }
        switch cookie.sameSite?.lowercased() {
        case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        case "lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        default: break
        }
        if let expires = cookie.expires {
            // Foundation caps lifetimes at 400 days; the mirror re-runs well
            // inside that.
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }
        return HTTPCookie(properties: properties)
    }
}
