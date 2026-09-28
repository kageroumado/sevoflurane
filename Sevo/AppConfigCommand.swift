import ArgumentParser
import Foundation

extension AppCommand {
    /// One game's settings: what it resolves to and from which level, and
    /// the game's own values. A value set here is written to the engine's
    /// per-program env file for every exe
    /// the game is known to run under.
    struct Config: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "config",
            abstract: "A game's own settings, over the bottle's and the global defaults.",
            discussion: """
            Keys: renderer (\(Renderer.gameRungs) — the translation layer \
            this game renders through, over the bottle's), emulate-modeset \
            (on | off | inherit — fakes a display-mode switch and shows the \
            result in a window), processors (all | a count such as 8 | \
            inherit — how many processors the game is told of; a Unity 5 \
            game keeps a worker spinning on each), dll <name>=<mode> \
            (n,b | b,n | n | b | empty for disabled; <name>= drops one, inherit drops the \
            table), the switches \(ConfigSwitches.names) (on | off | \
            inherit), recommended to print what the fix table knows about \
            this game, windows (the values below), upscaler (off | \
            lanczos | metalfx | a shader package's name | inherit — sevo \
            shaders list names the packages), filter (nearest | bilinear | \
            lanczos | inherit — how the upscaler's last pass reaches the \
            window), mouse (system | linear | inherit — linear gives a game \
            holding the cursor for mouse-look the mouse's own displacement, \
            unshaped by the pointer acceleration curve), runner (wine | \
            nwjs — nwjs runs an NW.js game in native macOS NW.js and \
            downloads the runtime the first time), detect to look at the \
            game's files again, exe <name> to name an executable the game \
            runs under before its first launch has recorded one. Omit the \
            key to print every setting with the level it comes from.
            
            windows takes one of:
            \(WindowTreatment.help)
            """,
        )
        @Argument var appid: Int
        @Argument(help: "renderer | windows | upscaler | filter | mouse | emulate-modeset | processors | dll | \(ConfigSwitches.names) | runner | recommended | detect | exe. Omit to print every setting.")
        var key: String?
        @Argument(help: "New value; for windows: \(WindowTreatment.rungs). Omit to read the key.")
        var value: String?
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            let bottle = SteamBottle.name
            guard let key else {
                report(bottle: bottle)
                return
            }
            switch key {
            case "recommended":
                // Read-only on purpose: a recommendation is something to judge,
                // so it is printed and the user writes the key they agree with.
                print(Self.recommendedLines(appid, exes: GameConfig.game(appid).exes ?? []))
                return
            case "detect":
                try Detect.report(appid: appid, asJSON: asJSON)
                return
            default:
                break
            }
            guard let value else {
                try printKey(key, bottle: bottle)
                return
            }
            try await setKey(key, to: value, bottle: bottle)
            report(bottle: bottle)
        }

        /// One key's value for this game and the level it comes from.
        private func printKey(_ key: String, bottle: String) throws {
            let values = GameConfig.game(appid)
            switch key {
            case "renderer":
                let resolved = GameConfig.renderer(game: appid)
                print("\(resolved.value.rawValue) (\(resolved.source)) — \(Self.rendererReach(appid))")
            case _ where ConfigSwitches.path(for: key) != nil:
                let resolved = ConfigSwitches.resolved(key, bottle: bottle, game: appid)
                print("\(resolved?.value ?? false) (\(resolved?.source.description ?? "?"))")
            case "emulate-modeset":
                let resolved = GameConfig.emulateModeset(bottle: bottle, game: appid)
                print("\(resolved.value) (\(resolved.source))")
            case "processors":
                let resolved = GameConfig.processors(bottle: bottle, game: appid)
                print("\(ConfigKeyParsing.processorsLabel(resolved.value)) (\(resolved.source))")
            case "dll":
                print(Self.overrideLines(values))
            case "windows":
                let resolved = GameConfig.windows(bottle: bottle, game: appid)
                print("\(resolved.value.rawValue) (\(resolved.source)) — \(resolved.value.summary)")
            case "upscaler":
                let resolved = GameConfig.upscaler(bottle: bottle, game: appid)
                print("\(resolved.value) (\(resolved.source))")
            case "filter":
                let resolved = GameConfig.filter(bottle: bottle, game: appid)
                print("\(resolved.value.rawValue) (\(resolved.source))")
            case "mouse":
                let resolved = GameConfig.mouse(bottle: bottle, game: appid)
                print("\(resolved.value.rawValue) (\(resolved.source))")
            case "tuning":
                let resolved = GameConfig.tuning(bottle: bottle, game: appid)
                let parameters = GameConfig.tuningParameters(bottle: bottle, game: appid)
                print("\(resolved.value.rawValue) \(parameters.argument) (\(resolved.source))")
            case "runner":
                print(values.runner ?? GameRunner.wine)
            case "exe":
                print((values.exes ?? []).joined(separator: "\n"))
            default:
                throw Self.unknownKey(key)
            }
        }

        /// Writes one key's value as this game's own.
        private func setKey(_ key: String, to value: String, bottle: String) async throws {
            switch key {
            case "renderer":
                let renderer = try ConfigKeyParsing.renderer(value)
                updateGame(bottle: bottle) { $0.renderer = renderer }
            case _ where ConfigSwitches.path(for: key) != nil:
                let flag = try ConfigKeyParsing.flag(value, key: key)
                let path = ConfigSwitches.path(for: key)!
                updateGame(bottle: bottle) { $0[keyPath: path] = flag }
            case "emulate-modeset":
                let modeset = try ConfigKeyParsing.flag(value, key: "emulate-modeset")
                updateGame(bottle: bottle) { $0.emulateModeset = modeset }
                await ConfigRegistry.settle(bottle: SteamBottle.name, prefix: SteamBottle.root)
            case "processors":
                let processors = try ConfigKeyParsing.processors(value)
                updateGame(bottle: bottle) { $0.processors = processors }
            case "dll":
                try setDLLOverride(value, bottle: bottle)
                await ConfigRegistry.settle(bottle: SteamBottle.name, prefix: SteamBottle.root)
            case "windows":
                let treatment = try ConfigKeyParsing.windows(value)
                updateGame(bottle: bottle) { $0.windows = treatment }
            case "upscaler":
                let upscaler = try await ConfigKeyParsing.upscaler(value)
                updateGame(bottle: bottle) { $0.upscaler = upscaler }
            case "filter":
                let filter = try ConfigKeyParsing.filter(value)
                updateGame(bottle: bottle) { $0.filter = filter }
            case "mouse":
                let curve = try ConfigKeyParsing.mouse(value)
                updateGame(bottle: bottle) { $0.mouse = curve }
            case "tuning":
                try setTuning(value, bottle: bottle)
            case "runner":
                try await setRunner(value)
                ConfigMaterializer.materialize(bottle: bottle, prefix: SteamBottle.root)
            case "exe":
                GameConfig.noteExecutable(value, forApp: appid)
                ConfigMaterializer.materialize(bottle: bottle, prefix: SteamBottle.root)
            default:
                throw Self.unknownKey(key)
            }
        }

        /// Prints the key list after an unknown key and gives the exit that
        /// goes with it.
        private static func unknownKey(_ key: String) -> ExitCode {
            Sevo.printError("unknown key '\(key)' (renderer | windows | upscaler | filter | "
                + "mouse | emulate-modeset | processors | dll | \(ConfigSwitches.names) | runner | "
                + "recommended | detect | exe)")
            return SevoExit.badInvocation
        }

        /// Sets the sync tuning preset, or a custom one with its parameters.
        private func setTuning(_ value: String, bottle: String) throws {
            // `custom:<wait>,<adaptive 0|1>,<object>` names the preset and
            // its parameters in one value.
            let custom = value.hasPrefix("custom:")
                ? TuningParameters(argument: String(value.dropFirst("custom:".count))) : nil
            let tuning = custom != nil ? PerformanceTuning.custom : PerformanceTuning(rawValue: value)
            guard tuning != nil && (tuning != .custom || custom != nil) || value == "inherit" else {
                throw ValidationError(
                    "tuning is standard, experimental, custom:<wait spin>,<adaptive 0|1>,<object spin> "
                        + "(spins 0 to 1000000, 5200 is two microseconds) or inherit",
                )
            }
            updateGame(bottle: bottle) {
                $0.tuning = tuning
                $0.tuningParameters = custom
            }
        }

        private func updateGame(bottle: String, _ change: (inout ConfigValues) -> Void) {
            GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root, change)
        }

        /// Writes, changes or drops one DLL's load order for this game. An
        /// empty table is removed rather than left as a key that says nothing.
        private func setDLLOverride(_ value: String, bottle: String) throws {
            let parsed = try ConfigKeyParsing.dllOverride(value)
            GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root) { values in
                guard let parsed else {
                    values.dllOverrides = nil
                    return
                }
                var table = values.dllOverrides ?? [:]
                table[parsed.dll] = parsed.mode
                values.dllOverrides = table.isEmpty ? nil : table
            }
        }

        /// What the fix table says about this game: the keys it names, the
        /// values it names them with, and the measurement behind each.
        private static func recommendedLines(_ appid: Int, exes: [String]) -> String {
            let recommendation = KnownFixes.recommended(for: appid, exes: exes)
            guard !recommendation.isEmpty else {
                return "nothing — no entry in the fix table names this game"
            }
            return recommendation.fixes.map { fix in
                let keys = ConfigMaterializer.gameLines(appid, fix.values)
                    .dropFirst()
                    .joined(separator: " ")
                return "\(fix.title): \(keys.isEmpty ? "see below" : keys)\n  \(fix.reason)"
            }.joined(separator: "\n")
        }

        /// This game's own load orders, one per line.
        private static func overrideLines(_ values: ConfigValues) -> String {
            let table = values.dllOverrides ?? [:]
            guard !table.isEmpty else { return "none — the bottle's own overrides apply" }
            return table.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.isEmpty ? "disabled" : $0.value)" }
                .joined(separator: "\n")
        }

        /// What a renderer set for this game costs to reach it: its own env
        /// file at the next launch, or the client restart the menu bar offers.
        private static func rendererReach(_ appid: Int) -> String {
            SettingReach.renderer(GameConfig.game(appid).renderer).detail
        }

        /// Switches the game between the bottle's engine and native NW.js,
        /// fetching the runtime that matches the game's own build the first
        /// time it is asked for.
        private func setRunner(_ value: String) async throws {
            var values = GameConfig.game(appid)
            switch value {
            case GameRunner.wine:
                values.runner = nil
                values.nwjsRuntime = nil
            case GameRunner.nwjs:
                guard let info = values.nwjs ?? NWJSGames.record(appID: appid) else {
                    Sevo.printError("app \(appid): not an NW.js game")
                    throw SevoExit.badInvocation
                }
                guard !info.version.isEmpty else {
                    Sevo.printError("app \(appid): could not read the NW.js version out of "
                        + "\(info.dir)/nw.dll")
                    throw SevoExit.failed
                }
                let wanted = await NWJSRuntime.release(forGameVersion: info.version)
                do {
                    _ = try await NWJSRuntime.ensure(version: wanted) { label, fraction in
                        let percent = fraction.map { " \(Int($0 * 100))%" } ?? ""
                        FileHandle.standardError.write(Data("\(label)\(percent)\n".utf8))
                    }
                } catch {
                    Sevo.printError("\(error)")
                    throw SevoExit.failed
                }
                if let caution = info.caution {
                    Sevo.printError("app \(appid): \(caution)")
                }
                // Detection may have rewritten the file since it was read.
                values = GameConfig.game(appid)
                values.runner = GameRunner.nwjs
                values.nwjs = info
                values.nwjsRuntime = wanted
            default:
                Sevo.printError("runner must be \(GameRunner.all.joined(separator: " or "))")
                throw SevoExit.badInvocation
            }
            GameConfig.setGame(appid, values)
        }

        private func report(bottle: String) {
            if asJSON {
                print(Sevo.json(reportPayload(bottle: bottle), pretty: true))
                return
            }
            let renderer = GameConfig.renderer(game: appid)
            let windows = GameConfig.windows(bottle: bottle, game: appid)
            let values = GameConfig.game(appid)
            let exes = values.exes ?? []
            print("renderer \(renderer.value.rawValue) (\(renderer.source)) — \(Self.rendererReach(appid))")
            print("windows \(windows.value.rawValue) (\(windows.source)) — \(windows.value.summary)")
            let upscaler = GameConfig.upscaler(bottle: bottle, game: appid)
            print("upscaler \(upscaler.value) (\(upscaler.source))")
            let filter = GameConfig.filter(bottle: bottle, game: appid)
            print("filter \(filter.value.rawValue) (\(filter.source))")
            let mouse = GameConfig.mouse(bottle: bottle, game: appid)
            print("mouse \(mouse.value.rawValue) (\(mouse.source))")
            let modeset = GameConfig.emulateModeset(bottle: bottle, game: appid)
            print("emulate-modeset \(modeset.value) (\(modeset.source))")
            let processors = GameConfig.processors(bottle: bottle, game: appid)
            print("processors \(ConfigKeyParsing.processorsLabel(processors.value)) (\(processors.source))")
            print("dll \(Self.overrideLines(values).replacingOccurrences(of: "\n", with: " "))")
            for entry in ConfigSwitches.all {
                let resolved = ConfigSwitches.resolved(entry.key, bottle: bottle, game: appid)
                print("\(entry.key) \(resolved?.value ?? false) (\(resolved?.source.description ?? "?"))")
            }
            print("runner \(values.runner ?? GameRunner.wine)")
            if let info = values.nwjs {
                print(info.summary)
                if let runtime = values.nwjsRuntime {
                    print("runtime nwjs \(runtime) \(NWJSRuntime.nativeFlavor)"
                        + (runtime == info.version ? "" : " — the game's own \(info.version) has "
                            + "no build this Mac runs without translation"))
                }
            }
            print("exes \(exes.isEmpty ? "none yet — recorded at the first launch" : exes.joined(separator: " "))")
            var reach = Engine.active.supportsEnvFiles
                ? "settings reach the game at its next launch"
                : "needs an engine that reads the env files (Dormison)"
            if exes.isEmpty {
                reach += "; its exe is not known yet, so a value lands one launch late"
            }
            print("— \(reach)")
        }

        /// Every setting with the level it comes from, as `--json` prints it.
        private func reportPayload(bottle: String) -> [String: Any] {
            let renderer = GameConfig.renderer(game: appid)
            let modeset = GameConfig.emulateModeset(bottle: bottle, game: appid)
            let windows = GameConfig.windows(bottle: bottle, game: appid)
            let upscaler = GameConfig.upscaler(bottle: bottle, game: appid)
            let filter = GameConfig.filter(bottle: bottle, game: appid)
            let mouse = GameConfig.mouse(bottle: bottle, game: appid)
            let processors = GameConfig.processors(bottle: bottle, game: appid)
            let values = GameConfig.game(appid)
            var payload: [String: Any] = [
                "appid": appid,
                "renderer": [
                    "value": renderer.value.rawValue, "source": renderer.source.description,
                    "reach": Self.rendererReach(appid),
                ],
                "windows": [
                    "value": windows.value.rawValue, "source": windows.source.description,
                ],
                "upscaler": [
                    "value": upscaler.value, "source": upscaler.source.description,
                ],
                "filter": [
                    "value": filter.value.rawValue, "source": filter.source.description,
                ],
                "mouse": [
                    "value": mouse.value.rawValue, "source": mouse.source.description,
                ],
                "emulate-modeset": [
                    "value": modeset.value, "source": modeset.source.description,
                ],
                "processors": [
                    "value": processors.value, "source": processors.source.description,
                ],
                "dll-overrides": values.dllOverrides ?? [:],
                "switches": Dictionary(uniqueKeysWithValues: ConfigSwitches.all.map {
                    ($0.key, ConfigSwitches.resolved(
                        $0.key, bottle: bottle, game: appid,
                    )?.value ?? false)
                }),
                "runner": values.runner ?? GameRunner.wine,
                "exes": values.exes ?? [],
            ]
            payload["nwjs"] = values.nwjs.map { info -> Any in
                [
                    "version": info.version, "dir": info.dir,
                    "flavor": info.flavor ?? NSNull(),
                    "greenworks": info.greenworks,
                    "greenworks_cloud": info.greenworksCloud ?? NSNull(),
                    "packageName": info.packageName,
                ] as [String: Any]
            } ?? NSNull()
            return payload
        }
    }
}
