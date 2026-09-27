import Foundation

/// `tools/call` dispatch, one handler per tool domain. Each handler answers
/// the tools it owns and returns nil for any other name.
extension MCPServer {
    func invoke(_ name: String, args: [String: Any]) async throws -> String {
        if let text = try await invokeDiagnosticTool(name, args: args) { return text }
        if let text = try await invokePerfTool(name, args: args) { return text }
        if let text = try await invokeStackTool(name, args: args) { return text }
        if let text = try await invokeAppTool(name, args: args) { return text }
        if let text = try await invokeProgramOrDownloadTool(name, args: args) { return text }
        if name == "eval_js", allowEval { return try await Self.evalJS(args) }
        throw ClientOps.Failure.message("unknown tool: \(name)")
    }

    private static func requiredAppID(_ args: [String: Any]) throws -> Int {
        guard let appid = integer(args["appid"]) else {
            throw ClientOps.Failure.message("appid (integer) is required")
        }
        return appid
    }

    // MARK: - Diagnostics

    private func invokeDiagnosticTool(_ name: String, args: [String: Any]) async throws -> String? {
        switch name {
        case "runs_recent":
            let records = RunLog.recent(max(1, Self.integer(args["last"]) ?? 10))
            return Sevo.json(records.map(RunsCommand.row), pretty: true)
        case "diag_level":
            return try Self.diagnosticLevel(args)
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
        case "logs_tail":
            return try Self.logTail(lines: Self.integer(args["lines"]) ?? 50)
        default:
            return nil
        }
    }

    /// Reads the diagnostic level, or sets it first when `level` is given.
    private static func diagnosticLevel(_ args: [String: Any]) throws -> String {
        var level = DiagnosticLevel.current
        if args["level"] != nil {
            guard let wanted = integer(args["level"]).flatMap(DiagnosticLevel.init(rawValue:)) else {
                throw ClientOps.Failure.message("level must be 0, 1 or 2")
            }
            level = DiagnosticLevel.set(wanted)
        }
        return Sevo.json([
            "level": level.rawValue, "title": level.title, "detail": level.detail,
            "wine_debug": level.channels(), "reports": CrashCollector.root.path,
            "single_run": level.isSingleRun,
        ], pretty: true)
    }

    // MARK: - Frame traces

    private func invokePerfTool(_ name: String, args: [String: Any]) async throws -> String? {
        switch name {
        case "perf_compare":
            return try Self.perfCompare(args)
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
        default:
            return nil
        }
    }

    private static func perfCompare(_ args: [String: Any]) throws -> String {
        var selection = try PerfCommand.Selection.parse([])
        selection.game = integer(args["appid"])
        selection.last = integer(args["last"]) ?? 6
        if let seconds = args["skip"] as? [NSNumber], !seconds.isEmpty {
            selection.skip = PerRunSeconds(values: seconds.map(\.doubleValue))
        } else {
            selection.skip = PerRunSeconds(values: [(args["skip"] as? NSNumber)?.doubleValue ?? 0])
        }
        selection.fromMark = args["from_mark"] as? String
        return try Sevo.json(PerfReport.model(PerfComparison.groups(selection.resolve()), series: false), pretty: true)
    }

    // MARK: - Engine and client

    private func invokeStackTool(_ name: String, args: [String: Any]) async throws -> String? {
        var progress: [String] = []
        let outcome: ClientOps.Outcome
        switch name {
        case "engine_list":
            return await Self.engineList()
        case "engine_use":
            outcome = try await Self.useEngine(args) { progress.append($0) }
        case "client_start":
            outcome = try await ClientOps.start(noApp: false) { progress.append($0) }
        case "client_stop":
            outcome = try await ClientOps.stop(noApp: false) { progress.append($0) }
        case "client_restart":
            outcome = try await ClientOps.restart(noApp: false) { progress.append($0) }
        case "recover":
            let deep = Self.boolean(args["deep"]) ?? false
            outcome = try await ClientOps.recover(deep: deep, noApp: false) { progress.append($0) }
        default:
            return nil
        }
        return await Self.observed(outcome, progress: progress)
    }

    private static func engineList() async -> String {
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
    }

    private static func useEngine(
        _ args: [String: Any], progress: (String) -> Void,
    ) async throws -> ClientOps.Outcome {
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
        return try await ClientOps.useEngine(
            engine, version: version, bottle: args["bottle"] as? String, noApp: false,
            progress: progress,
        )
    }

    // MARK: - Steam apps

    private func invokeAppTool(_ name: String, args: [String: Any]) async throws -> String? {
        switch name {
        case "library_list":
            return try await SteamOps.libraryList(
                installedOnly: Self.boolean(args["installed_only"]) ?? false,
            )
        case "app_info":
            return try await SteamOps.appInfo(Self.requiredAppID(args))
        case "app_launch":
            return try await Self.launchApp(Self.requiredAppID(args))
        case "app_terminate":
            try await SteamOps.terminate(Self.requiredAppID(args))
            return "terminate requested"
        case "app_install":
            return try await Self.installApp(Self.requiredAppID(args))
        case "app_uninstall":
            return try await Self.uninstallApp(Self.requiredAppID(args), confirming: args["name"] as? String)
        case "app_verify":
            try await SteamOps.verify(Self.requiredAppID(args))
            return "verify requested — check downloads_status"
        default:
            return nil
        }
    }

    private static func launchApp(_ id: Int) async throws -> String {
        var progress: [String] = []
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
    }

    private static func installApp(_ appid: Int) async throws -> String {
        let outcome = try await SteamOps.install(appid)
        switch outcome {
        case "ok": return "install queued — check downloads_status"
        case "license": return "Steam is showing the game's license agreement; the user accepts it in the Steam window, then the download starts"
        default: return "install did not start: \(outcome)"
        }
    }

    /// Uninstalls only when `name` matches the library's display name for the app.
    private static func uninstallApp(_ appid: Int, confirming name: String?) async throws -> String {
        guard let name else {
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
    }

    // MARK: - Programs and downloads

    private func invokeProgramOrDownloadTool(_ name: String, args: [String: Any]) async throws -> String? {
        switch name {
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
            return await Self.observed(outcome, progress: [])
        case "downloads_status":
            return try await SteamOps.downloadsStatus()
        case "downloads_pause":
            try await SteamOps.setDownloadsEnabled(false)
            return "downloads paused"
        case "downloads_resume":
            try await SteamOps.setDownloadsEnabled(true)
            return "downloads resumed"
        default:
            return nil
        }
    }

    // MARK: - JavaScript

    private static func evalJS(_ args: [String: Any]) async throws -> String {
        let js = args["js"] as? String ?? ""
        if args["context"] as? String == "client" {
            return try await SteamJS.eval(js) ?? "null"
        }
        let reply = try await BridgeEval.eval(js)
        guard reply.ok else {
            throw ClientOps.Failure.message("page eval failed: \(reply.value)")
        }
        return reply.value
    }
}
