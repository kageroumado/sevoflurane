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

struct CookieMirrorDiffTests {
    private func cookie(
        _ name: String, value: String, domain: String = "store.steampowered.com",
        path: String = "/", expires: Double? = nil,
    ) -> SteamWebCookie {
        var cdp: [String: Any] = ["name": name, "value": value, "domain": domain, "path": path]
        if let expires { cdp["expires"] = expires }
        return SteamWebCookie(cdp: cdp)!
    }

    @Test
    func `first pass applies everything`() {
        let cookies = [cookie("a", value: "1"), cookie("b", value: "2")]
        #expect(WebSessionCookies.changedCookies(in: cookies, since: [:]).count == 2)
    }

    @Test
    func `unchanged cookies are skipped and changes are kept`() {
        let old = cookie("a", value: "1")
        let same = cookie("a", value: "1")
        let renewed = cookie("b", value: "2", expires: 100)
        let applied = [
            WebSessionCookies.identity(of: old): old,
            WebSessionCookies.identity(of: cookie("b", value: "2")): cookie("b", value: "2"),
        ]
        let delta = WebSessionCookies.changedCookies(in: [same, renewed], since: applied)
        #expect(delta == [renewed])
    }

    @Test
    func `same name on another domain is a different cookie`() {
        let applied = [WebSessionCookies.identity(of: cookie("a", value: "1")): cookie("a", value: "1")]
        let other = cookie("a", value: "1", domain: "steamcommunity.com")
        #expect(WebSessionCookies.changedCookies(in: [other], since: applied) == [other])
    }
}
