import Foundation
import ServiceManagement

/// The machine-touching half of provisioning, split from the policy in
/// ``Provisioner`` so the DEBUG onboarding harness (`SetupDryRun.swift`) can
/// substitute simulated effects while the wizard flow, stage ordering, skip
/// logic, and error handling stay the code under test.
@MainActor
protocol SetupEnvironment: AnyObject {
    /// Whether effects are simulated (the dry-run harness) — the wizard shows
    /// a badge so a screenshot can never be mistaken for a real run.
    var isSimulation: Bool { get }

    /// Re-reads the machine facts every stage decision runs on.
    func detect() async -> SetupDetection

    /// `softwareupdate --install-rosetta --agree-to-license`.
    func installRosetta() async -> SetupCommandOutcome

    /// Installs the managed engine — the path taken when no usable CrossOver
    /// exists: from `tarball` when someone has the file, else the one shipped
    /// with this copy of the app, else the manifest's stable release,
    /// downloaded. The outcome's output is the version installed. The
    /// fraction is download progress, or `nil` where none is measurable.
    func installEngine(
        from tarball: URL?,
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async -> SetupCommandOutcome

    /// `cxbottle --create --template win10_64` under CrossOver; a
    /// `wineboot -u`-initialized prefix under a managed engine.
    func createBottle(named name: String) async -> SetupCommandOutcome

    /// Fetches SteamSetup.exe from the Steam CDN into the bottle's `drive_c`.
    func downloadSteamInstaller(intoBottle name: String) async throws

    /// Waits for a freshly created prefix to finish booting. An installer
    /// started while `wineboot` is still writing the registry exits nonzero
    /// in under a second and says nothing about why.
    func settleBottle(named name: String) async

    /// Runs the NSIS bootstrapper installer silently (`SteamSetup.exe /S`),
    /// with Wine's error channel on so a failure carries a reason.
    func runSteamInstaller(inBottle name: String) async -> SetupCommandOutcome

    /// Bootstrapper → full client, the long headless download. Exit status is
    /// deliberately unreported: the updater's exit code is unreliable, so the
    /// caller re-detects and judges by what landed on disk.
    func updateSteamClient(inBottle name: String) async

    /// The idempotent per-bottle registry configuration (tray suppression).
    func configureBottle(named name: String) async

    /// Whether the active bottle contains the dependency's installed payload.
    func isDependencyInstalled(_ dependency: BottleDependencies.Dependency) -> Bool

    /// Installs a required game runtime in the active bottle.
    func installDependency(_ dependency: BottleDependencies.Dependency) async -> SetupCommandOutcome

    func setOpenAtLogin(_ enabled: Bool) throws
    var openAtLogin: Bool { get }
}

extension SetupEnvironment {
    var isSimulation: Bool {
        false
    }

    /// Nothing boots in a simulation, so nothing has to settle.
    func settleBottle(named name: String) async {}
}

nonisolated struct SetupCommandOutcome: Sendable {
    let status: Int32?
    let output: String

    var succeeded: Bool {
        status == 0
    }

    static func success(_ output: String = "") -> Self {
        .init(status: 0, output: output)
    }

    static func failure(_ output: String) -> Self {
        .init(status: 1, output: output)
    }
}

/// The real executor: `softwareupdate`, `cxbottle`, `wine`, the Steam CDN,
/// and the login item.
@MainActor
final class LiveSetupEnvironment: SetupEnvironment {
    private static let steamSetupURL =
        URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!

    func detect() async -> SetupDetection {
        await SetupProbe.detect()
    }

    func installRosetta() async -> SetupCommandOutcome {
        await run(
            "/usr/sbin/softwareupdate",
            ["--install-rosetta", "--agree-to-license"],
            timeout: .seconds(600),
        )
    }

