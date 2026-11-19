import Foundation
import Network

/// One parsed HTTP request, as delivered to an ``HTTPServer`` handler.
nonisolated struct HTTPRequest: Sendable, Equatable {
    let method: String
    /// The full request target, query string included.
    let target: String
    /// Header fields, names lowercased.
    let headers: [String: String]
    let body: Data

    var path: String {
        String(target.prefix(while: { $0 != "?" }))
    }
    var query: String {
        guard let mark = target.firstIndex(of: "?") else { return "" }
        return String(target[target.index(after: mark)...])
    }
}

/// The handler's answer; written verbatim plus `Content-Length`. A `HEAD`
/// request is answered with the same headers and no body.
nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var reason: String
    var headers: [(String, String)]
    var body: Data
    /// The `Content-Length` a bodiless answer to `HEAD` declares: the length
    /// of what `GET` would return, when the handler knows it without reading
    /// it. Nil declares `body`'s own length.
    var headLength: Int?

    static func ok(
        _ body: Data,
        type: String,
        headers extra: [(String, String)] = [],
    ) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            reason: "OK",
            headers: [("Content-Type", type)] + extra,
            body: body,
        )
    }

    static func redirect(to location: String) -> HTTPResponse {
        HTTPResponse(
            status: 302,
            reason: "Found",
            headers: [("Location", location)],
            body: Data(),
        )
    }

    static func error(_ status: Int, _ reason: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            reason: reason,
            headers: [("Content-Type", "text/plain")],
            body: Data("\(status) \(reason)".utf8),
        )
    }
}

