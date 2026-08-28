import Foundation
import Observation
import os

/// The idempotent provisioning state machine behind the first-run assistant
/// and Settings › Repair (`Docs/onboarding-spec.md`). Every stage is
/// detect → perform → re-detect; quitting mid-setup and relaunching continues
/// where it left off because detection, not stored progress, decides what
/// still needs doing.
///
/// Policy lives here; the machine-touching effects live behind
/// ``SetupEnvironment`` so the DEBUG onboarding harness can run the same flow
/// against a fixture machine.
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
    private let environment: any SetupEnvironment

    init(environment: (any SetupEnvironment)? = nil) {
        self.environment = environment ?? LiveSetupEnvironment()
    }

    #if DEBUG
        /// A provisioner frozen mid-story, for the gallery's Repair pane.
        convenience init(previewActivity: Activity, detection: SetupDetection? = nil) {
            self.init(environment: DryRunSetupEnvironment(
                scenario: .provisioned, stepDelay: .zero,
            ))
            activity = previewActivity
            self.detection = detection
        }
    #endif

    /// Whether effects are simulated — the wizard badges itself so a
    /// screenshot can never be mistaken for a real run.
    var isDryRun: Bool {
        environment.isSimulation
    }

    /// True when the app cannot reach a working library without the wizard:
    /// no usable engine, or no Steam in the bottle we actually drive.
    ///
    /// The bottle's *name* matters: every path below this — `SteamBottle.root`,
    /// the launch lines, the kill ladder — addresses `SteamBottle.name`, so a
    /// Steam sitting in some other bottle is not a provisioned machine. (The
    /// multi-bottle picker that would adopt one is release-plan R2.3.)
    var needsSetup: Bool {
        guard let detection else { return false }
        let ours = detection.steamBottles.contains { $0.name == SteamBottle.name }
        return !(detection.hasEngine && ours)
    }

    func refreshDetection() async {
        detection = await environment.detect()
    }

    // MARK: - Stage actions

    /// Creates the Steam bottle if missing, silent-installs the Steam
    /// bootstrapper, then runs the headless full-client update. Each stage is
    /// skipped when detection says its product already exists.
    func provisionSteam() async {
        guard detection != nil else { return }
        let interval = PerfProbe.setup.beginInterval("Provision")
        defer { PerfProbe.setup.endInterval("Provision", interval) }
        let bottleName = SteamBottle.name
        do {
            try await installRosettaIfMissing()
            try await installEngineIfMissing()
            try await createBottleIfMissing(bottleName)
            try await installBootstrapperIfMissing(inBottle: bottleName)
            try await updateClient(inBottle: bottleName)
            activity = .done
            SetupLog.log("provision: Steam client present in bottle \(bottleName)")
        } catch {
            activity = .failed("\(error)")
            SetupLog.log("provision failed: \(error)")
        }
    }

    /// The whole stack is x86_64; without Rosetta neither cxbottle nor the
    /// client runs. `softwareupdate` shows Apple's own progress; nothing of
    /// ours to configure.
    private func installRosettaIfMissing() async throws {
        guard detection?.rosetta == false else { return }
        activity = .working("Installing Rosetta…")
        SetupLog.log("provision: installing Rosetta")
        let result = await environment.installRosetta()
        guard result.succeeded else {
            throw ProvisionError("Rosetta install failed: \(result.output.suffix(200))")
        }
        await refreshDetection()
    }

    /// A usable CrossOver wins outright; otherwise the managed engine is
    /// downloaded from the manifest (release-plan R2.2) and every wine
    /// invocation from here on routes through it.
    private func installEngineIfMissing() async throws {
        guard let detection, detection.usableCrossOver == nil else { return }
        if detection.managedEngineVersions.isEmpty {
            activity = .working("Installing the game engine…")
            SetupLog.log("provision: installing managed engine")
            let result = await environment.installEngine { phase in
                SetupLog.log("engine install: \(phase)")
            }
            guard result.succeeded else {
                throw ProvisionError("engine install failed: \(result.output.suffix(200))")
            }
            await refreshDetection()
        }
        // A dry run must never redirect the real process's wine invocations.
        if let refreshed = self.detection, !environment.isSimulation {
            Engine.active = Engine.resolve(from: refreshed)
        }
        guard self.detection?.hasEngine == true else {
            throw ProvisionError("no usable engine after install")
        }
    }

    private func createBottleIfMissing(_ bottleName: String) async throws {
        guard detection?.bottles.contains(where: { $0.name == bottleName }) != true else {
            return
        }
        activity = .working("Creating the Steam environment…")
        SetupLog.log("provision: creating bottle \(bottleName) (win10_64)")
        let create = await environment.createBottle(named: bottleName)
        guard create.succeeded else {
            throw ProvisionError("bottle creation failed: \(create.output.suffix(200))")
        }
        await refreshDetection()
    }

    private func installBootstrapperIfMissing(inBottle bottleName: String) async throws {
        guard !steamPresent(inBottle: bottleName) else { return }

        activity = .working("Downloading the Steam installer…")
        SetupLog.log("provision: downloading SteamSetup.exe")
        try await environment.downloadSteamInstaller(intoBottle: bottleName)

        activity = .working("Installing Steam…")
        SetupLog.log("provision: silent NSIS install")
        let install = await environment.runSteamInstaller(inBottle: bottleName)
        guard install.succeeded else {
            throw ProvisionError("Steam installer failed: \(install.output.suffix(200))")
        }
    }

    /// Bootstrapper → full client, no login needed (the lancache-prefill
    /// trick). On a bottle that already has Steam this is the update pass —
    /// `-forcesteamupdate -forcepackagedownload` brings a client of any age
    /// up to current, which is why adoption and Repair both run it.
    private func updateClient(inBottle bottleName: String) async throws {
        activity = .working(steamPresent(inBottle: bottleName)
            ? "Updating Steam…"
            : "Downloading Steam (this is the long step)…")
        SetupLog.log("provision: headless client update")
        await environment.updateSteamClient(inBottle: bottleName)
        await refreshDetection()
        guard steamPresent(inBottle: bottleName) else {
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
        // Leaves `activity` alone: the wizard's Continue button gates on
        // `.done`, which this reassert must not overwrite.
        await environment.configureBottle(named: name)
    }

    /// The wizard's whole sequence: install Steam, then apply the idempotent
    /// bottle configuration the boot path also reasserts.
    func provisionAndConfigure() async {
        await provisionSteam()
        if case .done = activity {
            await configureBottle(named: SteamBottle.name)
        }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            try environment.setOpenAtLogin(enabled)
        } catch {
            SetupLog.log("open-at-login change failed: \(error)")
        }
    }

    var openAtLogin: Bool {
        environment.openAtLogin
    }

    private func steamPresent(inBottle bottleName: String) -> Bool {
        detection?.bottles.first { $0.name == bottleName }?.hasSteam == true
    }

    private struct ProvisionError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
