import Foundation
import Observation
import ServiceManagement

/// The idempotent provisioning state machine behind the first-run assistant
/// and Settings › Repair (`Docs/onboarding-spec.md`). Every stage is
/// detect → perform → re-detect; quitting mid-setup and relaunching continues
/// where it left off because detection, not stored progress, decides what
/// still needs doing.
@MainActor
@Observable
final class Provisioner {
    enum Activity: Equatable {
        case idle
        case working(String)
        case failed(String)
        case done
    }

    private(set) var detection: SetupDetection?
    private(set) var activity: Activity = .idle
    private let log = EventLog.shared

    /// True when the app cannot reach a working library without the wizard:
    /// no usable engine, or no bottle with Steam in it.
    var needsSetup: Bool {
        guard let detection else { return false }
        return !(detection.hasEngine && !detection.steamBottles.isEmpty)
    }

    func refreshDetection() async {
        detection = await SetupProbe.detect()
    }

    // MARK: - Stage actions

    /// `softwareupdate --install-rosetta` — Apple's own license prompt and
    /// progress; nothing of ours to configure.
    func installRosetta() async {
        activity = .working("Installing Rosetta…")
        let result = await Self.run(
            "/usr/sbin/softwareupdate",
            ["--install-rosetta", "--agree-to-license"],
        )
        activity = result.status == 0
            ? .idle
            : .failed("Rosetta install failed: \(result.output.suffix(200))")
        await refreshDetection()
    }

    /// Creates the Steam bottle if missing, silent-installs the Steam
    /// bootstrapper, then runs the headless full-client update. Each stage is
    /// skipped when detection says its product already exists.
    func provisionSteam() async {
        guard let detection else { return }
        guard detection.usableCrossOver != nil else {
            activity = .failed("No usable engine — the built-in engine pipeline "
                + "is not wired yet (release-plan R2.2); install CrossOver for now.")
            return
        }
        let bottleName = "Steam"
        do {
            try await createBottleIfMissing(bottleName, detection: detection)
            try await installBootstrapperIfMissing(inBottle: bottleName)
            try await updateClient(inBottle: bottleName)
            activity = .done
            log.log(.client, "provision: Steam client present in bottle \(bottleName)")
        } catch {
            activity = .failed("\(error)")
            log.log(.client, "provision failed: \(error)")
        }
    }

    private func createBottleIfMissing(
        _ bottleName: String,
        detection: SetupDetection,
    ) async throws {
        guard !detection.bottles.contains(where: { $0.name == bottleName }) else { return }
        activity = .working("Creating the Steam environment…")
        log.log(.client, "provision: creating bottle \(bottleName) (win10_64)")
        let create = await Self.run(
            Self.crossoverBin + "/cxbottle",
            [
                "--bottle",
                bottleName,
                "--create",
                "--template",
                "win10_64",
                "--description",
                "Sevoflurane Steam",
            ],
        )
        guard create.status == 0 else {
            throw ProvisionError("bottle creation failed: \(create.output.suffix(200))")
        }
    }

    private func installBootstrapperIfMissing(inBottle bottleName: String) async throws {
        let bottleURL = SetupProbe.crossoverBottles.appendingPathComponent(bottleName)
        let steamDLL = bottleURL.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steamclient64.dll",
        )
        guard !FileManager.default.fileExists(atPath: steamDLL.path) else { return }

        activity = .working("Downloading the Steam installer…")
        log.log(.client, "provision: downloading SteamSetup.exe")
        let (temp, _) = try await URLSession.shared.download(from: Self.steamSetupURL)
        let setup = bottleURL.appendingPathComponent("drive_c/SteamSetup.exe")
        try? FileManager.default.removeItem(at: setup)
        try FileManager.default.moveItem(at: temp, to: setup)

        activity = .working("Installing Steam…")
        log.log(.client, "provision: silent NSIS install")
        let install = await Self.runWine(
            bottle: bottleName,
            args: [#"C:\SteamSetup.exe"#, "/S"],
        )
        guard install.status == 0 else {
            throw ProvisionError("Steam installer failed: \(install.output.suffix(200))")
        }
    }

    /// Bootstrapper → full client, no login needed (the lancache-prefill
    /// trick); doubles as the update pass on existing installs.
    private func updateClient(inBottle bottleName: String) async throws {
        activity = .working("Downloading Steam (this is the long step)…")
        log.log(.client, "provision: headless client update")
        _ = await Self.runWine(
            bottle: bottleName,
            args: [
                Self.steamExe,
                "-forcesteamupdate",
                "-forcepackagedownload",
                "-exitsteam",
            ],
            timeout: 1800,
        )
        await refreshDetection()
        guard detectionHasSteam else {
            throw ProvisionError("client update finished but steamclient64.dll is missing")
        }
    }

    /// Applies the idempotent bottle configuration every adoption gets —
    /// today the tray suppression; renderer/msync knobs land here too.
    ///
    /// The tray values gate explorer.exe's own systray window, which the Mac
    /// driver's path bypasses entirely (see SPEC), so neither removes Steam's
    /// status item here — `ClientSupervisor.suppressWineTray` does. They are
    /// still written because they are correct for the non-driver path an OSS
    /// Wine build may take.
    func configureBottle(named name: String) async {
        activity = .working("Configuring for background use…")
        _ = await Self.runWine(bottle: name, args: [
            "reg", "add", #"HKCU\Software\Wine\Explorer"#,
            "/v", "ShowSystray", "/t", "REG_SZ", "/d", "N", "/f",
        ])
        activity = .idle
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.log(.supervisor, "open-at-login change failed: \(error)")
        }
    }

    var openAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private var detectionHasSteam: Bool {
        !(detection?.steamBottles.isEmpty ?? true)
    }

    // MARK: - Process plumbing

    private struct ProvisionError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }

    private static let crossoverBin =
        "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
    private static let steamExe = #"C:\Program Files (x86)\Steam\Steam.exe"#
    private static let steamSetupURL =
        URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!

    private nonisolated static func runWine(
        bottle: String, args: [String], timeout: TimeInterval = 600,
    ) async -> (status: Int32, output: String) {
        await run(
            crossoverBin + "/wine",
            ["--bottle", bottle, "--wait-children"] + args,
            timeout: timeout,
        )
    }

    private nonisolated static func run(
        _ launchPath: String, _ arguments: [String], timeout: TimeInterval = 600,
    ) async -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            process.terminate()
        }
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        }
        watchdog.cancel()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return (status, String(data: data, encoding: .utf8) ?? "")
    }
}
