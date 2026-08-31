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

    /// Where a run is in the fixed stage sequence, for the wizard's overall
    /// progress bar. Stages that detection skips flash past; the count stays
    /// honest because the sequence itself never changes.
    struct Stage: Equatable {
        let index: Int
        static let count = 5
    }

    private(set) var detection: SetupDetection?
    private(set) var activity: Activity = .idle
    private(set) var stage: Stage?
    /// Progress within the current stage (the engine download), or `nil`
    /// where none is measurable.
    private(set) var stageFraction: Double?
    private let environment: any SetupEnvironment

    init(environment: (any SetupEnvironment)? = nil) {
        self.environment = environment ?? LiveSetupEnvironment()
    }

    #if DEBUG
        /// A provisioner frozen mid-story, for the gallery's Repair pane. The
        /// environment comes from the caller so this file stays buildable
        /// where the harness is not — the `sevo` target compiles it without
        /// `SetupDryRun.swift`.
        convenience init(
            previewActivity: Activity,
            detection: SetupDetection? = nil,
            environment: any SetupEnvironment,
        ) {
            self.init(environment: environment)
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
        stage = nil
        stageFraction = nil
    }

    /// Re-runs a failed provisioning pass. Detection decides what still needs
    /// doing, so only the stage that failed (and those after it) run again.
    func retry() async {
        guard case .failed = activity else { return }
        activity = .idle
        await refreshDetection()
        await provisionAndConfigure()
    }

    private func beginStage(_ index: Int, _ phase: String) {
        stage = Stage(index: index)
        stageFraction = nil
        activity = .working(phase)
    }

    /// The whole stack is x86_64; without Rosetta neither cxbottle nor the
    /// client runs. `softwareupdate` shows Apple's own progress; nothing of
    /// ours to configure.
    private func installRosettaIfMissing() async throws {
        guard detection?.rosetta == false else { return }
        beginStage(1, "Installing Rosetta…")
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
            beginStage(2, "Installing the game engine…")
            SetupLog.log("provision: installing managed engine")
            let result = await environment.installEngine { phase, fraction in
                Task { @MainActor [weak self] in
                    if self?.activity != .working(phase) {
                        SetupLog.log("engine install: \(phase)")
                        self?.activity = .working(phase)
                    }
                    self?.stageFraction = fraction
                }
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
        beginStage(3, "Creating the Steam environment…")
        SetupLog.log("provision: creating bottle \(bottleName) (win10_64)")
        let create = await environment.createBottle(named: bottleName)
        guard create.succeeded else {
            throw ProvisionError("bottle creation failed: \(create.output.suffix(200))")
        }
        await refreshDetection()
    }

    private func installBootstrapperIfMissing(inBottle bottleName: String) async throws {
        guard !steamPresent(inBottle: bottleName) else { return }

        beginStage(4, "Downloading the Steam installer…")
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
        beginStage(5, steamPresent(inBottle: bottleName)
            ? "Updating Steam…"
            : "Downloading Steam (this is the long step)…")
        // The CDN's bootstrapper is old enough that its first update replaces
        // the updater itself, and the new updater then wants the separate
        // win64 client package. One pass leaves that package for the user's
        // first launch to download (measured: 235 MB and ~80 s of updater
        // window); looping until the win64 manifest lands absorbs it here,
        // where "Updating Steam…" is already on screen.
        for pass in 1 ... 3 {
            if pass > 1 {
                SetupLog.log("provision: updater replaced itself — update pass \(pass)")
                activity = .working("Updating Steam…")
            } else {
                SetupLog.log("provision: headless client update")
            }
            await environment.updateSteamClient(inBottle: bottleName)
            await refreshDetection()
            if clientFullyUpdated(inBottle: bottleName) { return }
        }
        guard steamPresent(inBottle: bottleName) else {
            throw ProvisionError("client update finished but steamclient64.dll is missing")
        }
    }

    /// Whether the bottle's client is current enough that a launch goes
    /// straight through: the win64 package manifest is what the self-updated
    /// updater installs last. A dry run has no bottle on disk to ask.
    private func clientFullyUpdated(inBottle name: String) -> Bool {
        guard !environment.isSimulation else {
            return steamPresent(inBottle: name)
        }
        guard steamPresent(inBottle: name) else { return false }
        let bottle = Engine.active.bottlesRoot.appendingPathComponent(name)
        let manifest = SteamBottle.steamRoot(inBottle: bottle)
            .appendingPathComponent("package/steam_client_win64.installed")
        return FileManager.default.fileExists(atPath: manifest.path)
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