    func installEngine(
        from tarball: URL?,
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async -> SetupCommandOutcome {
        do {
            if let tarball = tarball ?? EngineInstaller.bundledTarball() {
                SetupLog.log("engine install from \(tarball.path)")
                let version = try await EngineInstaller.install(fromFile: tarball, progress: progress)
                return .success(version)
            }
            let release = try await EngineInstaller.stableRelease()
            try await EngineInstaller.install(release, progress: progress)
            return .success(release.version)
        } catch {
            return .failure("\(error)")
        }
    }

    func createBottle(named name: String) async -> SetupCommandOutcome {
        switch Engine.active {
        case .crossover, .crossoverPreview:
            return await run(
                (Engine.active.crossoverBin ?? "") + "/cxbottle",
                [
                    "--bottle",
                    name,
                    "--create",
                    "--template",
                    "win10_64",
                    "--description",
                    "Sevoflurane Steam",
                ],
                timeout: .seconds(600),
            )
        case .managed:
            let prefix = Engine.active.bottlesRoot.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(
                    at: prefix, withIntermediateDirectories: true,
                )
            } catch {
                return .failure("\(error)")
            }
            let boot = await runWine(bottle: name, args: ["wineboot", "-u"])
            guard boot.succeeded else { return boot }
            // A fresh prefix reports a pre-Windows-10 version, and Steam
            // then installs its legacy CEF build instead of the modern one
            // (measured on a clean machine: `bin/cef/cef.win7x64` and no
            // `cef.win64`). This is the plain-Wine equivalent of the
            // `win10_64` template CrossOver bottles are created from.
            return await runWine(bottle: name, args: ["winecfg", "/v", "win10"])
        }
    }

