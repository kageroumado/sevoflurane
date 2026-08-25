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

    /// `cxbottle --create --template win10_64`.
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

    func createBottle(named name: String) async -> SetupCommandOutcome {
        await run(
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
    }

    func downloadSteamInstaller(intoBottle name: String) async throws {
        let bottleURL = SteamBottle.bottlesRoot.appendingPathComponent(name)
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
        await run(
            SteamBottle.crossoverBin + "/wine",
            ["--bottle", bottle, "--wait-children"] + args,
            timeout: timeout,
        )
    }

    private nonisolated func run(
        _ path: String, _ arguments: [String], timeout: Duration,
    ) async -> SetupCommandOutcome {
        let result = await Subprocess.run(
            path, arguments, capture: .combined, timeout: timeout,
        )
        return SetupCommandOutcome(status: result.status, output: result.output)
    }
}
