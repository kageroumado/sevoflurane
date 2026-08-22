import Foundation
import Network

/// One parsed HTTP request, as delivered to an ``HTTPServer`` handler.
nonisolated struct HTTPRequest: Sendable {
    let method: String
    /// The full request target, query string included.
    let target: String
    /// Header fields, names lowercased.
    let headers: [String: String]
    let body: Data

    var path: String { String(target.prefix(while: { $0 != "?" })) }
    var query: String {
        guard let mark = target.firstIndex(of: "?") else { return "" }
        return String(target[target.index(after: mark)...])
    }
}

/// The handler's answer; written verbatim plus `Content-Length`.
nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var reason: String
    var headers: [(String, String)]
    var body: Data

    static func ok(_ body: Data, type: String,
                   headers extra: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK",
                     headers: [("Content-Type", type)] + extra, body: body)
    }

    static func redirect(to location: String) -> HTTPResponse {
        HTTPResponse(status: 302, reason: "Found",
                     headers: [("Location", location)], body: Data())
    }

    static func error(_ status: Int, _ reason: String) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason,
                     headers: [("Content-Type", "text/plain")],
                     body: Data("\(status) \(reason)".utf8))
    }
}

/// A minimal loopback HTTP/1.1 server on Network.framework: keep-alive, one
/// async handler, no TLS, no ranges — the surface Steam's UI bundle and the
/// art cache actually exercise. Listens on 127.0.0.1 only.
nonisolated final class HTTPServer: Sendable {
    private let listener: NWListener
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private static let queue = DispatchQueue(label: "sevo.http", qos: .userInitiated)

    init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.newConnectionHandler = { [handler] connection in
            connection.start(queue: Self.queue)
            Self.serve(connection, handler: handler, leftover: Data())
        }
        listener.start(queue: Self.queue)
    }

    func stop() { listener.cancel() }

    /// Reads one request (headers, then `Content-Length` bytes of body),
    /// answers it, and recurses for keep-alive. `leftover` carries bytes read
    /// past the previous request's end.
    private static func serve(_ connection: NWConnection,
                              handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
                              leftover: Data) {
        readRequest(connection, buffer: leftover) { request, remainder in
            guard let request else {
                connection.cancel()
                return
            }
            Task {
                let response = await handler(request)
                var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
                for (name, value) in response.headers {
                    head += "\(name): \(value)\r\n"
                }
                head += "Content-Length: \(response.body.count)\r\n\r\n"
                var data = Data(head.utf8)
                data.append(response.body)
                connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        connection.cancel()
                    } else {
                        serve(connection, handler: handler, leftover: remainder)
                    }
                })
            }
        }
    }

    private static func readRequest(_ connection: NWConnection, buffer: Data,
                                    completion: @escaping @Sendable (HTTPRequest?, Data) -> Void) {
        if let request = parse(buffer) {
            completion(request.0, request.1)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            guard error == nil, let data, !data.isEmpty else {
                completion(nil, Data())
                return
            }
            var grown = buffer
            grown.append(data)
            if done && parse(grown) == nil {
                completion(nil, Data())
            } else {
                readRequest(connection, buffer: grown, completion: completion)
            }
        }
    }

    /// Returns the first complete request in `data` plus the unconsumed rest,
    /// or nil if more bytes are needed.
    static func parse(_ data: Data) -> (HTTPRequest, Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= bodyLength else { return nil }
        let body = data.subdata(in: bodyStart..<bodyStart + bodyLength)
        let rest = data.subdata(in: bodyStart + bodyLength..<data.count)
        let request = HTTPRequest(method: String(requestLine[0]),
                                  target: String(requestLine[1]),
                                  headers: headers, body: body)
        return (request, rest)
    }
}

nonisolated enum ContentType {
    private static let map: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript",
        "mjs": "text/javascript", "css": "text/css", "json": "application/json",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp",
        "ico": "image/x-icon", "woff": "font/woff", "woff2": "font/woff2",
        "ttf": "font/ttf", "otf": "font/otf", "map": "application/json",
        "wasm": "application/wasm", "webm": "video/webm", "mp4": "video/mp4",
        "txt": "text/plain; charset=utf-8",
    ]

    static func forExtension(_ ext: String) -> String {
        map[ext.lowercased()] ?? "application/octet-stream"
    }
}
