import Foundation

/// The daemon's half of the link to Sevoflurane.app: the app posts facts to
/// the control port, and this calls the app's listener for the work only it
/// can do (the page, Steam's popups, the library). No app attached is not an
/// error; the client stays up without one.
@MainActor
final class AppLink {
    private(set) var facts = PageFacts()
    private let log = EventLog.shared

    /// Whether an app is attached and alive; its exit is watched from attach,
    /// since a crashed app posts no farewell.
    var isAttached: Bool {
        facts.appPID > 0
    }

    /// Fires once when the attached app's process exits.
    private var exitWatch: DispatchSourceProcess?

    /// Takes the app's facts; answers whether this is a new app process.
    @discardableResult
    func attach(_ incoming: PageFacts) -> Bool {
        let isNew = incoming.appPID != facts.appPID
        facts = incoming
        guard isNew else { return false }
        log.log(.app, "Sevoflurane \(incoming.appVersion) attached (pid \(incoming.appPID))")
        watchForExit(of: incoming.appPID)
        return true
    }

    private func watchForExit(of pid: pid_t) {
        exitWatch?.cancel()
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.facts.appPID == pid else { return }
                self.detach(reason: "the process is gone")
            }
        }
        exitWatch = watch
        watch.resume()
        // A process that exited before the watch began delivers no event.
        if kill(pid, 0) != 0 { detach(reason: "the process is gone") }
    }

    /// Forgets the app, so page guards read "no app", not "page not answering".
    func detach(reason: String) {
        guard facts.appPID > 0 else { return }
        log.log(.app, "Sevoflurane (pid \(facts.appPID)) detached: \(reason)")
        facts = PageFacts()
        exitWatch?.cancel()
        exitWatch = nil
    }

    // MARK: - Commands

    @discardableResult
    func send(_ command: PageCommand) async -> Bool {
        await post("/command?verb=\(command.rawValue)") != nil
    }

    /// Runs a stop with the app told the client is going down, so the client's
    /// window requests on the way out are answered with nothing.
    func duringClientStop<T>(_ body: () async -> T) async -> T {
        await send(.clientStopBegan)
        let result = await body()
        await send(.clientStopEnded)
        return result
    }

    /// Asks the app to connect the bridge to the client and waits for the
    /// fact, so no page boots into an unconnected bridge.
    func connectToClient() async {
        guard isAttached else { return }
        await send(.connectToClient)
        for _ in 0 ..< Int(Timing.connectBudget) where !facts.isClientConnected {
            try? await Task.sleep(for: .seconds(1))
            guard isAttached else { return }
        }
    }

    /// Hides the client's CEF windows over the bridge and answers what it hid,
    /// which is how the daemon sees the sign-in window.
    func sweepClientPopups(_ scope: PopupSweepScope) async -> [String] {
        guard isAttached,
              let data = await post("/popups/sweep?scope=\(scope.rawValue)") else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Whether Steam's stores finished initializing; nil when the app cannot say.
    func servicesReady() async -> Bool? {
        guard isAttached, let data = await post("/services/ready") else { return nil }
        struct Reply: Decodable { let ready: Bool? }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.ready
    }

    /// Asks the app to start a game from its page, with `option` answering
    /// Steam's launch-option question ahead of it. Answers whether the app
    /// took the launch.
    func launchGame(appID: Int, option: Int? = nil) async -> Bool {
        guard isAttached else { return false }
        let path = "/command/launch?appid=\(appID)" + (option.map { "&option=\($0)" } ?? "")
        return await post(path) != nil
    }

    /// Tells the app a launch prepared here gave a game its first-launch
    /// fixes, so it posts the notification whose Undo puts them back.
    func announceFixesApplied(appID: Int) async {
        guard isAttached else { return }
        _ = await post("/fixes/applied?appid=\(appID)")
    }

    /// Tells the app a program is about to start here, so the app opens its
    /// run, window watch and status line before the process can write a line
    /// (``ProgramStartNotice``). Answers whether the app took the notice;
    /// with no app attached nothing records the run.
    func announceProgramStart(programID: Int) async -> Bool {
        guard isAttached else { return false }
        return await post(ProgramStartNotice(programID: programID).target, timeout: Timing.notice) != nil
    }

    /// Tells the app a program started here drew nothing after its kernel
    /// driver failed to load, so it explains why.
    func announceKernelDriverFailure(programID: Int, driver: String) async {
        guard isAttached,
              let name = driver.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        _ = await post("/program/driver-failed?id=\(programID)&driver=\(name)")
    }

    /// Mirrors the daemon's verdict into the app.
    func push(_ snapshot: SupervisorSnapshot) async {
        guard isAttached, let body = try? JSONEncoder().encode(snapshot) else { return }
        _ = await post("/state", body: body)
    }

    /// Mirrors one log line into the app's in-memory trail; the file has it already.
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

    /// Passes one of the app's verbs through from the control port, even with
    /// no app attached: after a helper relaunch the app answers before its
    /// facts arrive.
    func proxy(_ request: HTTPRequest) async -> HTTPResponse {
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
        proxied.timeoutInterval = isAttached ? Timing.proxy : Timing.detachedProxy
        ControlToken.authorize(&proxied)
        guard let (data, response) = try? await URLSession.shared.data(for: proxied),
              let http = response as? HTTPURLResponse else {
            return isAttached
                ? .error(504, "Sevoflurane did not answer")
                : .error(409, "Sevoflurane is not running")
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
        /// The longest a program's spawn waits for the app to take its start
        /// notice; an app busier than this opens the run when it gets to it.
        static let notice: TimeInterval = 5
        /// A proxied verb can be a benchmark or a window inventory.
        static let proxy: TimeInterval = 120
        /// For an app not attached: a refused connection fails at once.
        static let detachedProxy: TimeInterval = 10
    }

    private func post(_ path: String, body: Data? = nil, timeout: TimeInterval = Timing.command) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.appLink)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        ControlToken.authorize(&request)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) else {
            return nil
        }
        return data
    }
}
