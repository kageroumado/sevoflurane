import Foundation
import os

/// One connection to the bottled client's `SharedJSContext` over the Chrome
/// DevTools Protocol: `evaluate()` plus the `__sevo` binding's push events.
actor CDPClient {
    enum Failure: Error, Equatable {
        case unreachable(String)
        /// Something is listening and did not answer inside the timeout. A
        /// mute server is a different fault from an absent one: one is a
        /// client under load, the other is a client that is gone.
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

    /// Wine binds the debug port to whichever loopback family it feels like on
    /// a given run, so the reachable one is discovered rather than assumed.
    ///
    /// Every discovery opens a fresh connection, on a session of its own. A
    /// pooled connection can predate the client: anything else listening on
    /// the port (a wildcard-bound dev server on the same machine) accepts the
    /// probe, and the shared pool then keeps every later probe glued to that
    /// connection even once the client's own listener is up. An unpooled
    /// connect always lands on the client's specific-address bind.
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

    /// How long the handshake may take. Every other call is bounded by its
    /// caller, whose budget it knows; the handshake has one budget wherever
    /// it is made.
    static let connectBudget: Duration = .seconds(5)

    /// Opens the socket within ``connectBudget``. A handshake that fails or
    /// runs out of time leaves the client closed.
    ///
    /// `consumingBindings` enables the `Runtime` domain, which only the
    /// bridge's persistent connection needs: `Runtime.bindingCalled` is what
    /// carries the client's callbacks back, and `Runtime.evaluate` answers
    /// without the domain enabled; one-shot sessions leave it off.
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

    /// One-shot sessions get an ephemeral session of their own, invalidated
    /// with the socket: on the shared session they compete with the bridge's
    /// persistent connection for the six connections `URLSession` allows per
    /// host, and a cancelled task can sit in that pool.
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
        // Pushes are delivered on their own task, in order, so the receive
        // loop never waits on the bridge: a reply to a pending call must not
        // queue behind a push whose handler is busy elsewhere.
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

    /// One-shot evaluate against a specific target's debugger socket —
    /// connect, evaluate, disconnect. The bridge's persistent connection
    /// stays on `SharedJSContext`; this is for the asks that stand outside
    /// it, the shutdown ask and the standing scripts in the client's own
    /// friends UI.
    ///
    /// It spends a permit from ``CDPBudget`` for its whole life, because a
    /// session is what CEF's one DevTools thread pays for.
    static func evaluateOnce(socketURL: URL, _ expression: String) async throws -> String? {
        try await CDPBudget.spend("one-shot evaluate") {
            let client = CDPClient(onPush: { _ in })
            // `connect` sits inside the cleanup scope: a cancelled handshake
            // must close the socket, pump and push stream like a failed
            // evaluate.
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

    /// Evaluates `expression` with `returnByValue` + `awaitPromise` and returns
    /// the value: strings verbatim, other scalars as their JSON text, `nil`
    /// for null/undefined. A script that throws, or a promise that rejects,
    /// throws ``Failure/scriptThrew(_:)``.
    func evaluate(_ expression: String) async throws -> String? {
        let reply = try await send(method: "Runtime.evaluate", params: [
            "expression": expression, "returnByValue": true, "awaitPromise": true,
        ])
        return try Self.value(fromEvaluateReply: reply)
    }

    /// The value a `Runtime.evaluate` reply carries, rendered as
    /// ``evaluate(_:)`` returns it.
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

    /// The client's whole CEF cookie jar. `Storage.getCookies` is a
    /// browser-wide read that a page session answers too, so this reuses the
    /// connection the bridge already holds instead of opening a second one.
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
        // Reply, socket error, closure and cancellation all resume the
        // continuation through `pending.removeValue(forKey:)`, so whichever
        // arrives first is the only one that resumes it. The cancellation
        // handler's task cannot reach `fail` before the insertion below: both
        // wrappers run their bodies synchronously on this actor. No `await`
        // may sit between entering the operation and `pending[id] = …`, or
        // that ordering is gone.
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
        // A close frame, not a dropped connection: CEF then tears the
        // session down itself instead of discovering a transport that
        // stopped answering.
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        ephemeralSession?.finishTasksAndInvalidate()
        ephemeralSession = nil
    }
}
