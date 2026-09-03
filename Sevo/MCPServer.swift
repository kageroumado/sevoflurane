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
    private let allowEval = ProcessInfo.processInfo.environment["SEVO_MCP_ALLOW_EVAL"] == "1"

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

    private func handle(_ message: [String: Any]) async -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications get no reply.
        guard let id else { return nil }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-06-18"
            return result(id: id, [
                "protocolVersion": requested,
                "capabilities": ["tools": [:], "resources": [:]] as [String: Any],
                "serverInfo": ["name": "sevo", "version": Sevo.version],
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

    private func toolDefinitions() -> [[String: Any]] {
        func tool(
            _ name: String, _ description: String,
            properties: [String: Any] = [:], required: [String] = [],
            readOnly: Bool = false, destructive: Bool = false,
        ) -> [String: Any] {
            [
                "name": name,
                "description": description,
                "inputSchema": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ] as [String: Any],
                "annotations": [
                    "readOnlyHint": readOnly,
                    "destructiveHint": destructive,
                ] as [String: Any],
            ]
        }
        let appid: [String: Any] = ["appid": ["type": "integer", "description": "Steam appid"]]
        var tools: [[String: Any]] = [
            tool(
                "doctor",
                "Full environment diagnosis: engine, bottle, client, bridge, "
                    + "app health, crash-dump rate. Run this first when anything is wrong.",
                readOnly: true,
            ),
            tool(
                "status",
                "One-glance state: engine, bottle, client, bridge, app.",
                readOnly: true,
            ),
            tool(
                "engine_list",
                "Installed Wine engines (CrossOver and managed built-ins) and which is active.",
                readOnly: true,
            ),
            tool(
                "engine_use",
                "Switch the active Wine engine and restart the client under it. "
                    + "`version` is a name from engine_list — a built-in directory name, "
                    + "or 'crossover'.",
                properties: [
                    "version": ["type": "string", "description": "Engine to switch to"],
                    "bottle": ["type": "string", "description": "Bottle to run (default: the current one)"],
                ],
                required: ["version"],
                destructive: true,
            ),
            tool("client_start", "Start the bottled Steam client and wait for it to come up."),
            tool(
                "client_stop",
                "Stop the Steam client (kill ladder; pauses the app's "
                    + "auto-restart when routed through the app).",
                destructive: true,
            ),
            tool(
                "client_restart",
                "Restart the Steam client and wait for healthy.",
                destructive: true,
            ),
            tool(
                "recover",
                "The wedge playbook: probe, then restart what is actually stuck. "
                    + "deep=true also trashes the web cache and repairs the client (minutes).",
                properties: ["deep": [
                    "type": "boolean",
                    "description":
                        "Add htmlcache purge + headless client repair",
                ]],
                destructive: true,
            ),
            tool(
                "library_list",
                "The Steam library (appid, name, installed, size, playtime).",
                properties: ["installed_only": ["type": "boolean"]],
                readOnly: true,
            ),
            tool(
                "app_info",
                "One app's overview, including Steam Deck compat category.",
                properties: appid,
                required: ["appid"],
                readOnly: true,
            ),
            tool("app_launch", "Launch a game.", properties: appid, required: ["appid"]),
            tool(
                "app_terminate",
                "Terminate a running game.",
                properties: appid,
                required: ["appid"],
                destructive: true,
            ),
            tool(
                "app_install",
                "Queue an app install with default settings.",
                properties: appid,
                required: ["appid"],
            ),
            tool(
                "app_uninstall",
                "Uninstall an app. `name` must match the app's display "
                    + "name exactly — the echo is the confirmation.",
                properties: appid.merging(
                    ["name": ["type": "string", "description": "The app's display name, echoed as confirmation"]],
                    uniquingKeysWith: { a, _ in a },
                ),
                required: ["appid", "name"],
                destructive: true,
            ),
            tool(
                "app_verify",
                "Validate an app's local files.",
                properties: appid,
                required: ["appid"],
            ),
            tool(
                "downloads_status",
                "One DownloadOverview snapshot (current item, progress "
                    + "stages, speed).",
                readOnly: true,
            ),
            tool("downloads_pause", "Disable all downloads."),
            tool("downloads_resume", "Re-enable downloads."),
            tool(
                "logs_tail",
                "The last N lines of the unified event log.",
                properties: ["lines": ["type": "integer", "description": "Default 50"]],
                readOnly: true,
            ),
        ]
        if allowEval {
            tools.append(tool(
                "eval_js",
                "Evaluate JavaScript. context='page' runs in the app's page (needs the app); "
                    + "context='client' runs in the bottled client's SharedJSContext.",
                properties: [
                    "js": ["type": "string"],
                    "context": ["type": "string", "enum": ["page", "client"]],
                ],
                required: ["js"],
                destructive: true,
            ))
        }
        return tools
    }

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

    private func invoke(_ name: String, args: [String: Any]) async throws -> String {
        func appid() throws -> Int {
            guard let appid = args["appid"] as? Int else {
                throw ClientOps.Failure.message("appid (integer) is required")
            }
            return appid
        }
        var progress: [String] = []
        switch name {
        case "doctor":
            let snapshot = await Doctor.snapshot()
            return Sevo.json(
                Doctor.jsonReport(from: snapshot, checks: Doctor.checks(from: snapshot)),
                pretty: true,
            )
        case "status":
            let snapshot = await Doctor.snapshot()
            let checks = Doctor.checks(from: snapshot)
            let summary = checks.map { "\($0.ok ? "ok" : "FAIL"): \($0.label)" }
            return summary.joined(separator: "\n")
        case "engine_list":
            let detection = await SetupProbe.detect()
            var rows: [[String: Any]] = []
            if let cx = detection.crossover {
                rows.append([
                    "engine": "crossover", "version": cx.version,
                    "active": Engine.active == .crossover,
                ])
            }
            for version in detection.managedEngineVersions {
                rows.append([
                    "engine": "builtin", "version": version,
                    "active": Engine.active == .managed(version: version),
                ])
            }
            return Sevo.json(rows, pretty: true)
        case "engine_use":
            guard let version = args["version"] as? String, !version.isEmpty else {
                throw ClientOps.Failure.message("version (string) is required")
            }
            let engine: Engine = switch version {
            case "crossover": .crossover
            case "crossover-preview": .crossoverPreview
            default: .managed(version: version)
            }
            guard engine.existsOnDisk else {
                throw ClientOps.Failure.message(
                    "engine \(version) is not installed — see engine_list",
                )
            }
            try await ClientOps.useEngine(
                engine, version: version, bottle: args["bottle"] as? String, noApp: false,
            ) { progress.append($0) }
            return (progress + ["active engine: \(version)"]).joined(separator: "\n")
        case "client_start":
            try await ClientOps.start(noApp: false) { progress.append($0) }
            return progress.joined(separator: "\n")
        case "client_stop":
            try await ClientOps.stop(noApp: false) { progress.append($0) }
            return progress.joined(separator: "\n")
        case "client_restart":
            try await ClientOps.restart(noApp: false) { progress.append($0) }
            return progress.joined(separator: "\n")
        case "recover":
            let deep = args["deep"] as? Bool ?? false
            try await ClientOps.recover(deep: deep, noApp: false) { progress.append($0) }
            return progress.joined(separator: "\n")
        case "library_list":
            return try await SteamOps.libraryList(
                installedOnly: args["installed_only"] as? Bool ?? false,
            )
        case "app_info":
            return try await SteamOps.appInfo(appid())
        case "app_launch":
            try await SteamOps.launch(appid())
            return "launch requested"
        case "app_terminate":
            try await SteamOps.terminate(appid())
            return "terminate requested"
        case "app_install":
            try await SteamOps.install(appid())
            return "install queued — check downloads_status"
        case "app_uninstall":
            let appid = try appid()
            guard let name = args["name"] as? String else {
                throw ClientOps.Failure.message("name (string) is required as confirmation")
            }
            guard let actual = try await SteamOps.appName(appid) else {
                throw ClientOps.Failure.message("appid \(appid) is not in the library")
            }
            guard actual.lowercased() == name.lowercased() else {
                throw ClientOps.Failure.message(
                    "name mismatch: appid \(appid) is \"\(actual)\" — not uninstalling",
                )
            }
            try await SteamOps.uninstall(appid)
            return "uninstall requested for \(appid) (\(actual))"
        case "app_verify":
            try await SteamOps.verify(appid())
            return "verify requested — check downloads_status"
        case "downloads_status":
            return try await SteamOps.downloadsStatus()
        case "downloads_pause":
            try await SteamOps.setDownloadsEnabled(false)
            return "downloads paused"
        case "downloads_resume":
            try await SteamOps.setDownloadsEnabled(true)
            return "downloads resumed"
        case "logs_tail":
            return try Self.logTail(lines: args["lines"] as? Int ?? 50)
        case "eval_js" where allowEval:
            let js = args["js"] as? String ?? ""
            if args["context"] as? String == "client" {
                return try await SteamJS.eval(js) ?? "null"
            }
            let reply = try await BridgeEval.eval(js)
            guard reply.ok else {
                throw ClientOps.Failure.message("page eval failed: \(reply.value)")
            }
            return reply.value
        default:
            throw ClientOps.Failure.message("unknown tool: \(name)")
        }
    }

    private static func logTail(lines: Int) throws -> String {
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
