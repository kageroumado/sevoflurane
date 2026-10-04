import ArgumentParser
import Foundation

// MARK: - app / downloads

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Library and per-app actions via the client's own API.",
        subcommands: [
            List.self, Info.self, Compat.self, Config.self, RepairDLL.self, Detect.self,
            Launch.self, Terminate.self, Install.self, Uninstall.self, Verify.self,
        ],
    )

    /// The same record the library page's strip draws, from the same cache:
    /// AreWeAntiCheatYet, AppleGamingWiki, ProtonDB, and Steam's Deck
    /// category when the client is up to say it.
    struct Compat: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compat",
            abstract: "What the community databases say about a game on a Mac.",
        )
        @Argument var appid: Int
        @Option(help: "The game's title, for the wiki lookup. Read from the client when omitted.")
        var name: String?
        @Flag(help: "Ask every source again instead of reading the week-old cache.")
        var refresh = false
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            var title = name ?? ""
            var deck: Int?
            // The client, when it is up, knows the title and Valve's own
            // category; without it the wiki lookup needs `--name`.
            if let raw = try? await SteamOps.appInfo(appid),
               let info = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                if title.isEmpty { title = info["name"] as? String ?? "" }
                deck = info["deck_compat_category"] as? Int
            }
            let record = await GameCompatService.shared.record(
                appID: appid, name: title, deckCategory: deck, ignoringCache: refresh,
            )
            if asJSON {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let json = try encoder.encode(record)
                print(String(decoding: json, as: UTF8.self))
                return
            }
            print("\(record.name.isEmpty ? String(appid) : record.name) (\(appid))")
            print("  Mac:        \(record.mac.label) — \(record.mac.reason)")
            if let native = record.nativeBadge {
                print("  macOS version: \(native.label) — \(native.reason)")
            } else if record.macArchitectures?.is32BitOnly == true {
                print("  macOS version: 32-bit only — no Apple silicon Mac runs it (PCGamingWiki)")
            }
            print("  Anti-cheat: \(record.antiCheatBadge.label) — \(record.antiCheatBadge.reason)")
            if let wiki = record.wiki {
                let columns: [(String, String?)] = [
                    ("native", wiki.native), ("rosetta 2", wiki.rosetta2), ("crossover", wiki.crossover),
                    ("wine", wiki.wine), ("parallels", wiki.parallels),
                ]
                let tiers: [String] = columns.compactMap { name, tier in tier.map { "\(name) \($0)" } }
                print("  AppleGamingWiki: \(tiers.joined(separator: " · ")) — \(wiki.pageURL)")
            }
            if let community = record.community {
                let fps = community.medianFPS.map { ", \(Int($0.rounded())) fps median" } ?? ""
                print("  Sevoflurane: \(community.verdict) (\(community.runs) runs on \(GameCompatVerdict.macs(community.installs))\(fps)) — \(community.pageURL)")
            }
            if let proton = record.proton {
                print("  ProtonDB:   \(proton.tier) (\(proton.total) reports, \(proton.confidence)) — \(proton.sourceURL)")
            }
            if let deck = record.deckCategory {
                let words = [0: "unknown", 1: "unsupported", 2: "playable", 3: "verified"]
                print("  Steam Deck: \(words[deck] ?? String(deck))")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "The library (appid, name, state).",
        )
        @Flag(help: "Only installed apps.") var installed = false
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            var raw = "[]"
            try await handlingFailures {
                raw = try await SteamOps.libraryList(installedOnly: installed)
            }
            if asJSON {
                print(raw)
                return
            }
            guard let apps = try? JSONSerialization.jsonObject(with: Data(raw.utf8))
                as? [[String: Any]] else {
                print(raw)
                return
            }
            for app in apps {
                let appid = app["appid"] as? Int ?? 0
                let name = app["name"] as? String ?? "?"
                let installed = app["installed"] as? Bool == true
                print("\(String(appid).padding(toLength: 8, withPad: " ", startingAt: 0))"
                    + " \(installed ? "●" : "○") \(name)")
            }
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info", abstract: "One app's overview (JSON).",
        )
        @Argument var appid: Int

        func run() async throws {
            try await handlingFailures {
                var info = try await SteamOps.appInfo(appid)
                // The ways an installed app can start, as `sevo app launch
                // --option <n>` numbers them.
                if var overview = Sevo.jsonObject(info), overview["installed"] as? Bool == true,
                   let listed = try? await SteamOps.launchOptions(appid) {
                    overview["launch_options"] = LaunchOptions.parse(listed) {
                        SteamAppInfo.launchDescriptions(appID: appid)
                    }.enumerated().map { number, option in
                        [
                            "number": number + 1,
                            "index": option.index,
                            "description": option.description,
                            "type": option.type,
                        ]
                    }
                    info = Sevo.json(overview)
                }
                print(info)
            }
        }
    }

    /// Puts a DLL a run said was missing back: installs the package that
    /// carries it, then gives this game the native copy.
    struct RepairDLL: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "repair-dll",
            abstract: "Install what carries a missing DLL and take it for one game.",
            discussion: """
            For a launch that ended in 0xc0000135 or "X.dll was not found". \
            The package is installed in the bottle once; the load order is \
            this game's alone and reaches it at its next launch.
            """,
        )
        @Argument var appid: Int
        @Argument(help: "The DLL the game could not find, with or without .dll.")
        var dll: String
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            guard let repair = KnownFixes.dllRepair(for: dll) else {
                Sevo.printError("no package in the dependency catalog carries \(dll) "
                    + "(sevo doctor lists what a bottle has)")
                throw SevoExit.badInvocation
            }
            if BottleDependencies.catalog.first(where: { $0.id == repair.dependency })
                .map(BottleDependencies.isInstalled) == true {
                print("\(repair.packageName) is already installed")
            } else {
                print("installing \(repair.packageName)…")
                if let failure = await BottleDependencies.install(repair.dependency, phase: {
                    FileHandle.standardError.write(Data("  \($0)\n".utf8))
                }) {
                    Sevo.printError("\(repair.packageName): \(failure)")
                    throw SevoExit.failed
                }
            }
            GameConfig.update(game: appid, bottle: SteamBottle.name, prefix: SteamBottle.root) {
                KnownFixes.apply(repair, to: &$0)
            }
            await ConfigRegistry.settle(bottle: SteamBottle.name, prefix: SteamBottle.root)
            if asJSON {
                print(Sevo.json([
                    "appid": appid, "dll": repair.dll, "mode": repair.mode,
                    "package": repair.dependency,
                ], pretty: true))
                return
            }
            print("\(repair.dll)=\(repair.mode) for app \(appid) — reaches it at its next launch")
        }
    }

    /// Looks at a game's files again and records what they are: the NW.js
    /// build it ships, if any. The app does this for the whole installed
    /// library at every client start, so this is for a game that has just
    /// been installed or updated.
    struct Detect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "detect",
            abstract: "Read a game's files and record what runtime it is built on.",
        )
        @Argument var appid: Int
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            try Self.report(appid: appid, asJSON: asJSON)
        }

        static func report(appid: Int, asJSON: Bool) throws {
            guard SharedGames.installDirectory(appID: appid) != nil else {
                Sevo.printError("app \(appid) is not installed in \(SteamBottle.name)")
                throw SevoExit.failed
            }
            let found = NWJSGames.record(appID: appid)
            if asJSON {
                print(Sevo.json([
                    "appid": appid,
                    "nwjs": found.map { info -> Any in
                        [
                            "version": info.version, "dir": info.dir, "main": info.main,
                            "flavor": info.flavor ?? NSNull(), "greenworks": info.greenworks,
                            "greenworks_cloud": info.greenworksCloud ?? NSNull(),
                            "packageName": info.packageName,
                        ] as [String: Any]
                    } ?? NSNull(),
                ], pretty: true))
            } else if let found {
                print(found.summary)
                if let caution = found.caution { print("caution: \(caution)") }
                print("dir \(found.dir)")
                print("page \(found.main)")
                print("data \(found.packageName)")
                print("— sevo app config \(appid) runner nwjs runs it natively")
            } else {
                print("no native runtime detected — this game runs on the bottle's engine")
            }
        }
    }

    struct Launch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch",
            abstract: "Apps.RunGame, then report the game window that appears.",
        )
        @Argument var appid: Int
        @Option(name: .customLong("timeout"), help: "Seconds to wait for the window (default 180).")
        var timeout = 180
        @Option(
            name: .customLong("option"),
            help: "Which way to start it when Steam lists more than one, numbered from 1 in the order sevo app info lists them.",
        )
        var option: Int?
        @Flag(name: .customLong("json"), help: "Machine-readable observation.") var asJSON = false

        func run() async throws {
            try await handlingFailures {
                try await refuseUnlessInstalledHere()
                let before = await WindowReport.currentWindow()
                await warnAboutRunningApps()
                let stuckInSync = await isStuckInCloudSync()
                let route = try await requestLaunch()
                narrate("launch requested for \(appid) — waiting for its window", asJSON: asJSON)
                let window = await WindowReport.awaitWindow(
                    forApp: appid, before: before, timeout: timeout,
                ) {
                    narrate($0, asJSON: asJSON)
                }
                let waitingFor = window == nil ? await SteamOps.pendingUserRequest(appid) : nil
                if asJSON {
                    var payload: [String: Any] = [
                        "verdict": window != nil ? "confirmed"
                            : stuckInSync || waitingFor != nil ? "noEffect" : "unverifiable",
                        "intent": "app launch",
                        "appid": appid,
                    ]
                    payload["window"] = window.map { $0 as Any } ?? NSNull()
                    payload["waiting_for"] = waitingFor
                    print(Sevo.json(payload, pretty: true))
                } else if let window {
                    print("app launch: confirmed — game window up")
                    for line in WindowReport.lines(window) {
                        print("  \(line)")
                    }
                } else if stuckInSync {
                    print("app launch: no effect — Steam kept \(appid) at Synchronizing and dropped the launch"
                        + " (sevo client restart)")
                } else if waitingFor == "ShowLaunchOption" {
                    print("app launch: no effect — Steam is waiting at its launch-option chooser"
                        + (option == nil ? " (pass --option <n>; sevo app info numbers them)"
                            : "; option \(option!) never reached it (sevo diag save)"))
                } else if let waitingFor {
                    print("app launch: no effect — Steam is waiting for an answer to \(waitingFor)")
                } else {
                    print("app launch: unverifiable — no game window within \(timeout)s"
                        + (route == .client ? " (is Sevoflurane running? poll: sevo status)" : ""))
                }
                if waitingFor != nil { throw SevoExit.failed }
            }
        }

        /// Asks for the launch where the launch-option question can be answered:
        /// through the daemon and the app when they are up, so its own chooser
        /// or the `--option` given here answers Steam; otherwise in the
        /// client's own context, where only an option given here can.
        @discardableResult
        private func requestLaunch() async throws -> SteamOps.LaunchRoute {
            let index = try await steamIndex(ofOption: option)
            let route = try await SteamOps.requestLaunch(appid, option: index)
            if let option {
                narrate("option \(option) will answer Steam's launch-option question", asJSON: asJSON)
            } else if route == .client {
                narrate(
                    "Sevoflurane is not running — if Steam asks which way to start it, "
                        + "nothing will answer; pass --option <n> (sevo app info lists them)",
                    asJSON: asJSON,
                )
            }
            return route
        }

        /// A game installed only by another of the account's Steam clients —
        /// a native Mac Steam, another PC — shows as installed in Steam's
        /// library, and launching it here fails at its app ticket and offers
        /// an install. Said up front, with exit 1.
        private func refuseUnlessInstalledHere() async throws {
            guard let info = try? await SteamOps.appInfo(appid),
                  let overview = Sevo.jsonObject(info),
                  overview["installed"] as? Bool == false
            else { return }
            let elsewhere = overview["installed_elsewhere"] as? [String] ?? []
            let name = overview["name"] as? String ?? String(appid)
            let message = elsewhere.isEmpty
                ? "\(name) is not installed in this bottle"
                : "\(name) is installed on \(elsewhere.joined(separator: ", ")), not in this bottle"
            if asJSON {
                print(Sevo.json([
                    "verdict": "noEffect", "intent": "app launch", "appid": appid,
                    "installed": false, "installed_elsewhere": elsewhere,
                ], pretty: true))
            } else {
                print("app launch: no effect — \(message) (install it from Steam in Sevoflurane first)")
            }
            throw SevoExit.failed
        }

        /// Steam's own index for the option numbered `number` from 1, in
        /// the order `sevo app info` lists them: Steam's indexes can skip.
        private func steamIndex(ofOption number: Int?) async throws -> Int? {
            guard let number else { return nil }
            let listed = try await SteamOps.launchOptions(appid)
            let options = LaunchOptions.parse(listed) { SteamAppInfo.launchDescriptions(appID: appid) }
            guard options.indices.contains(number - 1) else {
                throw ValidationError("--option \(number): \(appid) has \(options.count) launch option"
                    + "\(options.count == 1 ? "" : "s"), numbered from 1 (sevo app info lists them)")
            }
            return options[number - 1].index
        }

        /// A game force-ended during its Steam Cloud sync stays at Synchronizing, and the
        /// client accepts and drops every later launch of it. Restarting the client clears it.
        private func isStuckInCloudSync() async -> Bool {
            guard await (try? SteamOps.displayStatus(appid)) == SteamOps.DisplayStatus.synchronizing else {
                return false
            }
            narrate(
                "Steam shows \(appid) as Synchronizing before this launch — a sync that was cut off holds "
                    + "it there, and the client drops launches until it restarts (sevo client restart)",
                asJSON: asJSON,
            )
            return true
        }

        /// Steam refuses a second game while it believes one is running, and
        /// it believes that of any game whose entry outlived its process — so
        /// a non-empty list before the ask is the likeliest reason the launch
        /// that follows does nothing at all.
        private func warnAboutRunningApps() async {
            let running = await (try? SteamOps.runningApps()) ?? []
            guard !running.isEmpty else { return }
            let others = running.filter { $0 != appid }
            guard !others.isEmpty else {
                narrate("\(appid) is already listed as running", asJSON: asJSON)
                return
            }
            narrate(
                "Steam still lists \(others.map(String.init).joined(separator: ", ")) "
                    + "as running — this launch is a no-op until that clears "
                    + "(sevo app terminate <appid>)",
                asJSON: asJSON,
            )
        }
    }

    struct Terminate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "terminate",
            abstract: "End the game's processes, then Apps.TerminateApp, then wait for it to actually go.",
        )
        @Argument var appid: Int
        @Option(
            name: .customLong("timeout"),
            help: "Seconds to wait before signaling the game's processes (default 20).",
        )
        var timeout = 20
        @Flag(name: .customLong("json"), help: "Machine-readable verdict.") var asJSON = false

        func run() async throws {
            try await handlingFailures {
                // The word goes down first: the recorder reads it when the
                // exit that follows is seen. The game's own processes end
                // before Steam is asked, whole, so the ask finds nothing to
                // tear down thread by thread (``GameEnding``).
                RunLog.noteStopRequest(forApp: appid, by: .tool)
                if let ended = await GameEnding.end(appID: appid).summary {
                    narrate(ended, asJSON: asJSON)
                }
                try await SteamOps.terminate(appid)
                // A game on the native runner left the bottle at its first
                // instruction, so the client's terminate only drops its
                // record — the process itself is asked here.
                let native = GameConfig.game(appid).runsNatively
                    ? NWJSRunner.terminate(appID: appid) : []
                narrate(
                    "terminate requested for \(appid)"
                        + (native.isEmpty ? "" : " — and \(native.count) native "
                            + "process\(native.count == 1 ? "" : "es") asked to quit")
                        + " — waiting up to \(timeout)s for it to go",
                    asJSON: asJSON,
                )
                var sighting = await GameStop.waitUntilGone(appid: appid, seconds: timeout)
                var verdict = GameStop.Verdict.terminated
                if !sighting.isGone, sighting.steamListsIt, sighting.processes.isEmpty {
                    // An entry with no process behind it is one the client lost
                    // track of, and only the client clears it: ask once more.
                    try await SteamOps.terminate(appid)
                    narrate(
                        "Steam still lists \(appid) with no process behind it — asked the client once more",
                        asJSON: asJSON,
                    )
                    sighting = await GameStop.waitUntilGone(appid: appid, seconds: 5)
                }
                if !sighting.isGone, sighting.processes.isEmpty {
                    verdict = .stillRunning
                } else if !sighting.isGone {
                    // The record and the processes are separate survivors: a
                    // stale entry is what makes every later RunGame a silent
                    // no-op, and only the client clears it, so what can be
                    // signaled here is the tree.
                    for pid in sighting.processes { kill(pid, SIGKILL) }
                    narrate(
                        "it did not go — SIGKILL'd \(sighting.processes.count) "
                            + "process\(sighting.processes.count == 1 ? "" : "es")",
                        asJSON: asJSON,
                    )
                    sighting = await GameStop.waitUntilGone(appid: appid, seconds: 5)
                    verdict = sighting.isGone ? .killed : .stillRunning
                }
                report(verdict, sighting)
            }
        }

        private func report(_ verdict: GameStop.Verdict, _ sighting: GameStop.Sighting) {
            guard !asJSON else {
                print(Sevo.json([
                    "verdict": verdict.rawValue,
                    "intent": "app terminate",
                    "appid": appid,
                    "steam_lists_it": sighting.steamListsIt,
                    "processes": sighting.processes.map(Int.init),
                ], pretty: true))
                return
            }
            print("app terminate: \(verdict.rawValue) — \(sighting.description)")
            if verdict == .stillRunning, sighting.steamListsIt, sighting.processes.isEmpty {
                print("  Steam's entry outlived the game: every later launch is a "
                    + "silent no-op until it clears. Restart the client: sevo client restart")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install", abstract: "Queue an install with the default folder.",
        )
        @Argument var appid: Int
        @Flag(help: "Accept the game's license agreement when Steam shows one.")
        var acceptLicense = false

        func run() async throws {
            try await handlingFailures {
                let outcome = try await SteamOps.install(appid, acceptLicense: acceptLicense)
                switch outcome {
                case "ok": print("install queued for \(appid) — watch: sevo downloads status")
                case "ok license-accepted":
                    print("install queued for \(appid), its license agreement accepted — watch: sevo downloads status")
                case "no-wizard": print("Steam did not open an install for \(appid): the account holds no license for it. Add it to the library from its store page first.")
                case "license":
                    print("Steam is showing the license agreement for \(appid). Accept it in the Steam window, or run this again with --accept-license.")
                default: print("install of \(appid) stopped: \(outcome)")
                }
            }
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Uninstall an app. Requires --name matching the app, as a guard.",
        )
        @Argument var appid: Int
        @Option(help: "The app's display name, echoed back as confirmation.")
        var name: String

        func run() async throws {
            try await handlingFailures {
                try await uninstall()
            }
        }

        private func uninstall() async throws {
            guard let actual = try await SteamOps.appName(appid) else {
                Sevo.printError("appid \(appid) is not in the library")
                throw SevoExit.failed
            }
            guard actual.lowercased() == name.lowercased() else {
                Sevo.printError("name mismatch: appid \(appid) is \"\(actual)\" — not uninstalling")
                throw SevoExit.badInvocation
            }
            try await SteamOps.uninstall(appid)
            print("uninstall requested for \(appid) (\(actual))")
        }
    }

    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify", abstract: "Apps.VerifyApp (validate local files).",
        )
        @Argument var appid: Int

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.verify(appid)
                print("verify requested for \(appid) — watch: sevo downloads status")
            }
        }
    }
}

