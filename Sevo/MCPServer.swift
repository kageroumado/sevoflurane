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
                    + "'crossover', or 'crossover-preview'.",
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
                "Stop the Steam client (kill ladder; pauses the daemon's "
                    + "auto-restart when routed through the daemon).",
                destructive: true,
            ),
            tool(
                "client_restart",
                "Restart the Steam client and wait for healthy.",
                destructive: true,
            ),
            tool(
                "recover",
                "Bring a stuck client back: probe, then restart what is actually stuck. "
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
                "perf_compare",
                "Compare frame-time traces of a game's recent runs: runs are grouped by what they ran on "
                    + "(engine, renderer, upscaler, tuning, msync, D3DMetal, window treatment, label) and "
                    + "each group is tested against the first, with 95 % intervals for the average and "
                    + "the 1 % low. versus.*.method \"welch\" is Welch's t-test over runs (two or more per "
                    + "side); \"block-bootstrap\" means a side had one run and is weaker evidence. A "
                    + "difference counts only where significant is true: its interval excludes zero. "
                    + "Runs need at least 60 s past loading in a comparable scene; pass skip to leave "
                    + "loading out.",
                properties: appid.merging([
                    "last": ["type": "integer", "description": "How many of the game's newest runs (default 6)"],
                    "skip": ["type": "number", "description": "Seconds to leave out at the start of each run"],
                ], uniquingKeysWith: { a, _ in a }),
                readOnly: true,
            ),
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
                "program_list",
                "The Windows programs added outside Steam (id, name, kind, path).",
                readOnly: true,
            ),
            tool(
                "program_launch",
                "Start an added Windows program. `id` is from program_list, "
                    + "not a Steam appid.",
                properties: [
                    "id": ["type": "integer", "description": "Added program id"],
                    "renderer": ["type": "string", "description": "Run it on this renderer for once"],
                ],
                required: ["id"],
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
                "perf_list",
                "Runs that have a frame trace, newest first: number (what perf_label takes), start "
                    + "time, game, engine, renderer, label, and the frame-time summary.",
                properties: [
                    "appid": ["type": "integer", "description": "Only this game's runs"],
                    "last": ["type": "integer", "description": "How many (default 20)"],
                ],
                readOnly: true,
            ),
            tool(
                "perf_label",
                "Name a run, so two runs the record cannot tell apart (a setting inside the game, a "
                    + "different scene) compare as different configurations. An empty label removes it.",
                properties: [
                    "run": ["type": "string", "description": "A perf_list number, a start time, or a trace path"],
                    "label": ["type": "string", "description": "The name; empty removes it"],
                ],
                required: ["run", "label"],
            ),
            tool(
                "runs_recent",
                "The last game launches as run records: what each ran on, when its first window "
                    + "appeared, how long it ran, how it ended, the last exception, renderer notes, "
                    + "the frame-rate summary, and known_failure when the app recognizes the ending.",
                properties: ["last": ["type": "integer", "description": "How many (default 10)"]],
                readOnly: true,
            ),
            tool(
                "diag_level",
                "How much the next game run records. Without level, reads it. 0: the run record, frame "
                    + "trace, event log and Wine's errors, with a report after a crash. 1: adds Wine's "
                    + "exception channel, the renderers' logs and a report after every run. 2: adds "
                    + "every library load, the presenter logs, whole minidumps and host samples, and "
                    + "turns itself off after one run. A level reaches a game at its next launch.",
                properties: ["level": ["type": "integer", "enum": [0, 1, 2]]],
            ),
            tool(
                "diag_save",
                "Write the diagnostics zip to the Desktop and answer its path: the logs, doctor, host, "
                    + "the engine's identity, the bottle's env files, Steam's logs, this month's run "
                    + "records with the games' own logs, and 48 h of crash reports, all redacted. "
                    + "Call it right after the problem shows.",
            ),
            tool(
                "logs_tail",
                "The last N lines of the unified event log: what the app and sevo did, the "
                    + "launch trail, and at level 2 the host's state every 10 s.",
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
            guard let appid = Self.integer(args["appid"]) else {
                throw ClientOps.Failure.message("appid (integer) is required")
            }
            return appid
        }
        var progress: [String] = []
        switch name {
        case "perf_compare":
            var selection = try PerfCommand.Selection.parse([])
            selection.game = Self.integer(args["appid"])
            selection.last = Self.integer(args["last"]) ?? 6
            selection.skip = (args["skip"] as? NSNumber)?.doubleValue ?? 0
            return try Sevo.json(PerfReport.model(PerfComparison.groups(selection.resolve()), series: false), pretty: true)
        case "perf_list":
            let runs = PerfRuns.available(game: Self.integer(args["appid"]))
                .prefix(max(1, Self.integer(args["last"]) ?? 20))
            return Sevo.json(runs.enumerated().map { PerfRuns.row($0.offset + 1, $0.element) }, pretty: true)
        case "perf_label":
            guard let reference = args["run"] as? String, let label = args["label"] as? String else {
                throw ClientOps.Failure.message("run (string) and label (string) are required")
            }
            guard let entry = PerfRuns.find(reference, in: PerfRuns.available(game: nil)) else {
                throw ClientOps.Failure.message("no run \(reference) — perf_list names them")
            }
            try PerfLabels.set(label, forTrace: entry.url.lastPathComponent)
            return label.isEmpty ? "label removed" : "labeled “\(label)”"
        case "runs_recent":
            let records = RunLog.recent(max(1, Self.integer(args["last"]) ?? 10))
            return Sevo.json(records.map(RunsCommand.row), pretty: true)
        case "diag_level":
            var level = DiagnosticLevel.current
            if args["level"] != nil {
                guard let wanted = Self.integer(args["level"]).flatMap(DiagnosticLevel.init(rawValue:)) else {
                    throw ClientOps.Failure.message("level must be 0, 1 or 2")
                }
                level = DiagnosticLevel.set(wanted)
            }
            return Sevo.json([
                "level": level.rawValue, "title": level.title, "detail": level.detail,
                "wine_debug": level.channels(), "reports": CrashCollector.root.path,
                "single_run": level.isSingleRun,
            ], pretty: true)
        case "diag_save":
            Diagnostics.faceReport = { await DiagCommand.faceReport() }
            return try await Diagnostics.bundle(to: nil, steamLogs: true).path
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
            for (name, engine, cx) in [
                ("crossover", Engine.crossover, detection.crossover),
                ("crossover-preview", Engine.crossoverPreview, detection.crossoverPreview),
            ] {
                guard let cx else { continue }
                rows.append([
                    "engine": name, "version": cx.version,
                    "active": Engine.active == engine,
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
            let outcome = try await ClientOps.useEngine(
                engine, version: version, bottle: args["bottle"] as? String, noApp: false,
            ) { progress.append($0) }
            return await Self.observed(outcome, progress: progress)
        case "client_start":
            let outcome = try await ClientOps.start(noApp: false) { progress.append($0) }
            return await Self.observed(outcome, progress: progress)
        case "client_stop":
            let outcome = try await ClientOps.stop(noApp: false) { progress.append($0) }
            return await Self.observed(outcome, progress: progress)
        case "client_restart":
            let outcome = try await ClientOps.restart(noApp: false) { progress.append($0) }
            return await Self.observed(outcome, progress: progress)
        case "recover":
            let deep = Self.boolean(args["deep"]) ?? false
            let outcome = try await ClientOps.recover(deep: deep, noApp: false) { progress.append($0) }
            return await Self.observed(outcome, progress: progress)
        case "library_list":
            return try await SteamOps.libraryList(
                installedOnly: Self.boolean(args["installed_only"]) ?? false,
            )
        case "app_info":
            return try await SteamOps.appInfo(appid())
        case "app_launch":
            let id = try appid()
            let before = await WindowReport.currentWindow()
            _ = try await SteamOps.requestLaunch(id, option: nil)
            let window = await WindowReport.awaitWindow(
                forApp: id, before: before, timeout: 180,
            ) { progress.append($0) }
            guard let window else {
                return (progress + [
                    "app launch: unverifiable — no game window within 180s (poll: sevo status)",
                ]).joined(separator: "\n")
            }
            return (progress + ["app launch: confirmed — game window up"]
                + WindowReport.lines(window)).joined(separator: "\n")
        case "app_terminate":
            try await SteamOps.terminate(appid())
            return "terminate requested"
        case "app_install":
            let outcome = try await SteamOps.install(appid())
            switch outcome {
            case "ok": return "install queued — check downloads_status"
            case "license": return "Steam is showing the game's license agreement; the user accepts it in the Steam window, then the download starts"
            default: return "install did not start: \(outcome)"
            }
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
        case "program_list":
            return Sevo.json(["programs": AdoptedPrograms.all().map { entry in
                [
                    "id": entry.id, "name": entry.name, "kind": entry.kind,
                    "path": entry.program.path, "exists": entry.program.exists,
                ] as [String: Any]
            }], pretty: true)
        case "program_launch":
            guard let id = Self.integer(args["id"]) else {
                throw ClientOps.Failure.message("id (integer) is required")
            }
            let outcome = try await ClientOps.launchProgram(
                id: id, renderer: args["renderer"] as? String,
            )
            return await Self.observed(outcome, progress: progress)
        case "downloads_status":
            return try await SteamOps.downloadsStatus()
        case "downloads_pause":
            try await SteamOps.setDownloadsEnabled(false)
            return "downloads paused"
        case "downloads_resume":
            try await SteamOps.setDownloadsEnabled(true)
            return "downloads resumed"
        case "logs_tail":
            return try Self.logTail(lines: Self.integer(args["lines"]) ?? 50)
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

    /// A mutating verb's reply, MCP-flavored: the narration, the verdict, and
    /// the state the agent's model should hold now — the observation, not "ok".
    private static func observed(_ outcome: ClientOps.Outcome, progress: [String]) async -> String {
        let (_, line) = await StatusReport.build()
        return (progress + [
            "\(outcome.intent): \(outcome.verdict.rawValue) — \(outcome.note)", line,
        ]).joined(separator: "\n")
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
