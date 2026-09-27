import ArgumentParser
import Foundation

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Stdio MCP server exposing the same verbs as the CLI.",
        discussion: """
        Attach from any MCP host, e.g. Claude Desktop / Claude Code:
          { "mcpServers": { "sevoflurane": { "command": "sevo", "args": ["mcp"] } } }
        eval_js is disabled unless SEVO_MCP_ALLOW_EVAL=1 is set in the server's
        environment — arbitrary JS in the Steam session is a power tool, not a
        default.
        """,
    )

    func run() async throws {
        await MCPServer().serve()
    }
}

/// A hand-rolled MCP stdio server (newline-delimited JSON-RPC 2.0): the
/// protocol subset a tools+resources server needs is small, and the official
/// SDK would be the CLI's only heavyweight dependency. Tools are thin
/// wrappers over the same operations the CLI verbs call.
final class MCPServer {
    let allowEval = ProcessInfo.processInfo.environment["SEVO_MCP_ALLOW_EVAL"] == "1"

    func serve() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let message = Sevo.jsonObject(line) else { continue }
            if let reply = await handle(message) {
                var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
            }
        }
    }

    /// The protocol revisions this server speaks, newest first.
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// The client's revision when this server speaks it, else the newest this
    /// server does — the client then decides whether it can go on.
    static func negotiatedVersion(_ requested: String?) -> String {
        if let requested, supportedVersions.contains(requested) { return requested }
        return supportedVersions[0]
    }

    /// What a host puts in front of its model before the first tool call: what the
    /// server drives, and the order a diagnostic run is made in.
    static let instructions = """
    sevo drives Sevoflurane, which runs Windows games from a bottled Steam client on a \
    Wine engine. Start with doctor when anything is wrong; status is the short form.
    
    A diagnostic run worth reading:
    1. diag_level with level 1 before launching (2 for a bug level 1 does not explain; \
    it turns itself off after one run). A level reaches a game at its next launch.
    2. app_launch, then let the game run at least 60 s past loading, in one scene.
    3. For a performance question change one setting between runs (app config, engine, \
    renderer) and run each side at least twice. perf_label names what the record cannot \
    see; perf_compare with skip ≈ 20 leaves loading out.
    4. runs_recent reads how each launch ended; its known_failure is the diagnosis when \
    the app recognizes one. logs_tail is the app's event trail.
    5. diag_save right after the problem, then diag_level with level 0.
    
    Files: ~/Library/Application Support/Sevoflurane/Runs (run records, traces/), \
    …/Sevoflurane/Reports (one collected report per run), ~/Library/Logs/Sevoflurane.log \
    and Sevoflurane-wine.log. Everything a report or the zip carries is redacted: home \
    paths become ~, Steam ids <steamid>, the account and the Mac's names <user> and <host>.
    """

    /// A JSON integer argument. `JSONSerialization` bridges `true` to an
    /// `NSNumber` that `as? Int` accepts as 1, so booleans are refused here.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    /// A JSON boolean argument; a number is not one.
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func handle(_ message: [String: Any]) async -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications get no reply.
        guard let id else { return nil }

        switch method {
        case "initialize":
            return result(id: id, [
                "protocolVersion": Self.negotiatedVersion(params["protocolVersion"] as? String),
                "capabilities": ["tools": [:], "resources": [:]] as [String: Any],
                "serverInfo": ["name": "sevo", "version": Sevo.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": toolDefinitions()])
        case "tools/call":
            return await callTool(id: id, params: params)
        case "resources/list":
            return result(id: id, ["resources": resourceDefinitions()])
        case "resources/read":
            return await readResource(id: id, params: params)
        case "resources/templates/list":
            return result(id: id, ["resourceTemplates": [] as [Any]])
        case "prompts/list":
            return result(id: id, ["prompts": [] as [Any]])
        default:
            return error(id: id, code: -32_601, "method not found: \(method)")
        }
    }

    // MARK: - Tools

    private func callTool(id: Any, params: [String: Any]) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text = try await invoke(name, args: args)
            return result(id: id, [
                "content": [["type": "text", "text": text]],
                "isError": false,
            ])
        } catch {
            let message = switch error {
            case let ClientOps.Failure.message(m): m
            case let ClientOps.Failure.unprovisioned(m): "environment not provisioned: \(m)"
            case let failure as CDPClient.Failure: "client unreachable: \(failure)"
            case BridgeEval.Failure.unreachable:
                "bridge unreachable — is the Sevoflurane app running?"
            default: "\(error)"
            }
            return result(id: id, [
                "content": [["type": "text", "text": message]],
                "isError": true,
            ])
        }
    }

    /// A mutating verb's reply, MCP-flavored: the narration, the verdict, and
    /// the state the agent's model should hold now — the observation, not "ok".
    static func observed(_ outcome: ClientOps.Outcome, progress: [String]) async -> String {
        let (_, line) = await StatusReport.build()
        return (progress + [
            "\(outcome.intent): \(outcome.verdict.rawValue) — \(outcome.note)", line,
        ]).joined(separator: "\n")
    }

    static func logTail(lines: Int) throws -> String {
        guard let text = try? String(contentsOf: Sevo.logFile, encoding: .utf8) else {
            throw ClientOps.Failure.message("no log file — has the app ever run?")
        }
        return text.split(separator: "\n").suffix(max(1, lines)).joined(separator: "\n")
    }

    // MARK: - Resources

    private func resourceDefinitions() -> [[String: Any]] {
        [
            [
                "uri": "sevo://status",
                "name": "status",
                "description": "One-glance state of the whole stack",
                "mimeType": "text/plain",
            ],
            [
                "uri": "sevo://doctor",
                "name": "doctor",
                "description": "Full environment diagnosis",
                "mimeType": "application/json",
            ],
            [
                "uri": "sevo://log",
                "name": "log",
                "description": "Tail of the unified event log",
                "mimeType": "text/plain",
            ],
            [
                "uri": "sevo://library",
                "name": "library",
                "description": "The Steam library",
                "mimeType": "application/json",
            ],
        ]
    }

    private func readResource(id: Any, params: [String: Any]) async -> [String: Any] {
        let uri = params["uri"] as? String ?? ""
        do {
            let (text, mime): (String, String) = switch uri {
            case "sevo://status":
                try await (invoke("status", args: [:]), "text/plain")
            case "sevo://doctor":
                try await (invoke("doctor", args: [:]), "application/json")
            case "sevo://log":
                try (Self.logTail(lines: 100), "text/plain")
            case "sevo://library":
                try await (invoke("library_list", args: [:]), "application/json")
            default:
                throw ClientOps.Failure.message("unknown resource: \(uri)")
            }
            return result(id: id, [
                "contents": [["uri": uri, "mimeType": mime, "text": text]],
            ])
        } catch {
            return self.error(id: id, code: -32_002, "\(error)")
        }
    }

    // MARK: - JSON-RPC envelopes

    private func result(id: Any, _ payload: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": payload]
    }

    private func error(id: Any, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]]
    }
}
