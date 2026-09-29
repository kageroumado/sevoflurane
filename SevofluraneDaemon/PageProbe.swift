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

    /// One probe covers the whole chain the UI depends on: app page → bridge
    /// WebSocket → page eval and back. The bridge always answers HTTP 200 with
    /// `ok: false` carrying the failure ("no page connected", eval timeout),
    /// so an HTTP-level failure specifically means the bridge itself is down.
    /// A bridge that refuses the control token counts as down too: reloading
    /// the page cannot fix a token neither process can read.
    ///
    /// The expression asks Steam's own app object whether its stores finished
    /// initializing. A bare eval is not enough: the page runs in the app's
    /// WKWebView and keeps answering evals after the client's UI session dies
    /// (steamwebhelper hang, regression to the login window) — a state where
    /// CDP still lists SharedJSContext and the user sees a frozen splash.
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

    /// How long `steam.exe` has to answer ``nativeAnswers()``. The install
    /// manager's state is one message to its main thread, answered in
    /// milliseconds whenever that thread runs.
    static let nativeTimeout: Duration = .seconds(5)

    /// Whether `steam.exe` itself answers: a call its main thread serves, timed.
    /// Services stay initialized while that thread is stuck in a wait, and the
    /// page keeps answering evals, so this is the one probe that sees it. Nil
    /// when the page gives no answer at all.
    static func nativeAnswers() async -> Bool? {
        let milliseconds = Int(nativeTimeout.components.seconds * 1000)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(BridgePorts.steamUI)/__eval")!)
        request.httpMethod = "POST"
        request.httpBody = Data("""
        new Promise(function (resolve) {
          SteamClient.Installs.GetInstallManagerInfo().then(function () { resolve("answered"); });
          setTimeout(function () { resolve("silent"); }, \(milliseconds));
        })
        """.utf8)
        request.timeoutInterval = 30
        ControlToken.authorize(&request)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        struct Reply: Decodable { let ok: Bool; let v: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.ok else { return nil }
        return reply.v?.contains("answered") == true
    }
}
