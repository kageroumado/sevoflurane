import Foundation

/// `GET /__web?u=<absolute URL>`: the page's route to Steam's web properties.
///
/// Steam's store allows cross-origin reads only from
/// `https://steamloopback.host`, so from `http://127.0.0.1:8762` WebKit blocks
/// the reply (a launch dialog's EULA fails as axios's "Network Error"). The
/// proxied request is same-origin and carries the client's cookies.
///
/// Only ``WebSessionCookies/domains`` may be fetched, on the first request
/// and every redirect, so this is no open relay.
nonisolated enum WebProxy {
    /// The largest body handed back, far above Steam's documents, to stop a
    /// mistaken URL pulling a video through the bridge.
    static let maximumBodyBytes = 8 * 1024 * 1024

    /// How long an upstream fetch may take before the page gets a retryable
    /// error.
    static let budget: Duration = .seconds(20)

    /// Why a request never left the app, with the status the page sees.
    enum Rejection: Error, Equatable {
        case badMethod(String)
        case missingURL
        case unsupportedScheme(String)
        case hostNotAllowed(String)

        var status: Int {
            switch self {
            case .badMethod: 405
            case .missingURL, .unsupportedScheme: 400
            case .hostNotAllowed: 403
            }
        }

        var reason: String {
            switch self {
            case let .badMethod(method): "Method \(method) Not Allowed"
            case .missingURL: "Bad Request — u must be an absolute URL"
            case let .unsupportedScheme(scheme): "Bad Request — \(scheme) is not a web scheme"
            case let .hostNotAllowed(host): "Forbidden — \(host) is not a Steam host"
            }
        }
    }

    /// The URL a `/__web` request names, after checking method, scheme and
    /// host.
    static func target(method: String, query: String) -> Result<URL, Rejection> {
        guard method == "GET" || method == "HEAD" else {
            return .failure(.badMethod(method))
        }
        let items = URLComponents(string: "http://127.0.0.1/?" + query)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "u" })?.value,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            return .failure(.missingURL)
        }
        guard scheme == "https" || scheme == "http" else {
            return .failure(.unsupportedScheme(scheme))
        }
        guard let host = url.host, WebSessionCookies.isSteamDomain(host) else {
            return .failure(.hostNotAllowed(url.host ?? "no host"))
        }
        return .success(url)
    }

    /// Fetches `url` as the client would. Cookies go into the session's jar
    /// rather than a `Cookie` header, so Foundation applies their domain,
    /// path and `Secure` scoping across redirects.
    static func fetch(
        _ url: URL, method: String, cookies: [SteamWebCookie],
    ) async -> HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        for cookie in cookies.compactMap(WebSessionCookies.httpCookie(from:)) {
            configuration.httpCookieStorage?.setCookie(cookie)
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var built = URLRequest(url: url)
        built.httpMethod = method
        let request = built
        do {
            return try await withDeadline(budget) {
                try await read(request, on: session, wantsBody: method != "HEAD")
            }
        } catch is DeadlineExceeded {
            return .error(504, "Upstream Timed Out")
        } catch {
            return .error(502, "Upstream Unreachable")
        }
    }

    private static func read(
        _ request: URLRequest, on session: URLSession, wantsBody: Bool,
    ) async throws -> HTTPResponse {
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        guard wantsBody else {
            let length = response.expectedContentLength
            return HTTPResponse(
                status: status, reason: reason(for: status),
                headers: [("Content-Type", type), ("Cache-Control", "no-store")],
                body: Data(),
                headLength: length >= 0 ? Int(length) : nil,
            )
        }
        guard response.expectedContentLength <= Int64(maximumBodyBytes) else {
            return .error(502, "Upstream Body Too Large")
        }
        var body = Data()
        if response.expectedContentLength > 0 {
            body.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            body.append(byte)
            if body.count > maximumBodyBytes {
                return .error(502, "Upstream Body Too Large")
            }
        }
        return HTTPResponse(
            status: status, reason: reason(for: status),
            headers: [("Content-Type", type), ("Cache-Control", "no-store")],
            body: body,
        )
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        default: "Status \(status)"
        }
    }

    /// Holds a redirect chain inside the allowlist: Steam's own properties
    /// carry open redirects (`steamcommunity.com/linkfilter/?url=…`).
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void,
        ) {
            let host = request.url?.host
            completionHandler(
                host.map(WebSessionCookies.isSteamDomain) == true ? request : nil,
            )
        }
    }
}
