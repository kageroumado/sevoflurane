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
    static let version = "0.1.0"

    /// The app's event log — one trail whether the app or the CLI drove.
    static let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Sevoflurane.log")

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// JSON-encodes any JSON-representable value; dictionaries get sorted
    /// keys so `--json` output is diffable.
    static func json(_ value: Any, pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
}

/// Talks to the running app's control endpoint (`ControlServer`, loopback
/// :8764). `nil` from `get` means the app is not running — the CLI then
/// drives ``ClientLifecycle`` directly.
nonisolated enum AppControl {
    static func get(_ path: String, timeout: TimeInterval = 3) async -> Data? {
        await request(path, method: "GET", timeout: timeout)
    }

    static func post(_ path: String, timeout: TimeInterval = 10) async -> Data? {
        await request(path, method: "POST", timeout: timeout)
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
              let http = response as? HTTPURLResponse, http.statusCode < 500 else {
            return nil
        }
        return data
    }

    /// The app's `/status` as a dictionary, or nil when the app is down.
    /// One retry: the app's main actor can be busy past the timeout during a
    /// page reload, and a single missed probe must not read as "app gone".
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
