import ArgumentParser
import Foundation

// MARK: - doctor / status

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Full environment diagnosis, one ✔/✖ line per check.",
    )

    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        let snapshot = await Doctor.snapshot()
        let checks = Doctor.checks(from: snapshot)
        if asJSON {
            print(Sevo.json(Doctor.jsonReport(from: snapshot, checks: checks), pretty: true))
        } else {
            print("sevo doctor")
            for check in checks {
                let mark = check.ok ? "✔" : "✖"
                print("  \(mark) \(check.label)" + (check.ok ? "" : " — \(check.hint)"))
            }
        }
        if checks.contains(where: { !$0.ok && $0.provisioning }) { throw SevoExit.notProvisioned }
        if checks.contains(where: { !$0.ok }) { throw SevoExit.failed }
    }
}

/// The observation every mutating verb ends on and `status` prints: engine,
/// bottle, client, bridge, app, as a line and as a dict.
enum StatusReport {
    static func build() async -> (dict: [String: Any], line: String) {
        let snapshot = await Doctor.snapshot()
        let d = snapshot.detection
        // "NONE" only when no engine is on disk.
        let engine = if d.crossover == nil, d.managedEngineVersions.isEmpty {
            "NONE"
        } else if case .crossover = Engine.active, let cx = d.crossover {
            "CrossOver \(cx.version)"
        } else {
            Engine.active.description
        }
        let steamOK = SetupProbe.bottles(for: Engine.active).first { $0.name == SteamBottle.name }?.hasSteam == true
        let client = switch snapshot.clientState {
        case .up: "running"
        case .portWithoutContext: "half-wedged (no SharedJSContext)"
        case .busy: "running, CDP too busy to answer"
        case .down: snapshot.bottleProcesses.isEmpty ? "stopped" : "up, CDP unreachable"
        }
        let supervision = if let status = snapshot.appStatus {
            "running (\(status["health"] as? String ?? "?"))"
        } else {
            "not running"
        }
        // The daemon sees only an attached app; a detached live one answers
        // its own link port.
        let appState = AppRunState.classify(
            daemonReportsAttached: (snapshot.appStatus?["app"] as? String) == "running",
            appLinkAlive: snapshot.appLinkAlive,
        )
        // A missing dependency is a note: the bottle still runs games.
        let incomplete = BottleReadiness.incompleteSummary()
        // The bottle the running client is in, which is the configured one
        // only when nothing moved the preference under it.
        let running = snapshot.clientState != .down || !snapshot.bottleProcesses.isEmpty
        let clientBottle = running ? await BottleIdentity.clientBottleName() : nil
        let dict: [String: Any] = [
            "engine": engine,
            "bottle": SteamBottle.name,
            "client_bottle": clientBottle ?? NSNull(),
            "steam_installed": steamOK,
            "bottle_incomplete": incomplete ?? NSNull(),
            "provisioning": snapshot.provision?.dictionary ?? NSNull(),
            "client": client,
            "services_up": snapshot.servicesUp ?? NSNull(),
            "bridge": snapshot.bridgeUp,
            "app": snapshot.appStatus ?? NSNull(),
            "app_running": appState.isRunning,
            "app_attached": appState == .attached,
            "dump_rate_10m": snapshot.dumpCount,
            "client_pinned": snapshot.pinned,
            "signed_in_elsewhere": snapshot.appStatus?["signedInElsewhere"] ?? NSNull(),
        ]
        var line = "engine \(engine) · "
            + BottleIdentity.statusText(clientBottle: clientBottle, configured: SteamBottle.name, steamInstalled: steamOK)
            + " · client \(client) · bridge \(snapshot.bridgeUp ? "up" : "down")"
            + " · supervision \(supervision) · app \(appState.rawValue)"
        if let incomplete { line += " · bottle incomplete (\(incomplete))" }
        if snapshot.appStatus?["signedInElsewhere"] is [String: Any] {
            line += " · Steam signed out: its account signed in on another client"
        }
        if snapshot.appStatus?["debug"] as? Bool == true { line += " · debug mode on" }
        return (dict, line)
    }

    /// Prints a verb's verdict, then the resulting state.
    static func emit(_ outcome: ClientOps.Outcome, asJSON: Bool) async {
        let (dict, line) = await build()
        if asJSON {
            print(Sevo.json([
                "verdict": outcome.verdict.rawValue,
                "intent": outcome.intent,
                "note": outcome.note,
                "state": dict,
            ], pretty: true))
        } else {
            print("\(outcome.intent): \(outcome.verdict.rawValue) — \(outcome.note)")
            print("  \(line)")
        }
    }
}

