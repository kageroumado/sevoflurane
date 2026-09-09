import Foundation
import Testing
@testable import Sevoflurane

/// Which URLs may leave the page through the bridge's proxy, and which are
/// refused at the door. The allowlist is the whole security story of `/__web`.
struct WebProxyTests {
    private func target(_ url: String, method: String = "GET") -> Result<URL, WebProxy.Rejection> {
        WebProxy.target(
            method: method,
            query: "u=" + (url.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics,
            ) ?? url),
        )
    }

    private func rejection(_ result: Result<URL, WebProxy.Rejection>) -> WebProxy.Rejection? {
        guard case let .failure(rejection) = result else { return nil }
        return rejection
    }

    @Test
    func `the eula url is proxied`() {
        let eula = "https://store.steampowered.com/eula/1091500_eula_0?eulaLang=english&json=1"
        guard case let .success(url) = target(eula) else {
            Issue.record("the store must be reachable through the proxy")
            return
        }
        #expect(url.absoluteString == eula)
    }

    @Test
    func `subdomains of a steam property are reachable`() {
        #expect(rejection(target("https://api.steampowered.com/ISteamApps/GetAppList/v2")) == nil)
        #expect(rejection(target("https://steamcommunity.com/id/me")) == nil)
    }

    @Test
    func `the proxy is not an open relay`() {
        #expect(rejection(target("https://example.com/")) == .hostNotAllowed("example.com"))
        // The suffix match is on a label boundary, so a host that merely ends
        // in the allowlisted text is a different host.
        #expect(
            rejection(target("https://evil-steampowered.com/"))
                == .hostNotAllowed("evil-steampowered.com"),
        )
        #expect(
            rejection(target("https://store.steampowered.com.attacker.net/"))
                == .hostNotAllowed("store.steampowered.com.attacker.net"),
        )
    }

    @Test
    func `only web schemes and read methods are accepted`() {
        #expect(rejection(target("file:///etc/passwd")) == .unsupportedScheme("file"))
        #expect(rejection(target("steam://run/1091500")) == .unsupportedScheme("steam"))
        #expect(
            rejection(target("https://store.steampowered.com/", method: "POST"))
                == .badMethod("POST"),
        )
        #expect(rejection(WebProxy.target(method: "GET", query: "")) == .missingURL)
    }
}