/// A minimal loopback HTTP/1.1 server on Network.framework: keep-alive, one
/// async handler, 127.0.0.1 only.
final nonisolated class HTTPServer: Sendable {
    private let listener: NWListener
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let gate: LoopbackGate
    /// Per-instance: the UI and art servers must not interleave on one
    /// serial queue.
    private let queue: DispatchQueue

    /// Why an exclusive listener did not come up.
    enum StartFailure: Error, Equatable {
        /// Another process holds the port.
        case portIsTaken(UInt16)
        case listenerFailed(String)
    }

    private let port: UInt16

    /// - Parameter exclusive: Whether the port is held alone. Required for
    ///   anything that owns state: two listeners on the control port would
    ///   split requests between two supervisors.
    init(
        port: UInt16,
        gate: LoopbackGate,
        exclusive: Bool = false,
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
    ) throws {
        self.handler = handler
        self.gate = gate
        self.port = port
        queue = DispatchQueue(label: "sevo.http.\(port)", qos: .userInitiated)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
        )
        parameters.allowLocalEndpointReuse = !exclusive
        listener = try NWListener(using: parameters)
    }

    func start() {
        let gated = Self.gated(handler, by: gate)
        let open = OpenConnections()
        listener.newConnectionHandler = { [queue, port] connection in
            switch open.admit(connection) {
            case .refused:
                open.note("refusing a connection: every one of \(Self.connectionLimit) is serving", port: port)
                connection.cancel()
                return
            case let .evicting(silent):
                open.note("at \(Self.connectionLimit) connections; closing the oldest that sent nothing", port: port)
                silent.cancel()
            case .admitted:
                break
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled: open.leave(connection)
                default: break
                }
            }
            connection.start(queue: queue)
            Self.serve(connection, open: open, handler: gated, leftover: Data())
        }
        listener.start(queue: queue)
    }

    /// How many connections one server holds open at once. Any local process
    /// can connect before the gate sees a request, so each one is bounded.
    static let connectionLimit = 64
    /// How long a connection may take to deliver a whole request, counted
    /// from when the server starts waiting for it; a handler's own time is
    /// not counted.
    static let requestDeadline: Duration = .seconds(30)

    /// The open connections and which of them are waiting for a request. At
    /// the limit a new connection takes the place of the one that has waited
    /// longest, so connections that never send anything cannot lock out a
    /// client whose request arrives in milliseconds.
    private final class OpenConnections: @unchecked Sendable {
        enum Admission {
            case admitted
            case evicting(NWConnection)
            case refused
        }

        private struct Open {
            let connection: NWConnection
            /// When it began waiting for its next request; nil while one is served.
            var waitingSince: ContinuousClock.Instant?
        }

        private let lock = NSLock()
        private var open: [ObjectIdentifier: Open] = [:]
        private var lastNote: ContinuousClock.Instant?

        func admit(_ connection: NWConnection) -> Admission {
            lock.withLock {
                var admission = Admission.admitted
                if open.count >= HTTPServer.connectionLimit {
                    let oldest = open.compactMap { key, entry in
                        entry.waitingSince.map { (key: key, connection: entry.connection, since: $0) }
                    }.min { $0.since < $1.since }
                    guard let oldest else { return .refused }
                    open[oldest.key] = nil
                    admission = .evicting(oldest.connection)
                }
                open[ObjectIdentifier(connection)] = Open(connection: connection, waitingSince: .now)
                return admission
            }
        }

        func waiting(_ connection: NWConnection) {
            lock.withLock { open[ObjectIdentifier(connection)]?.waitingSince = .now }
        }

        func serving(_ connection: NWConnection) {
            lock.withLock { open[ObjectIdentifier(connection)]?.waitingSince = nil }
        }

        /// Idempotent: an evicted connection is already gone when its cancel arrives.
        func leave(_ connection: NWConnection) {
            lock.withLock { open[ObjectIdentifier(connection)] = nil }
        }

        /// At most once a minute, so a flood does not fill the log.
        func note(_ message: String, port: UInt16) {
            let due = lock.withLock {
                if let lastNote, ContinuousClock.now - lastNote < .seconds(60) { return false }
                lastNote = .now
                return true
            }
            if due { EventLog.enqueue(.bridge, ":\(port) \(message)") }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func first() -> Bool {
            lock.withLock {
                defer { done = true }
                return !done
            }
        }
    }

    /// Starts and returns once the port is held, or throws when another
    /// process holds it, the listener is cancelled, or it has not bound within
    /// ``bindBudget``. An exclusive listener's failure arrives only on its
    /// state handler.
    func startWaitingForThePort() async throws {
        try await Self.waitUntilBound(listener, port: port, on: queue) { self.start() }
    }

    /// Runs `start` and returns once `listener` holds its port; otherwise
    /// cancels it and throws. A page is sent only to ports this process
    /// bound: whoever holds one receives what the page sends there.
    static func waitUntilBound(
        _ listener: NWListener, port: UInt16, on queue: DispatchQueue, start: @escaping @Sendable () -> Void,
    ) async throws {
        let outcome = Outcome()
        do {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        outcome.finish(waiter, with: .success(()))
                    case let .failed(error):
                        let taken = error == .posix(.EADDRINUSE) || error == .posix(.EADDRNOTAVAIL)
                        outcome.finish(waiter, with: .failure(
                            taken ? StartFailure.portIsTaken(port)
                                : StartFailure.listenerFailed(error.localizedDescription),
                        ))
                    case .cancelled:
                        outcome.finish(waiter, with: .failure(StartFailure.listenerFailed("cancelled")))
                    default:
                        break
                    }
                }
                queue.asyncAfter(deadline: .now() + bindBudget) {
                    outcome.finish(waiter, with: .failure(
                        StartFailure.listenerFailed("not bound after \(Int(bindBudget)) s"),
                    ))
                }
                start()
            }
        } catch {
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw error
        }
        listener.stateUpdateHandler = nil
    }

    /// How long a listener may take to bind a loopback port.
    static let bindBudget: TimeInterval = 10

    /// The handler behind the gate: a request the gate refuses never reaches
    /// it, and is answered 403 for its `Host` or `Origin` and 401 for its
    /// token.
    private static func gated(
        _ handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
        by gate: LoopbackGate,
    ) -> @Sendable (HTTPRequest) async -> HTTPResponse {
        { request in
            switch gate.verdict(
                method: request.method, target: request.target, headers: request.headers, body: request.body,
            ) {
            case .admitted:
                return await handler(request)
            case let .refused(reason):
                gate.noteRefusal(reason)
                return .error(403, "Forbidden")
            case let .unauthorized(reason):
                gate.noteRefusal(reason)
                return .error(401, "Unauthorized")
            }
        }
    }

    /// Resumes the wait exactly once, whatever order the listener's states
    /// arrive in.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var isFinished = false

        func finish(
            _ waiter: CheckedContinuation<Void, any Error>, with result: Result<Void, any Error>,
        ) {
            lock.lock()
            let first = !isFinished
            isFinished = true
            lock.unlock()
            guard first else { return }
            waiter.resume(with: result)
        }
    }

    /// Reads one request (headers, then `Content-Length` bytes of body),
    /// answers it, and recurses for keep-alive. `leftover` carries bytes read
    /// past the previous request's end.
    private static func serve(
        _ connection: NWConnection,
        open: OpenConnections,
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
        leftover: Data,
    ) {
        // The deadline and the request race for one claim: a request that
        // arrives late finds its connection already cancelled, and one that
        // arrives in time cancels the sleep.
        open.waiting(connection)
        let claim = Once()
        let deadline = Task {
            try? await Task.sleep(for: requestDeadline)
            if !Task.isCancelled, claim.first() { connection.cancel() }
        }
        readRequest(connection, buffer: leftover) { request, remainder in
            guard claim.first() else { return }
            deadline.cancel()
            open.serving(connection)
            Task {
                let response = await handler(request)
                connection.send(content: wire(response, isHead: request.method == "HEAD"), completion: .contentProcessed { error in
                    if error != nil {
                        connection.cancel()
                    } else {
                        serve(connection, open: open, handler: handler, leftover: remainder)
                    }
                })
            }
        }
    }

    /// Accumulates bytes until `buffer` holds a whole request. A closed or
    /// errored peer is cancelled; a rejected request is answered with
    /// `Connection: close` first.
    private static func readRequest(
        _ connection: NWConnection,
        buffer: Data,
        peerFinished: Bool = false,
        completion: @escaping @Sendable (HTTPRequest, Data) -> Void,
    ) {
        switch parse(buffer) {
        case let .complete(request, rest):
            completion(request, rest)
        case let .malformed(status):
            reject(connection, status: status)
        case .incomplete:
            if peerFinished {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
                guard error == nil, let data, !data.isEmpty else {
                    connection.cancel()
                    return
                }
                var grown = buffer
                grown.append(data)
                readRequest(connection, buffer: grown, peerFinished: done, completion: completion)
            }
        }
    }

    private static func reject(_ connection: NWConnection, status: Int) {
        var response = HTTPResponse.error(status, rejectionReasons[status] ?? "Bad Request")
        response.headers.append(("Connection", "close"))
        connection.send(content: wire(response), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let rejectionReasons: [Int: String] = [
        400: "Bad Request",
        413: "Content Too Large",
        431: "Request Header Fields Too Large",
        501: "Not Implemented",
    ]

    /// The response as bytes: status line, the handler's headers, then a
    /// `Content-Length` and the body. The answer to `HEAD` declares the
    /// length and stops at the headers.
    static func wire(_ response: HTTPResponse, isHead: Bool = false) -> Data {
        var head = "HTTP/1.1 \(response.status) \(oneLine(response.reason))\r\n"
        for (name, value) in response.headers {
            head += "\(oneLine(name)): \(oneLine(value))\r\n"
        }
        let length = isHead ? response.headLength ?? response.body.count : response.body.count
        head += "Content-Length: \(length)\r\n\r\n"
        var data = Data(head.utf8)
        if !isHead { data.append(response.body) }
        return data
    }

    /// `text` without control characters. A reason or header value can carry
    /// request text, and a CR LF in it would end the line and let the caller
    /// write the rest of the response: its own headers and body, served from
    /// this origin.
    static func oneLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        return String(scalars)
    }

    /// The parser's verdict on the front of a receive buffer.
    enum ParseResult: Equatable {
        /// The buffer ends before the request does; read more.
        case incomplete
        /// The bytes are a request this server refuses to frame, with the
        /// status to answer before closing.
        case malformed(status: Int)
        /// One request, plus the bytes read past its end.
        case complete(HTTPRequest, rest: Data)
    }

    /// The header block, request line through the blank line, fits in this
    /// many bytes; anything longer is answered 431.
    static let maxHeaderBytes = 16 * 1024
    /// The largest body the server buffers; anything longer is answered 413.
    static let maxBodyBytes = 1024 * 1024

    /// Frames the first request in `data`.
    ///
    /// The body is exactly `Content-Length` bytes: a missing header means
    /// zero, and the value must be ASCII digits only — `Int` also reads `-1`
    /// and `UInt` reads `+5`, and both would frame a body the request never
    /// carried. Two `Content-Length` fields or any `Transfer-Encoding`, chunked
    /// included, are refused: every client of these loopback servers sends a
    /// sized body, so the server frames exactly one way.
    static func parse(_ data: Data) -> ParseResult {
        let searched = data.prefix(maxHeaderBytes)
        guard let headerEnd = searched.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count >= maxHeaderBytes ? .malformed(status: 431) : .incomplete
        }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .malformed(status: 400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed(status: 400) }
        var headers: [String: String] = [:]
        var contentLengths = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            if name == "content-length" { contentLengths += 1 }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard contentLengths <= 1, headers["transfer-encoding"] == nil else {
            return .malformed(status: headers["transfer-encoding"] == nil ? 400 : 501)
        }
        let bodyLength: Int
        switch headers["content-length"] {
        case nil:
            bodyLength = 0
        case let field?:
            guard !field.isEmpty, field.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
                  let length = Int(field)
            else {
                return .malformed(status: 400)
            }
            guard length <= maxBodyBytes else { return .malformed(status: 413) }
            bodyLength = length
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= bodyLength else { return .incomplete }
        let body = data.subdata(in: bodyStart ..< bodyStart + bodyLength)
        let rest = data.subdata(in: bodyStart + bodyLength ..< data.count)
        let request = HTTPRequest(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            headers: headers,
            body: body,
        )
        return .complete(request, rest: rest)
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