    /// Whether a registry file already carries the given `"name"=value`
    /// line. A plain text scan: the hive files are flat `"key"="value"`
    /// dumps, and a false negative only costs one redundant `reg add`.
    private nonisolated func registry(
        of bottle: URL, file: String, contains needle: String,
    ) -> Bool {
        let url = bottle.appendingPathComponent(file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(needle)
    }

    func downloadSteamInstaller(intoBottle name: String) async throws {
        let bottleURL = Engine.active.bottlesRoot.appendingPathComponent(name)
        let (temp, _) = try await URLSession.shared.download(from: Self.steamSetupURL)
        let setup = bottleURL.appendingPathComponent("drive_c/SteamSetup.exe")
        try? FileManager.default.removeItem(at: setup)
        try FileManager.default.moveItem(at: temp, to: setup)
    }

    /// Polls the prefix's `system.reg` until it stops changing. `wineboot`
    /// writes the registry as its last act, and the process that started it
    /// returns before the writing is done — on a fresh prefix the Steam
    /// installer that follows failed 0.58 s later with no output at all.
    func settleBottle(named name: String) async {
        let registry = Engine.active.bottlesRoot
            .appendingPathComponent(name)
            .appendingPathComponent("system.reg")
        var lastWrite = modificationDate(of: registry)
        var stableSince = Date.now
        for _ in 0 ..< Self.settlePolls {
            try? await Task.sleep(for: .milliseconds(500))
            let write = modificationDate(of: registry)
            if write != lastWrite {
                lastWrite = write
                stableSince = .now
                continue
            }
            if Date.now.timeIntervalSince(stableSince) >= Self.settleQuiet { return }
        }
        SetupLog.log("provision: the prefix is still writing its registry — going ahead")
    }

    /// How long the registry must sit still, and how long to wait for that.
    private static let settleQuiet: TimeInterval = 2
    private static let settlePolls = 60

    private nonisolated func modificationDate(of file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    func runSteamInstaller(inBottle name: String) async -> SetupCommandOutcome {
        // The one invocation whose failure a user is asked to act on, so it
        // is also the one that never runs silenced: `WINEDEBUG=-all`, the
        // default, is why "Steam installer failed:" once ended in a colon.
        await runWine(
            bottle: name, args: [#"C:\SteamSetup.exe"#, "/S"],
            wineDebug: "err+all",
        )
    }

    func updateSteamClient(inBottle name: String) async {
        _ = await runWine(
            bottle: name,
            args: [
                SteamBottle.exeWindowsPath,
                "-forcesteamupdate",
                "-forcepackagedownload",
                "-exitsteam",
            ],
            timeout: .seconds(1800),
        )
    }

    func configureBottle(named name: String) async {
        // Each write is skipped when the value already sits in the hive —
        // a `reg add` against a booting client can hang on the registry for
        // the whole subprocess timeout, and every boot after the first
        // has nothing to write anyway.
        let bottleURL = Engine.active.bottlesRoot.appendingPathComponent(name)
        if !registry(
            of: bottleURL, file: "user.reg", contains: #""ShowSystray"="N""#,
        ) {
            _ = await runWine(bottle: name, args: [
                "reg", "add", #"HKCU\Software\Wine\Explorer"#,
                "/v", "ShowSystray", "/t", "REG_SZ", "/d", "N", "/f",
            ])
        }
        // The SDL bus is on or off by engine (`Engine.keepsSDLBus`): on, it is
        // the backend that reaches a Bluetooth Xbox pad; off, an older engine's
        // bus would wake winedevice.exe every millisecond. The value is only
        // ever written or removed, so a bottle that moves between engines
        // follows the engine it boots on.
        let sdlOff = registry(
            of: bottleURL, file: "system.reg", contains: #""Enable SDL"=dword:00000000"#,
        )
        if Engine.active.keepsSDLBus, sdlOff {
            _ = await runWine(bottle: name, args: [
                "reg", "delete", #"HKLM\System\CurrentControlSet\Services\winebus"#,
                "/v", "Enable SDL", "/f",
            ])
        } else if !Engine.active.keepsSDLBus, !sdlOff {
            _ = await runWine(bottle: name, args: [
                "reg", "add", #"HKLM\System\CurrentControlSet\Services\winebus"#,
                "/v", "Enable SDL", "/t", "REG_DWORD", "/d", "0", "/f",
            ])
        }
        // Wine's own renderer reads the card from the registry rather than
        // the environment, so the choice has to be written twice to be one
        // choice. The picker carries it into the prefix as it moves; this is
        // the pass that catches a bottle whose import never landed, and it
        // imports the same file so both routes say the same thing.
        let gpu = BottleGraphics.currentSelection().gpu
        if !BottleGraphics.registryHolds(gpu, inBottle: bottleURL),
           GPUIdentity.writeWineD3DRegistry(gpu, intoBottle: bottleURL) != nil {
            _ = await runWine(bottle: name, args: [
                "regedit", "/S", GPUIdentity.wineD3DRegistryWindowsPath,
            ])
        }
        let bottle = Engine.active.bottlesRoot.appendingPathComponent(name)
        BottleGraphics.adoptDefaultGPU(forBottle: bottle)
        // A bottle nobody has opened the picker for still needs DXVK's file:
        // the other layers read the launch environment, DXVK reads only this.
        GPUIdentity.writeDXVKConfig(BottleGraphics.currentSelection().gpu, intoBottle: bottle)
        guard case let .managed(version) = Engine.active else {
            do {
                try BottleGraphics.reassertDefaults(forBottle: bottle)
            } catch {
                SetupLog.log("graphics defaults not written: \(error)")
            }
            return
        }
        // A managed engine keeps its renderers in the engine directory; the
        // prefix needs the DLLs themselves for `n,b` to mean anything.
        let staged = EngineRenderers.stage(
            BottleGraphics.managedSelection().renderer,
            engine: Engine.managedRoot.appendingPathComponent(version),
            bottle: bottle,
        )
        if !staged.isEmpty {
            SetupLog.log("staged \(staged.count) renderer DLLs into \(name)")
        }
    }

    func setOpenAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func isDependencyInstalled(_ dependency: BottleDependencies.Dependency) -> Bool {
        BottleDependencies.isInstalled(dependency)
    }

    func installDependency(_ dependency: BottleDependencies.Dependency) async -> SetupCommandOutcome {
        let failure = await BottleDependencies.install(dependency.id) { phase in
            SetupLog.log("provision: \(dependency.name): \(phase)")
        }
        return failure.map(SetupCommandOutcome.failure) ?? .success()
    }

    var openAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Wine's own chatter still comes back combined: provisioning quotes it
    /// in failure messages, and these invocations are rare and bounded.
    private nonisolated func runWine(
        bottle: String, args: [String], timeout: Duration = .seconds(600),
        wineDebug: String? = nil,
    ) async -> SetupCommandOutcome {
        let invocation = Engine.active.wineInvocation(
            bottle: bottle, wait: .children, program: args,
        )
        var environment = invocation.environment
        if let wineDebug {
            // CrossOver assembles its own environment and hands back none,
            // so the channels ride on the process's own.
            var merged = invocation.environment ?? ProcessInfo.processInfo.environment
            merged["WINEDEBUG"] = wineDebug
            environment = merged
        }
        return await run(
            invocation.executable.path,
            invocation.arguments,
            environment: environment,
            timeout: timeout,
        )
    }

    private nonisolated func run(
        _ path: String, _ arguments: [String],
        environment: [String: String]? = nil, timeout: Duration,
    ) async -> SetupCommandOutcome {
        let result = await Subprocess.run(
            path, arguments, environment: environment, capture: .combined, timeout: timeout,
        )
        return SetupCommandOutcome(status: result.status, output: result.output)
    }
}
