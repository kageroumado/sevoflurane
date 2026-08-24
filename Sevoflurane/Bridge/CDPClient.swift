import Foundation

/// One connection to the bottled client's `SharedJSContext` over the Chrome
/// DevTools Protocol: `evaluate()` plus the `__sevo` binding's push events.
actor CDPClient {
    enum Failure: Error {
        case unreachable(String)
        case closed
        case badReply(String)
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
    static func discoverTargets(port: Int) async throws -> [[String: Any]] {
        for host in ["127.0.0.1", "[::1]"] {
            guard let url = URL(string: "http://\(host):\(port)/json") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            guard let (data, _) = try? await URLSession.shared.data(for: request) else {
                continue
            }
            if let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return targets
            }
        }
        throw Failure.unreachable("no CDP endpoint on port \(port) (is Steam up?)")
    }

    func connect(port: Int) async throws {
        let targets = try await Self.discoverTargets(port: port)
        guard let shared = targets.first(where: { $0["title"] as? String == "SharedJSContext" }),
              let socketURL = (shared["webSocketDebuggerUrl"] as? String).flatMap(URL.init) else {
            throw Failure.unreachable("no SharedJSContext target (half-wedged client?)")
        }
        let socket = URLSession.shared.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 64 * 1024 * 1024
        task = socket
        socket.resume()
        Task { await pump() }
        _ = try await send(method: "Runtime.enable", params: [:])
        _ = try await send(method: "Runtime.addBinding", params: ["name": "__sevo"])
    }

    /// Evaluates `expression` with `returnByValue` + `awaitPromise` and returns
    /// the value: strings verbatim, other scalars as their JSON text, `nil`
    /// for null/undefined. Every caller's expression returns a string today.
    func evaluate(_ expression: String) async throws -> String? {
        let reply = try await send(method: "Runtime.evaluate", params: [
            "expression": expression, "returnByValue": true, "awaitPromise": true,
        ])
        let outer = reply["result"] as? [String: Any]
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

    private func send(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let task, !isClosed else { throw Failure.closed }
        nextID += 1
        let id = nextID
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.badReply("unencodable request")
        }
        let raw: String? = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            task.send(.string(text)) { error in
                if let error {
                    Task { await self.fail(id: id, error: error) }
                }
            }
        }
        guard let raw,
              let reply = try? JSONSerialization.jsonObject(with: Data(raw.utf8))
              as? [String: Any] else {
            throw Failure.badReply(method)
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
                await onPush(payload)
            }
        }
    }

    private func markClosed() {
        isClosed = true
        for continuation in pending.values {
            continuation.resume(throwing: Failure.closed)
        }
        pending.removeAll()
        task?.cancel()
        task = nil
    }
}
