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
    func installEngine(progress: @Sendable (String) -> Void) async -> SetupCommandOutcome

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

    func installEngine(progress: @Sendable (String) -> Void) async -> SetupCommandOutcome {
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
        case .crossover:
            return await run(
                SteamBottle.crossoverBin + "/cxbottle",
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
        _ = await runWine(bottle: name, args: [
            "reg", "add", #"HKCU\Software\Wine\Explorer"#,
            "/v", "ShowSystray", "/t", "REG_SZ", "/d", "N", "/f",
        ])
        // Wine's own renderer reads the card from the registry rather than
        // the environment, so the choice has to be written twice to be one
        // choice.
        for entry in BottleGraphics.currentSelection().gpu.wineD3DRegistry {
            _ = await runWine(bottle: name, args: [
                "reg", "add", #"HKCU\Software\Wine\Direct3D"#,
                "/v", entry.value, "/t", "REG_DWORD", "/d", entry.data, "/f",
            ])
        }
        let bottle = Engine.active.bottlesRoot.appendingPathComponent(name)
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
