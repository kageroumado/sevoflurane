import Foundation

/// The daemon's half of the link to Sevoflurane.app.
///
/// The app posts facts to the control port and this dials the app's own
/// listener back for the work only it can do — reloading the page, dismissing
/// Steam's popups, opening the library. Nothing here waits on an answer to a
/// question: a command is a statement, and everything the daemon needs to know
/// arrives as a fact the app posted when it changed.
///
/// An app that is not attached is not an error. The daemon keeps the client
/// alive without one, and the page half resumes when an app attaches again —
/// which is exactly what "a crash must not take a running game down" means.
@MainActor
final class AppLink {
    private(set) var facts = PageFacts()
    private let log = EventLog.shared

    /// Whether an app is attached and still alive. The pid is the whole test:
    /// a crashed app posts no farewell, and a stale fact must not keep the
    /// daemon reloading a page that no longer exists.
    var isAttached: Bool {
        facts.appPID > 0 && kill(facts.appPID, 0) == 0
    }

    /// The app said hello, or one of its facts changed. Answers whether this
    /// is a different app process from the one that was attached — a relaunch
    /// after a crash, or the first one of the session.
    @discardableResult
    func attach(_ incoming: PageFacts) -> Bool {
        let isNew = incoming.appPID != facts.appPID
        facts = incoming
        guard isNew else { return false }
        log.log(.app, "Sevoflurane \(incoming.appVersion) attached (pid \(incoming.appPID))")
        return true
    }

    /// Forgets the app, so every page-side guard reads as "nobody is
    /// rendering Steam" rather than as a page that stopped answering.
    func detach(reason: String) {
        guard facts.appPID > 0 else { return }
        log.log(.app, "Sevoflurane (pid \(facts.appPID)) detached: \(reason)")
        facts = PageFacts()
    }

    /// Drops the app if its process is gone. Called at the top of every probe
    /// cycle, so a crash is noticed within a cycle rather than at the next
    /// command that fails.
    func reapIfGone() {
        guard facts.appPID > 0, kill(facts.appPID, 0) != 0 else { return }
        detach(reason: "the process is gone")
    }

    // MARK: - Commands

    @discardableResult
    func send(_ command: PageCommand) async -> Bool {
        await post("/command?verb=\(command.rawValue)") != nil
    }

    /// Runs a stop with the app told the client is going down: it asks for its
    /// windows again on the way out, and those requests are answered with
    /// nothing while the mark is on.
    func duringClientStop<T>(_ body: () async -> T) async -> T {
        await send(.clientStopBegan)
        let result = await body()
        await send(.clientStopEnded)
        return result
    }

    /// Asks the app to bring the bridge's connection to the client up, and
    /// waits for the fact that says it did. A page is never booted into a
    /// bridge that cannot yet reach the client.
    func connectToClient() async {
        guard isAttached else { return }
        await send(.connectToClient)
        for _ in 0 ..< Int(Timing.connectBudget) where !facts.isClientConnected {
            try? await Task.sleep(for: .seconds(1))
            guard isAttached else { return }
        }
    }

    /// Hides whatever CEF windows the client has on screen, over the bridge's
    /// connection, and answers what it hid — the sign-in window among them is
    /// how the daemon learns the machine is waiting on a human.
    func sweepClientPopups(_ scope: PopupSweepScope) async -> [String] {
        guard isAttached,
              let data = await post("/popups/sweep?scope=\(scope.rawValue)") else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Whether Steam's own stores have finished initializing. Nil when the app
    /// cannot say — no app, or a bridge whose socket is closed — so the boot's
    /// own clock decides what the silence means.
    func servicesReady() async -> Bool? {
        guard isAttached, let data = await post("/services/ready") else { return nil }
        struct Reply: Decodable { let ready: Bool? }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.ready
    }

    func launchGame(appID: Int) async {
        _ = await post("/command/launch?appid=\(appID)")
    }

    /// Mirrors the daemon's verdict into the app, so the menu bar moves with
    /// the state machine rather than a poll behind it.
    func push(_ snapshot: SupervisorSnapshot) async {
        guard isAttached, let body = try? JSONEncoder().encode(snapshot) else { return }
        _ = await post("/state", body: body)
    }

    /// Mirrors one log line into the app's in-memory trail. Both processes
    /// append to the same file; this is what the menu-bar extra and the log
    /// window read.
    func push(_ line: RemoteLogLine) async {
        guard isAttached, let body = try? JSONEncoder().encode(line) else { return }
        _ = await post("/log", body: body)
    }

    /// Whether the app has its debug mode on: a session-only switch the app
    /// owns, read through its own `GET /debug` so `/status` can carry it.
    func debugIsOn() async -> Bool {
        guard isAttached else { return false }
        let request = HTTPRequest(method: "GET", target: "/debug", headers: [:], body: Data())
        let response = await proxy(request)
        guard response.status == 200,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { return false }
        return json["on"] as? Bool == true
    }

    // MARK: - Proxying

    /// Passes one of the app's own verbs through from the control port. The
    /// page, the windows and the benchmarks live in the app, and `sevo` should
    /// not have to know that — it asks the control port for everything.
    func proxy(_ request: HTTPRequest) async -> HTTPResponse {
        guard isAttached else {
            return .error(409, "Sevoflurane is not running")
        }
        var url = URLComponents()
        url.scheme = "http"
        url.host = "127.0.0.1"
        url.port = Int(BridgePorts.appLink)
        url.path = request.path
        url.percentEncodedQuery = request.query.isEmpty ? nil : request.query
        guard let target = url.url else { return .error(500, "bad proxy target") }
        var proxied = URLRequest(url: target)
        proxied.httpMethod = request.method
        proxied.httpBody = request.body.isEmpty ? nil : request.body
        proxied.timeoutInterval = Timing.proxy
        guard let (data, response) = try? await URLSession.shared.data(for: proxied),
              let http = response as? HTTPURLResponse else {
            return .error(504, "Sevoflurane did not answer")
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        return HTTPResponse(
            status: http.statusCode,
            reason: http.statusCode == 200 ? "OK" : "Error",
            headers: [("Content-Type", type)],
            body: data,
        )
    }

    // MARK: - Transport

    private enum Timing {
        /// How long the app has to bring the bridge's socket up before the
        /// boot goes on without it.
        static let connectBudget: Double = 30
        /// A command is local and the app answers it on its main actor, which
        /// can be busy with a page reload.
        static let command: TimeInterval = 15
        /// A proxied verb can be a benchmark or a window inventory.
        static let proxy: TimeInterval = 120
    }

    private func post(_ path: String, body: Data? = nil) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.appLink)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = Timing.command
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) else {
            return nil
        }
        return data
    }
}