/// The game window a launch produced, for an agent: id, title, pid, the frame
/// in points (click coordinates) and pixels (screenshots), the Retina scale
/// and the display.
enum WindowReport {
    /// The game window the app reports right now, if any.
    static func currentWindow() async -> [String: Any]? {
        guard let data = await AppControl.get("/game/window"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["window_id"] != nil else { return nil }
        return obj
    }

    /// Polls for the launched game's window; `nil` on timeout. A window up
    /// before the launch, or one whose exe belongs to another game, is not
    /// this launch's.
    static func awaitWindow(
        forApp appid: Int, before: [String: Any]?, timeout: Int, progress: (String) -> Void,
    ) async -> [String: Any]? {
        let known = GameConfig.game(appid).exes ?? []
        for waited in stride(from: 0, through: timeout, by: 3) {
            if let obj = await currentWindow() {
                let owner = (obj["owner"] as? String ?? "").lowercased()
                let isNew = obj["window_id"] as? Int != before?["window_id"] as? Int
                // With no exe recorded yet, any new window looks like this
                // launch's — including a window another game just put up.
                let claimant = GameConfig.app(claiming: owner)
                let accepted = known.isEmpty
                    ? (isNew && (claimant == nil || claimant == appid))
                    : known.contains(owner)
                if accepted { return obj }
            }
            try? await Task.sleep(for: .seconds(3))
            if waited > 0, waited % 15 == 0 { progress("waiting for the game window (\(waited)s)") }
        }
        return nil
    }

    static func lines(_ w: [String: Any]) -> [String] {
        func frame(_ d: [String: Any]?) -> String {
            guard let d, let x = d["x"] as? Double, let y = d["y"] as? Double,
                  let width = d["w"] as? Double, let height = d["h"] as? Double else { return "?" }
            return String(format: "%.0f,%.0f %.0f×%.0f", x, y, width, height)
        }
        let scale = w["retina_scale"] as? Double ?? 0
        let display = w["display"] as? [String: Any]
        let offPrimary = w["off_primary"] as? Bool == true
        return [
            "window \(w["window_id"] as? Int ?? 0) · \(w["owner"] as? String ?? "?") · pid \(w["pid"] as? Int ?? 0)",
            "title: \(w["title"] as? String ?? "")",
            "frame: \(frame(w["frame_points"] as? [String: Any])) pts · "
                + "\(frame(w["frame_pixels"] as? [String: Any])) px · scale \(String(format: "%g", scale))",
            "display \(display?["index"] as? Int ?? 0)"
                + (offPrimary ? " · off primary (negative origin)" : ""),
        ]
    }
}

/// Live narration during a wait. In `--json` it goes to stderr so stdout
/// stays a single clean observation; otherwise it prints inline.
func narrate(_ line: String, asJSON: Bool) {
    if asJSON {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    } else {
        print(line)
    }
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "One line: engine, bottle, client, bridge, supervision, app.",
    )

    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        let (dict, line) = await StatusReport.build()
        print(asJSON ? Sevo.json(dict, pretty: true) : line)
    }
}

/// Blocks until the client is healthy, or down with `--gone`, then reports
/// the observed state and a verdict.
struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Block until the client is healthy (or --gone: down), then report; exits 2 when the wait runs out.",
    )
    @Flag(name: .customLong("gone"), help: "Wait for the client to be gone, not healthy.")
    var gone = false
    @Option(name: .customLong("timeout"), help: "Seconds to wait (default 120).")
    var timeout = 120
    @Flag(name: .customLong("no-app")) var noApp = false
    @Flag(name: .customLong("json"), help: "Machine-readable observation.") var asJSON = false

    /// Seconds the closing status report may add, so the whole verb stays bounded.
    static let reportAllowance = 20

    func run() async throws {
        let gone = gone, noApp = noApp, timeout = timeout, asJSON = asJSON
        let sink: @Sendable (String) -> Void = { narrate($0, asJSON: asJSON) }
        let outcome: ClientOps.Outcome
        do {
            outcome = try await withDeadline(.seconds(timeout + Self.reportAllowance)) {
                let outcome: ClientOps.Outcome = if gone {
                    await ClientOps.waitGone(timeout: timeout, progress: sink)
                } else if await ClientOps.supervisionIsRunning(noApp: noApp) {
                    await ClientOps.pollAppHealthy(intent: "wait", timeout: timeout, progress: sink)
                } else {
                    await ClientOps.pollClientUp(intent: "wait", timeout: timeout, progress: sink)
                }
                await StatusReport.emit(outcome, asJSON: asJSON)
                return outcome
            }
        } catch is DeadlineExceeded {
            throw ClientOps.Failure.message("wait: still not \(gone ? "gone" : "healthy") after \(timeout)s, and the report itself stalled — sevo doctor")
        }
        // A wait that ends on its clock is a failure to the caller: a script
        // that waited for healthy must not go on as if it got it.
        guard outcome.verdict == .confirmed else {
            throw ExitCode(2)
        }
    }
}
