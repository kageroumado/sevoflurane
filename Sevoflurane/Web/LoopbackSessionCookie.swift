import Foundation
import WebKit

/// Puts ``LoopbackSession``'s cookie where the app's own requests to the
/// bridge will carry it.
@MainActor
enum LoopbackSessionCookie {
    /// Foundation has no constant for either key.
    private static let httpOnlyKey = HTTPCookiePropertyKey("HttpOnly")

    /// Idempotent: the value is fixed for the launch.
    static func install() async {
        // Every web view: the page, its popups, and its socket's handshake.
        // Strict keeps it off any request another site starts, a navigation
        // of one of these web views included.
        if let cookie = cookie(path: "/", sameSite: .sameSiteStrict) {
            await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        }
        // `URLSession`, for the menu bar's capsule art. Scoped to that path:
        // the same session talks to the control and DevTools ports, which
        // must never be handed this.
        if let cookie = cookie(path: "/art/", sameSite: nil) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    private static func cookie(path: String, sameSite: HTTPCookieStringPolicy?) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: LoopbackSession.cookieName,
            .value: LoopbackSession.key,
            .domain: "127.0.0.1",
            .path: path,
            .discard: "TRUE",
            httpOnlyKey: "TRUE",
        ]
        if let sameSite { properties[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: properties)
    }
}
