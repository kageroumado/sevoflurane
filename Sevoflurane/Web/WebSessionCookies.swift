import Foundation
import os
import WebKit

/// Mirrors the bottled client's authenticated web session into the app's
/// WKWebView cookie jar, so the store, community, and help pages render
/// signed in (`Docs/release-plan.md` R5.1).
///
/// Steam's web properties authenticate with a `steamLoginSecure` cookie the
/// client already holds for every Steam domain — it mints them at sign-in
/// through `login.steampowered.com/jwt/finalizelogin` and refreshes them on
/// its own schedule. Re-minting our own session would mean holding the
/// account's refresh token, which the client does not hand out
/// (`Auth.GetRefreshInfo` returns an id, never the token). Copying the jar it
/// already maintains needs no credentials and stays correct by construction:
/// whatever the client is signed in as, the web views are too.
@MainActor
enum WebSessionCookies {
    /// Cookies are mirrored for Steam's own web properties only; the client's
    /// jar also holds `steamloopback.host` entries, which belong to the local
    /// UI origin and mean nothing to a remote page.
    private static let domains = [
        "steampowered.com",
        "steamcommunity.com",
        "steamchina.com",
        "steam-chat.com",
        "csgo.com.cn",
    ]

    /// The live bridge, wired once at app start — the same one-assignment
    /// pattern as ``ClientLifecycle/log``.
    static var bridge: SteamBridge?

    private static var inFlight: Task<Void, Never>?

    /// Starts a fresh mirror pass. Called at startup and whenever Steam
    /// creates an embedded browser, so a session that rotated while the app
    /// was idle is picked up before the page loads.
    static func refresh() {
        let previous = inFlight
        inFlight = Task {
            // Passes never overlap: a second `setCookie` for the same name
            // while the first is in flight is a race over which value wins.
            await previous?.value
            await syncNow()
        }
    }

    /// Waits for the current mirror pass, if any. A load that races the pass
    /// renders signed out, so browser views await this before loading.
    static func settled() async {
        await inFlight?.value
    }

    /// Copies the client's Steam-domain cookies into the default website data
    /// store, replacing what was there. Returns how many landed.
    @discardableResult
    static func syncNow() async -> Int {
        // One CDP read plus one network-process round trip per cookie, all
        // before a browser view may load: the interval is that critical path.
        let mirror = PerfProbe.bridge.beginInterval("CookieMirror")
        guard let bridge, let raw = await bridge.clientCookies() else {
            PerfProbe.bridge.endInterval("CookieMirror", mirror, "applied=0")
            return 0
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        var applied = 0
        for cookie in raw.compactMap(httpCookie) {
            await store.setCookie(cookie)
            applied += 1
        }
        PerfProbe.bridge.endInterval("CookieMirror", mirror, "applied=\(applied, privacy: .public)")
        if applied > 0 {
            EventLog.shared.log(.page, "web session: \(applied) client cookies mirrored")
        }
        return applied
    }

    static func isSteamDomain(_ domain: String) -> Bool {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return domains.contains { bare == $0 || bare.hasSuffix("." + $0) }
    }

    /// Translates one client cookie into an `HTTPCookie`, dropping anything
    /// outside Steam's own web properties.
    static func httpCookie(from cookie: SteamWebCookie) -> HTTPCookie? {
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
        if let expires = cookie.expires {
            // Foundation caps a cookie's lifetime at 400 days (measured), so a
            // longer-lived client cookie lands shortened here. Harmless: the
            // mirror re-runs per browser view, well inside any cap.
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }
        return HTTPCookie(properties: properties)
    }
}
