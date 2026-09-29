import Foundation

/// The `tools/list` catalog, grouped by what each tool drives. The groups are
/// concatenated in the order a host lists the tools.
extension MCPServer {
    func toolDefinitions() -> [[String: Any]] {
        var tools = Self.stackTools()
            + Self.libraryTools()
            + [Self.perfCompareTool()]
            + Self.appMaintenanceTools()
            + Self.programAndDownloadTools()
            + Self.diagnosticTools()
        if allowEval {
            tools.append(Self.evalTool())
        }
        return tools
    }

    private static func tool(
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

    private static var appidProperty: [String: Any] {
        ["appid": ["type": "integer", "description": "Steam appid"]]
    }

    /// The engine, the bottled client and the whole stack's health.
    private static func stackTools() -> [[String: Any]] {
        [
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
        ]
    }

    /// Reading the Steam library and launching from it.
    private static func libraryTools() -> [[String: Any]] {
        [
            tool(
                "library_list",
                "The Steam library (appid, name, installed, size, playtime).",
                properties: ["installed_only": ["type": "boolean"]],
                readOnly: true,
            ),
            tool(
                "app_info",
                "One app's overview, including Steam Deck compat category.",
                properties: appidProperty,
                required: ["appid"],
                readOnly: true,
            ),
            tool("app_launch", "Launch a game.", properties: appidProperty, required: ["appid"]),
        ]
    }

    private static func perfCompareTool() -> [String: Any] {
        tool(
            "perf_compare",
            "Compare frame-time traces of a game's recent runs: runs are grouped by what they ran on "
                + "(engine, renderer, upscaler, tuning, msync+, D3DMetal, window treatment, label) and "
                + "each group is tested against the first, with 95 % intervals for the average and "
                + "the 1 % low. versus.*.method \"welch\" is Welch's t-test over runs (two or more per "
                + "side); \"block-bootstrap\" means a side had one run and is weaker evidence. A "
                + "difference counts only where significant is true: its interval excludes zero. "
                + "Runs need at least 60 s past loading in a comparable scene; pass skip to leave "
                + "loading out.",
            properties: appidProperty.merging([
                "last": ["type": "integer", "description": "How many of the game's newest runs (default 6)"],
                "skip": [
                    "type": ["number", "array"], "items": ["type": "number"],
                    "description": "Seconds to leave out at the start of each run; an array gives each "
                        + "run its own, oldest first, the last value holding for the rest",
                ],
                "from_mark": [
                    "type": "string",
                    "description": "Start each run at its first mark with this label (sevo perf mark), in place of skip",
                ],
            ], uniquingKeysWith: { a, _ in a }),
            readOnly: true,
        )
    }

    /// Stopping, installing, removing and checking one game.
    private static func appMaintenanceTools() -> [[String: Any]] {
        [
            tool(
                "app_terminate",
                "Terminate a running game.",
                properties: appidProperty,
                required: ["appid"],
                destructive: true,
            ),
            tool(
                "app_install",
                "Queue an app install with default settings.",
                properties: appidProperty,
                required: ["appid"],
            ),
            tool(
                "app_uninstall",
                "Uninstall an app. `name` must match the app's display "
                    + "name exactly — the echo is the confirmation.",
                properties: appidProperty.merging(
                    ["name": ["type": "string", "description": "The app's display name, echoed as confirmation"]],
                    uniquingKeysWith: { a, _ in a },
                ),
                required: ["appid", "name"],
                destructive: true,
            ),
            tool(
                "app_verify",
                "Validate an app's local files.",
                properties: appidProperty,
                required: ["appid"],
            ),
        ]
    }

    /// Windows programs added outside Steam, and Steam's download queue.
    private static func programAndDownloadTools() -> [[String: Any]] {
        [
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
                "hoyo_list",
                "HoYoverse games (genshin, starrail, zzz): each one's current build on HoYoPlay's "
                    + "servers and the install folders Sevoflurane keeps.",
                readOnly: true,
            ),
            tool(
                "hoyo_status",
                "What bringing a HoYoverse game folder to the current build takes: up to date, "
                    + "a patch (with its size) or a download of what differs.",
                properties: folderProperty, required: ["folder"], readOnly: true,
            ),
            tool(
                "hoyo_verify",
                "Check a HoYoverse game folder's files against its pkg_version lists. `quick` "
                    + "checks sizes only; a full check reads every file (minutes for 100 GB).",
                properties: folderProperty.merging([
                    "quick": ["type": "boolean", "description": "Sizes only"],
                ]) { first, _ in first },
                required: ["folder"], readOnly: true,
            ),
            tool(
                "hoyo_update",
                "Bring a HoYoverse game folder to the current build from HoYoPlay's servers and "
                    + "answer when done. A patch is a few GB; sevo hoyo update shows progress.",
                properties: folderProperty, required: ["folder"],
            ),
        ]
    }

    private static var folderProperty: [String: Any] {
        ["folder": ["type": "string", "description": "The game's install folder, the one its .exe sits in"]]
    }

    /// Frame traces, run records, the diagnostic level and the event log.
    private static func diagnosticTools() -> [[String: Any]] {
        [
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
    }

    private static func evalTool() -> [String: Any] {
        tool(
            "eval_js",
            "Evaluate JavaScript. context='page' runs in the app's page (needs the app); "
                + "context='client' runs in the bottled client's SharedJSContext.",
            properties: [
                "js": ["type": "string"],
                "context": ["type": "string", "enum": ["page", "client"]],
            ],
            required: ["js"],
            destructive: true,
        )
    }
}
