import ArgumentParser
import Foundation

/// The spec's exit contract: 0 ok · 1 operation failed · 2 bad invocation ·
/// 3 environment not provisioned (doctor-level problem) · 4 client
/// unreachable.
nonisolated enum SevoExit {
    static let failed = ExitCode(1)
    static let badInvocation = ExitCode(2)
    static let notProvisioned = ExitCode(3)
    static let unreachable = ExitCode(4)
}

nonisolated enum Sevo {
    /// The version of the app this executable shipped in (`Sevoflurane.app/
    /// Contents/Helpers/sevo`), which is what a bug report should name; a copy
    /// run from outside an app bundle says so.
    static let version: String = {
        // Bundle.main rather than argv[0], which is the bare word `sevo` when the
        // shell found the symlink on PATH.
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard let info = NSDictionary(contentsOf: contents.appending(path: "Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String
        else { return "development build" }
        return (info["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }()

    /// The app's event log — one trail whether the app or the CLI drove.
    static let logFile = AppIdentity.logFile()

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// JSON-encodes any JSON-representable value; dictionaries get sorted
    /// keys so `--json` output is diffable.
    static func json(_ value: Any, pretty: Bool = false) -> String {
        JSONText.string(value, pretty: pretty)
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
}

/// Talks to the supervision daemon's control endpoint (loopback :8764), which
/// also proxies the app's own verbs. `nil` from `get` means supervision is not
/// running — `sevo client start` brings it up, and `--no-app` drives
/// ``ClientLifecycle`` directly for debugging.
nonisolated enum AppControl {
    static func get(_ path: String, timeout: TimeInterval = 3) async -> Data? {
        await request(path, method: "GET", timeout: timeout)
    }

    static func post(_ path: String, timeout: TimeInterval = 10) async -> Data? {
        await request(path, method: "POST", timeout: timeout)
    }

    /// A POST that carries a body — the routes whose argument is a path,
    /// which a query string would have to escape.
    static func post(_ path: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.control)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) else { return nil }
        return data
    }

    /// A POST whose failure body matters: the status code and the body
    /// come back together, or nil when the daemon did not answer at all.
    static func postReply(_ path: String, timeout: TimeInterval = 10) async -> (status: Int, body: Data)? {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.control)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    private static func request(
        _ path: String, method: String, timeout: TimeInterval,
    ) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.control)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    /// The app's own link port, for the verbs only the app can serve. The
    /// daemon's control port cannot proxy these when the reason they are
    /// needed is that the daemon will not launch, so they go straight to the
    /// app. `nil` when no app is running to answer.
    static func appLinkPost(
        _ path: String, timeout: TimeInterval = 60,
    ) async -> (status: Int, body: Data)? {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.appLink)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    /// A read from the app's own link port, for the same reason as
    /// ``appLinkPost(_:timeout:)``. `nil` when no app is running to answer.
    static func appLinkGet(
        _ path: String, timeout: TimeInterval = 10,
    ) async -> (status: Int, body: Data)? {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.appLink)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    /// Whether the app process is answering its own link port, regardless of
    /// whether the daemon still holds its attachment. A detached-but-alive app
    /// — the window after a daemon rebuild, before the app re-posts its facts —
    /// answers here while the daemon's `/status` reports it gone. Any HTTP
    /// reply is proof of life; the `/game/window` read is side-effect-free.
    static func appIsAlive(timeout: TimeInterval = 2) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.appLink)/game/window") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              response is HTTPURLResponse else { return false }
        return true
    }

    /// The daemon's `/status` as a dictionary, or nil when supervision is
    /// down. One retry: the daemon's main actor can be busy past the timeout
    /// mid-restart, and a single missed probe must not read as "gone".
    static func status() async -> [String: Any]? {
        for attempt in 0 ..< 2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            if let data = await get("/status", timeout: 5),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        return nil
    }
}

/// One-shot JavaScript evaluation against the bottled client's
/// `SharedJSContext` — the same channel the bridge uses, opened fresh per
/// invocation. Works whether or not the app is running; only needs the
/// client's CDP port.
nonisolated enum SteamJS {
    static func eval(_ expression: String) async throws -> String? {
        let client = CDPClient(onPush: { _ in })
        try await client.connect(port: BridgePorts.cdp)
        return try await client.evaluate(expression)
    }
}

/// The bridge's `/__eval` — JavaScript in the app's own page context. Needs
/// the app running (the bridge lives in-process).
nonisolated enum BridgeEval {
    enum Failure: Error {
        case unreachable
        case malformedReply
    }

    static func eval(_ expression: String) async throws -> (ok: Bool, value: String) {
        guard let url = URL(string: "http://127.0.0.1:\(BridgePorts.steamUI)/__eval") else {
            throw Failure.unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("1", forHTTPHeaderField: BridgePorts.evalHeader)
        request.httpBody = Data(expression.utf8)
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            throw Failure.unreachable
        }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformedReply
        }
        return (reply["ok"] as? Bool ?? false, reply["v"] as? String ?? "null")
    }
}
