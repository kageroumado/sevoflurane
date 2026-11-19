import Foundation
import os

/// One connection to the bottled client's `SharedJSContext` over the Chrome
/// DevTools Protocol: `evaluate()` plus the `__sevo` binding's push events.
actor CDPClient {
    enum Failure: Error, Equatable {
        case unreachable(String)
        /// Something listens but did not answer in time: a loaded client,
        /// unlike a gone one.
        case unanswered(String)
        case closed
        case badReply(String)
        /// CDP refused the call itself: an unknown method, bad parameters.
        case protocolError(String)
        /// The evaluated script threw; the payload is the exception's
        /// description as the client renders it.
        case scriptThrew(String)
    }

    /// Fires for every `Runtime.bindingCalled` payload on the `__sevo` binding.
    private let onPush: @Sendable (String) async -> Void
    private var task: URLSessionWebSocketTask?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<String?, any Error>] = [:]
    private(set) var isClosed = false

    init(onPush: @escaping @Sendable (String) async -> Void) {
        self.onPush = onPush
    }

    /// Tries both loopback families, since Wine binds either. Each discovery
    /// uses its own session: a pooled connection to a wildcard-bound listener
    /// on the same port would keep later probes off the client's bind.
    static func discoverTargets(port: Int, timeout: TimeInterval = 3) async throws -> [[String: Any]] {
        try await CDPBudget.spend("target discovery") {
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            var wentUnanswered = false
            for host in ["127.0.0.1", "[::1]"] {
                guard let url = URL(string: "http://\(host):\(port)/json") else { continue }
                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                let data: Data
                do {
                    (data, _) = try await session.data(for: request)
                } catch {
                    wentUnanswered = wentUnanswered || (error as? URLError)?.code == .timedOut
                    continue
                }
                if let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    return targets
                }
            }
            if wentUnanswered {
                throw Failure.unanswered(
                    "CDP on port \(port) accepted the connection and said nothing",
                )
            }
            throw Failure.unreachable("no CDP endpoint on port \(port) (is Steam up?)")
        }
    }

    func connect(port: Int, targetTitle: String = "SharedJSContext") async throws {
        let targets = try await Self.discoverTargets(port: port)
        guard let shared = targets.first(where: { $0["title"] as? String == targetTitle }),
              let socketURL = (shared["webSocketDebuggerUrl"] as? String).flatMap(URL.init) else {
            throw Failure.unreachable("no \(targetTitle) target (half-wedged client?)")
        }
        try await connect(socketURL: socketURL, consumingBindings: true)
        _ = try await send(method: "Runtime.addBinding", params: ["name": "__sevo"])
    }

    /// The handshake's bound; every other call is bounded by its caller.
    static let connectBudget: Duration = .seconds(5)

    /// Opens the socket within ``connectBudget``, closed on failure.
    /// `consumingBindings` enables the `Runtime` domain for
    /// `Runtime.bindingCalled`; `Runtime.evaluate` works without it.
    func connect(socketURL: URL, consumingBindings: Bool) async throws {
        do {
            try await withDeadline(Self.connectBudget) {
                try await self.handshake(socketURL: socketURL, consumingBindings: consumingBindings)
            }
        } catch {
            markClosed()
            throw error
        }
    }

    /// A one-shot's own session: on the shared one it competes with the
    /// bridge for six connections per host, and cancelled tasks linger there.
    private var ephemeralSession: URLSession?

    private func handshake(socketURL: URL, consumingBindings: Bool) async throws {
        let session: URLSession
        if consumingBindings {
            session = .shared
        } else {
            session = URLSession(configuration: .ephemeral)
            ephemeralSession = session
        }
        let socket = session.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 64 * 1024 * 1024
        task = socket
        socket.resume()
        // Pushes run on their own task so a reply never queues behind a busy
        // push handler.
        let (pushes, pushContinuation) = AsyncStream.makeStream(of: String.self)
        pushSink = pushContinuation
        Task { [onPush] in
            for await payload in pushes {
                await onPush(payload)
            }
        }
        Task { await pump() }
        guard consumingBindings else { return }
        _ = try await send(method: "Runtime.enable", params: [:])
    }

    private var pushSink: AsyncStream<String>.Continuation?

    func disconnect() {
        markClosed()
    }

    /// Connect, evaluate, disconnect, holding a ``CDPBudget`` permit
    /// throughout, since CEF's one DevTools thread pays per session.
    static func evaluateOnce(socketURL: URL, _ expression: String) async throws -> String? {
        try await CDPBudget.spend("one-shot evaluate") {
            let client = CDPClient(onPush: { _ in })
            // A cancelled handshake must clean up too.
            do {
                try await client.connect(socketURL: socketURL, consumingBindings: false)
                let value = try await client.evaluate(expression)
                await client.disconnect()
                return value
            } catch {
                await client.disconnect()
                throw error
            }
        }
    }

    /// Evaluates with `returnByValue` and `awaitPromise`: strings verbatim,
    /// other values as JSON, `nil` for null; a throw or rejection throws
    /// ``Failure/scriptThrew(_:)``.
    func evaluate(_ expression: String) async throws -> String? {
        let reply = try await send(method: "Runtime.evaluate", params: [
            "expression": expression, "returnByValue": true, "awaitPromise": true,
        ])
        return try Self.value(fromEvaluateReply: reply)
    }

    /// The value of a `Runtime.evaluate` reply, as ``evaluate(_:)`` returns it.
    nonisolated static func value(fromEvaluateReply reply: [String: Any]) throws -> String? {
        let outer = reply["result"] as? [String: Any]
        if let details = outer?["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            let description = exception?["description"] as? String
                ?? (exception?["value"]).map { "\($0)" }
                ?? details["text"] as? String
                ?? "exception"
            throw Failure.scriptThrew(description)
        }
        let value = (outer?["result"] as? [String: Any])?["value"]
        switch value {
        case nil, is NSNull:
            return nil
        case let text as String:
            return text
        default:
            let data = try? JSONSerialization.data(
                withJSONObject: value as Any,
                options: [.fragmentsAllowed],
            )
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// The client's whole CEF cookie jar, which a page session can read.
    func cookies() async throws -> [SteamWebCookie] {
        let reply = try await send(method: "Storage.getCookies", params: [:])
        let result = reply["result"] as? [String: Any]
        guard let cookies = result?["cookies"] as? [[String: Any]] else {
            throw Failure.badReply("Storage.getCookies")
        }
        return cookies.compactMap(SteamWebCookie.init(cdp:))
    }

    private func send(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let task, !isClosed else { throw Failure.closed }
        nextID += 1
        let id = nextID
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.badReply("unencodable request")
        }
        let call = PerfProbe.bridge.beginInterval(
            "CDPCall", id: PerfProbe.bridge.makeSignpostID(), "\(method, privacy: .public)",
        )
        defer { PerfProbe.bridge.endInterval("CDPCall", call, "\(method, privacy: .public)") }
        try Task.checkCancellation()
        // Every path resumes through `pending.removeValue(forKey:)`, so only
        // the first does. Never put an `await` before `pending[id] = …`: the
        // cancellation `fail` must not run before the insertion.
        let raw: String? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                task.send(.string(text)) { error in
                    if let error {
                        Task { await self.fail(id: id, error: error) }
                    }
                }
            }
        } onCancel: {
            Task { await self.fail(id: id, error: CancellationError()) }
        }
        guard let raw,
              let reply = try? JSONSerialization.jsonObject(with: Data(raw.utf8))
              as? [String: Any] else {
            throw Failure.badReply(method)
        }
        if let error = reply["error"] as? [String: Any] {
            throw Failure.protocolError("\(method): \(error["message"] as? String ?? "error")")
        }
        return reply
    }

    private func fail(id: Int, error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func pump() async {
        guard let task else { return }
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                markClosed()
                return
            }
            guard case let .string(raw) = message,
                  let reply = try? JSONSerialization.jsonObject(with: Data(raw.utf8))
                  as? [String: Any] else { continue }
            if let id = reply["id"] as? Int {
                // A second reply for one id must not double-resume.
                if let continuation = pending.removeValue(forKey: id) {
                    continuation.resume(returning: raw)
                }
            } else if reply["method"] as? String == "Runtime.bindingCalled",
                      let params = reply["params"] as? [String: Any],
                      params["name"] as? String == "__sevo",
                      let payload = params["payload"] as? String {
                pushSink?.yield(payload)
            }
        }
    }

    private func markClosed() {
        isClosed = true
        for continuation in pending.values {
            continuation.resume(throwing: Failure.closed)
        }
        pending.removeAll()
        pushSink?.finish()
        pushSink = nil
        // A close frame, so CEF tears the session down itself.
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        ephemeralSession?.finishTasksAndInvalidate()
        ephemeralSession = nil
    }
}
