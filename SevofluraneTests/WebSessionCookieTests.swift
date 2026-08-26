import Foundation
import Testing
@testable import Sevoflurane

@MainActor
struct WebSessionCookieTests {
    private func cdp(
        name: String = "steamLoginSecure",
        domain: String = "store.steampowered.com",
        expires: Any = -1,
        secure: Bool = true,
    ) -> [String: Any] {
        [
            "name": name, "value": "abc", "domain": domain, "path": "/",
            "secure": secure, "expires": expires,
        ]
    }

    @Test
    func `session cookies carry no expiry`() throws {
        let parsed = try #require(SteamWebCookie(cdp: cdp()))
        #expect(parsed.expires == nil)
        let cookie = try #require(WebSessionCookies.httpCookie(from: parsed))
        #expect(cookie.expiresDate == nil)
        #expect(cookie.isSecure)
    }

    @Test
    func `expiring cookies keep their date`() throws {
        // A whole second inside Foundation's 400-day cookie-lifetime cap:
        // it silently shortens anything longer and truncates sub-second
        // precision. CDP reports whole seconds anyway.
        let expiry = (Date.now.timeIntervalSince1970 + 30 * 86_400).rounded(.down)
        let parsed = try #require(SteamWebCookie(cdp: cdp(expires: expiry)))
        let cookie = try #require(WebSessionCookies.httpCookie(from: parsed))
        #expect(cookie.expiresDate?.timeIntervalSince1970 == expiry)
        #expect(!cookie.isSessionOnly)
    }

    @Test
    func `steam domains are recognized, including leading dots`() {
        #expect(WebSessionCookies.isSteamDomain("store.steampowered.com"))
        #expect(WebSessionCookies.isSteamDomain(".steamcommunity.com"))
        #expect(WebSessionCookies.isSteamDomain("steam-chat.com"))
        #expect(!WebSessionCookies.isSteamDomain("steamloopback.host"))
        #expect(!WebSessionCookies.isSteamDomain("evil-steampowered.com.attacker.net"))
    }

    @Test
    func `non-steam cookies are dropped`() throws {
        let parsed = try #require(SteamWebCookie(cdp: cdp(domain: "steamloopback.host")))
        #expect(WebSessionCookies.httpCookie(from: parsed) == nil)
    }

    @Test
    func `malformed records are skipped`() {
        #expect(SteamWebCookie(cdp: ["name": "x", "value": "y"]) == nil)
    }
}