struct DownloadsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "downloads",
        abstract: "Download queue: status, pause, resume, throttle.",
        subcommands: [Status.self, Pause.self, Resume.self, Throttle.self],
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status", abstract: "What Steam is downloading now, in a line; --json for Steam's whole snapshot.",
        )

        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            try await handlingFailures {
                let snapshot = try await SteamOps.downloadsStatus()
                print(asJSON ? snapshot : Self.summary(of: snapshot))
            }
        }

        /// Steam's overview as a sentence: the app, the state, how far along
        /// and how fast. The snapshot itself carries two minutes of history.
        static func summary(of snapshot: String) -> String {
            guard let overview = (try? JSONSerialization.jsonObject(with: Data(snapshot.utf8))) as? [String: Any]
            else { return "no answer from Steam's download queue" }
            let paused = overview["paused"] as? Bool == true
            guard let appID = overview["update_appid"] as? Int, appID != 0 else {
                return paused ? "downloads paused, nothing queued" : "nothing downloading"
            }
            let state = (overview["update_state"] as? String ?? "").lowercased()
            let percent = overview["overall_percent_complete"] as? Int ?? 0
            let rate = overview["update_network_bytes_per_second"] as? Int64 ?? 0
            var line = "app \(appID): \(state.isEmpty ? "queued" : state), \(percent)%"
            if rate > 0 {
                line += " at \(ByteCountFormatter.string(fromByteCount: rate, countStyle: .file))/s"
            }
            if let seconds = overview["overall_estimated_time_remaining_sec"] as? Int, seconds > 0 {
                line += ", about \(seconds / 60 + 1) min left"
            }
            return paused ? line + " (paused)" : line
        }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pause", abstract: "Disable all downloads.",
        )

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.setDownloadsEnabled(false)
                print("downloads paused")
            }
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resume", abstract: "Re-enable downloads.",
        )

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.setDownloadsEnabled(true)
                print("downloads resumed")
            }
        }
    }

    struct Throttle: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "throttle", abstract: "Limit download speed in KB/s (0 = off).",
        )
        @Argument var kbps: Int

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.throttle(kbps)
                print(kbps == 0 ? "throttle off" : "throttled to \(kbps) KB/s")
            }
        }
    }
}
