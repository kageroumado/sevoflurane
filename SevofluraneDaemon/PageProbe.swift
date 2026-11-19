import Foundation

/// Whether the app's page is answering, and whether Steam's own stores
/// finished initializing behind it.
nonisolated enum PageProbe {
    enum State: Equatable {
        /// The page evals; `servicesUp` is whether Steam's stores finished
        /// initializing — the part that dies with the client's UI session.
        case answering(servicesUp: Bool)
        case bridgeDown
        case notAnswering(String)
    }

    /// Probes page → bridge → eval and back. The bridge answers HTTP 200 with
    /// `ok: false` for page failures, so an HTTP failure or a 401 means the
    /// bridge is down. It asks whether Steam's stores initialized, because the
    /// page keeps answering evals after the client's UI session dies.
    static func state() async -> State {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(BridgePorts.steamUI)/__eval")!)
        request.httpMethod = "POST"
        request.httpBody = Data(
            "String(!!(window.App&&App.GetServicesInitialized&&App.GetServicesInitialized()))".utf8,
        )
        request.timeoutInterval = 30
        ControlToken.authorize(&request)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode != 401
        else {
            return .bridgeDown
        }
        struct Reply: Decodable { let ok: Bool; let v: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            return .notAnswering("malformed /__eval reply")
        }
        guard reply.ok else { return .notAnswering(reply.v ?? "eval failed") }
        return .answering(servicesUp: reply.v?.contains("true") == true)
    }

    /// ``MainThreadProbe``'s timed questions to `steam.exe`, the one probe that
    /// sees its main thread parked; nil when the page gives no answer.
    static func nativeAnswers() async -> MainThreadProbe.Answer? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(BridgePorts.steamUI)/__eval")!)
        request.httpMethod = "POST"
        request.httpBody = Data(MainThreadProbe.expression.utf8)
        request.timeoutInterval = 30
        ControlToken.authorize(&request)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        struct Reply: Decodable { let ok: Bool; let v: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.ok else { return nil }
        return MainThreadProbe.answer(from: reply.v)
    }
}
