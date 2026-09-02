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

    /// Downloads and installs the manifest's stable managed engine
    /// (release-plan R2.2) — the path taken when no usable CrossOver exists.
    /// The fraction is download progress, or `nil` where none is measurable.
    func installEngine(
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async -> SetupCommandOutcome

    /// `cxbottle --create --template win10_64` under CrossOver; a
    /// `wineboot -u`-initialized prefix under a managed engine.
    func createBottle(named name: String) async -> SetupCommandOutcome

    /// Fetches SteamSetup.exe from the Steam CDN into the bottle's `drive_c`.
    func downloadSteamInstaller(intoBottle name: String) async throws

    /// Runs the NSIS bootstrapper installer silently (`SteamSetup.exe /S`).
    func runSteamInstaller(inBottle name: String) async -> SetupCommandOutcome

    /// Bootstrapper → full client, the long headless download. Exit status is
    /// deliberately unreported: the updater's exit code is unreliable, so the
    /// caller re-detects and judges by what landed on disk.
    func updateSteamClient(inBottle name: String) async

    /// The idempotent per-bottle registry configuration (tray suppression).
    func configureBottle(named name: String) async

    func setOpenAtLogin(_ enabled: Bool) throws
    var openAtLogin: Bool { get }
}

extension SetupEnvironment {
    var isSimulation: Bool {
        false
    }
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
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async -> SetupCommandOutcome {
        do {
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

    func runSteamInstaller(inBottle name: String) async -> SetupCommandOutcome {
        await runWine(bottle: name, args: [#"C:\SteamSetup.exe"#, "/S"])
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
        // the whole subprocess timeout (three wedged start.exe were caught
        // doing exactly that, 2026-09-01), and every boot after the first
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
        // winebus's SDL backend, with no video subsystem to wait on, polls
        // every millisecond forever — measured 2.6 % CPU and ~1,200 wakeups/s
        // in winedevice.exe at idle under Rosetta; zero with the backend off.
        // Controllers keep the IOHID backend, and Steam Input reads raw HID
        // anyway — the same default Proton ships (hidraw first,
        // PROTON_PREFER_SDL to opt back in).
        if !registry(
            of: bottleURL, file: "system.reg", contains: #""Enable SDL"=dword:00000000"#,
        ) {
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

    var openAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Wine's own chatter still comes back combined: provisioning quotes it
    /// in failure messages, and these invocations are rare and bounded.
    private nonisolated func runWine(
        bottle: String, args: [String], timeout: Duration = .seconds(600),
    ) async -> SetupCommandOutcome {
        let invocation = Engine.active.wineInvocation(
            bottle: bottle, wait: .children, program: args,
        )
        return await run(
            invocation.executable.path,
            invocation.arguments,
            environment: invocation.environment,
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
