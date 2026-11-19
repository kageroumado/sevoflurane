import Foundation
import Observation
import os

/// The idempotent provisioning state machine behind the first-run assistant
/// and Settings › Repair. Every stage is detect → perform → re-detect, so a
/// relaunch mid-setup continues where it left off.
///
/// Machine-touching effects live behind ``SetupEnvironment`` so the DEBUG
/// onboarding harness can run the same flow against a fixture machine.
@MainActor
@Observable
final class Provisioner {
    enum Activity: Equatable {
        case idle
        case working(String)
        case failed(String)
        case done
    }

    /// Where a run is in the fixed stage sequence, for the wizard's progress bar.
    struct Stage: Equatable {
        let index: Int
    }

    private(set) var detection: SetupDetection?
    private(set) var activity: Activity = .idle
    private(set) var stage: Stage?
    /// Progress within the current stage (the engine download), or `nil`
    /// where none is measurable.
    private(set) var stageFraction: Double?
    /// An engine tarball the engine stage installs in place of a download.
    var engineTarball: URL?
    /// Whether this run installs the whole dependency catalog. `nil` reads
    /// ``BottleDependencies/installsEverything`` when the stage runs, because
    /// the wizard's switch is pressed after this object exists.
    var installsEveryDependency: Bool?
    private let environment: any SetupEnvironment

    init(environment: (any SetupEnvironment)? = nil) {
        self.environment = environment ?? LiveSetupEnvironment()
    }

    #if DEBUG
        /// A provisioner frozen mid-story, for the gallery's Repair pane. The
        /// caller passes the environment because the `sevo` target compiles
        /// this file without `SetupDryRun.swift`.
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

    /// Whether effects are simulated; the wizard badges itself so a
    /// screenshot is never mistaken for a real run.
    var isDryRun: Bool {
        environment.isSimulation
    }

    /// True when there is no usable engine, or no Steam in the bottle named
    /// `SteamBottle.name`, the one every launch path addresses.
    var needsSetup: Bool {
        guard detection != nil else { return false }
        let ours = bottleRecord(named: environment.bottleName)?.hasSteam == true
        return !(detection?.hasEngine == true && ours)
    }

    /// The record for `name` under the active engine's bottle root. Never
    /// match by name alone: CrossOver's "Steam" would satisfy a managed-engine
    /// check and skip provisioning.
    private func bottleRecord(named name: String) -> SetupDetection.Bottle? {
        ownBottles.first { $0.name == name }
    }

    /// The bottles under the active engine's root. Roots are compared as
    /// paths: `appendingPathComponent` adds a trailing slash only for a
    /// directory already on disk, so a root not yet created compares unequal.
    var ownBottles: [SetupDetection.Bottle] {
        let root = environment.bottlesRoot.standardizedFileURL.path
        return detection?.bottles.filter {
            $0.url.deletingLastPathComponent().standardizedFileURL.path == root
        } ?? []
    }

    /// Whether no engine is on disk and the built-in one is wanted: the only
    /// case where the wizard offers installing from a file.
    var engineInstallPending: Bool {
        guard let detection else { return false }
        return detection.managedEngineVersions.isEmpty
            && (detection.usableCrossOver == nil || environment.wantsManagedEngine)
    }

    /// Names the bottle the remaining stages address, and answers whether the
    /// choice moved.
    ///
    /// A client in another bottle is stopped first through `stopClient` (the
    /// daemon's stop), while the preference still names its bottle, because
    /// every stop rung aims at the bottles the preference and boot record
    /// name. When `stopClient` answers a refusal, the choice stays and the
    /// pass fails with it. The caller restarts the client afterwards.
    @discardableResult
    func chooseBottle(
        named name: String,
        stoppingClient stopClient: (_ narrate: (String) -> Void) async -> String?,
    ) async -> Bool {
        if !environment.isSimulation, Self.choosingStopsClient(
            chosen: prefixPath(of: name),
            configured: prefixPath(of: environment.bottleName),
            booted: BootedBottle.target?.prefix.standardizedFileURL.path,
        ) {
            activity = .working(InterfaceCopy.localized("Stopping Steam…"))
            SetupLog.log("provision: stopping the client before moving to bottle \(name)")
            if let refusal = await stopClient({ activity = .working(InterfaceCopy.localized($0)) }) {
                activity = .failed(refusal)
                SetupLog.log("provision: the bottle stays \(environment.bottleName) — \(refusal)")
                return false
            }
        }
        activity = .idle
        environment.chooseBottle(named: name)
        return true
    }

    /// Whether choosing the bottle at `chosen` stops the client first: the
    /// preference names another bottle, or the client last booted in one.
    nonisolated static func choosingStopsClient(
        chosen: String, configured: String, booted: String?,
    ) -> Bool {
        chosen != configured || booted.map { $0 != chosen } ?? false
    }

    private func prefixPath(of name: String) -> String {
        environment.bottlesRoot.appendingPathComponent(name).standardizedFileURL.path
    }

    func refreshDetection() async {
        detection = await environment.detect()
    }

    // MARK: - Stage actions

    /// Runs every stage whose product detection does not find.
    /// `rebuildingSteam` reruns the bootstrapper and headless update over a
    /// provisioned bottle to repair damaged client files, leaving Rosetta,
    /// the engine, the prefix and its games and saves as they are.
    private func provisionSteam(rebuildingSteam: Bool) async {
        guard detection != nil else { return }
        let interval = PerfProbe.setup.beginInterval("Provision")
        defer { PerfProbe.setup.endInterval("Provision", interval) }
        let bottleName = environment.bottleName
        do {
            try await installRosettaIfMissing()
            try await installEngineIfMissing()
            // The engine stage can move the bottles root; the lease follows.
            holdBottle()
            try await createBottleIfMissing(bottleName)
            try await installBootstrapper(inBottle: bottleName, force: rebuildingSteam)
            try await updateClient(inBottle: bottleName, force: rebuildingSteam)
            try await installGameDependencies()
            activity = .done
            if !environment.isSimulation { BottleReadiness.recordProvisionSucceeded() }
            SetupLog.log("provision: Steam client present in bottle \(bottleName)")
        } catch {
            activity = .failed("\(error)")
            if !environment.isSimulation {
                BottleReadiness.recordProvisionFailed(
                    "\(error)",
                    blocksClientStart: (error as? ProvisionError)?.leavesNothingToStart ?? false,
                )
            }
            SetupLog.log("provision failed: \(error)")
        }
        stage = nil
        stageFraction = nil
    }

    /// Re-runs a failed pass from the stage that failed.
    func retry() async {
        guard case .failed = activity else { return }
        activity = .idle
        await refreshDetection()
        await provisionAndConfigure()
    }

    private func beginStage(_ index: Int, _ phase: String) {
        stage = Stage(index: index)
        stageFraction = nil
        activity = .working(InterfaceCopy.localized(phase))
    }

    private func installGameDependencies() async throws {
        let all = installsEveryDependency ?? BottleDependencies.installsEverything
        for dependency in BottleDependencies.provisioned(all: all) {
            guard !environment.isDependencyInstalled(dependency) else { continue }
            beginStage(6, String(localized: "Installing \(dependency.name)…"))
            let result = await environment.installDependency(dependency)
            guard result.succeeded, environment.isDependencyInstalled(dependency) else {
                // Only a required entry ends setup; the rest can be
                // installed later from Settings › Engine.
                guard dependency.required else {
                    SetupLog.log("provision: \(dependency.name) did not install: "
                        + "\(result.output.suffix(200))")
                    continue
                }
                throw ProvisionError(String(localized: "\(dependency.name) installation failed: \(result.output.suffix(300))"))
            }
        }
    }

    /// The whole stack is x86_64, so nothing runs without Rosetta.
    private func installRosettaIfMissing() async throws {
        guard detection?.rosetta == false else { return }
        beginStage(1, "Installing Rosetta…")
        SetupLog.log("provision: installing Rosetta")
        let result = await environment.installRosetta()
        guard result.succeeded else {
            // A standard (non-administrator) account can be refused here, so
            // the error names the command an administrator can run.
            throw ProvisionError(
                String(localized: "Rosetta install failed: \(result.output.suffix(200)). If this account isn't an administrator, run \"softwareupdate --install-rosetta --agree-to-license\" in Terminal as one, then Try Again."),
            )
        }
        await refreshDetection()
    }

    /// Installs the managed engine when nothing else can run Steam or the
    /// stored engine choice asks for it despite a usable CrossOver.
    private func installEngineIfMissing() async throws {
        guard let detection else { return }
        let managedWanted = detection.usableCrossOver == nil
            || environment.wantsManagedEngine
        if managedWanted, detection.managedEngineVersions.isEmpty {
            beginStage(2, "Installing the game engine…")
            SetupLog.log("provision: installing managed engine")
            let result = await environment.installEngine(from: engineTarball, progress: engineProgress())
            guard result.succeeded else {
                throw ProvisionError(
                    String(localized: "engine install failed: \(result.output.suffix(200))"),
                    leavesNothingToStart: true,
                )
            }
            engineTarball = nil
            await refreshDetection()
        }
        // A dry run must never redirect the real process's wine invocations.
        if let refreshed = self.detection, !environment.isSimulation {
            Engine.active = Engine.resolve(from: refreshed)
        }
        guard self.detection?.hasEngine == true else {
            throw ProvisionError(InterfaceCopy.localized("no usable engine after install"), leavesNothingToStart: true)
        }
    }

    /// Installs an engine tarball or tree from disk outside the provisioning
    /// sequence (Settings › Engine), answering the version installed; the
    /// caller decides whether to switch to it.
    func installEngine(from source: URL) async throws -> String {
        guard !isWorking else {
            throw ProvisionError(InterfaceCopy.localized("setup is already running"))
        }
        beginStage(2, "Installing the game engine…")
        SetupLog.log("installing engine from \(source.path)")
        let result = await environment.installEngine(from: source, progress: engineProgress())
        stage = nil
        stageFraction = nil
        activity = .idle
        await refreshDetection()
        guard result.succeeded else {
            throw ProvisionError(String(localized: "engine install failed: \(result.output.suffix(200))"))
        }
        return result.output
    }

    /// Setup is installing or repairing something.
    var isWorking: Bool {
        if case .working = activity { true } else { false }
    }

    /// The engine stage's narration: each new phase is logged once.
    private func engineProgress() -> @Sendable (String, Double?) -> Void {
        { [weak self] phase, fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let localizedPhase = InterfaceCopy.localized(phase)
                    if self?.activity != .working(localizedPhase) {
                        SetupLog.log("engine install: \(phase)")
                        self?.activity = .working(localizedPhase)
                    }
                    self?.stageFraction = fraction
                }
            }
        }
    }

    private func createBottleIfMissing(_ bottleName: String) async throws {
        // A Steam-less bottle whose boot never finished, or that Steam's
        // installer failed in, is set aside and rebuilt: the installer would
        // fail the same way again.
        let rebuilding = bottleRecord(named: bottleName).map {
            !$0.hasSteam && (!environment.bottleIsComplete(named: bottleName)
                || environment.steamInstallerFailed(inBottle: bottleName))
        }
        if rebuilding == false { return }
        beginStage(3, "Creating the Steam environment…")
        if rebuilding == true {
            do {
                let aside = try await environment.setAsideBottle(named: bottleName)
                SetupLog.log("provision: bottle \(bottleName) is unfinished or Steam's installer failed in it; set it aside as \(aside) to build it again")
            } catch {
                throw ProvisionError(
                    String(localized: "could not set aside an unfinished bottle: \(error.localizedDescription)"),
                    leavesNothingToStart: true,
                )
            }
            await refreshDetection()
        }
        SetupLog.log("provision: creating bottle \(bottleName) (win10_64)")
        let create = await environment.createBottle(named: bottleName)
        guard create.succeeded else {
            throw ProvisionError(
                String(localized: "bottle creation failed: \(create.output.suffix(200))"),
                leavesNothingToStart: true,
            )
        }
        await refreshDetection()
        guard environment.bottleIsComplete(named: bottleName) else {
            SetupLog.log("provision: bottle \(bottleName) booted without its 32-bit system DLLs (syswow64)")
            throw ProvisionError(
                String(localized: "the new bottle has no 32-bit Windows files, so the engine may be damaged"),
                leavesNothingToStart: true,
            )
        }
    }

    private func installBootstrapper(
        inBottle bottleName: String, force: Bool,
    ) async throws {
        guard force || !steamPresent(inBottle: bottleName) else { return }

        beginStage(4, "Downloading the Steam installer…")
        SetupLog.log("provision: downloading SteamSetup.exe")
        try await environment.downloadSteamInstaller(intoBottle: bottleName)

        activity = .working(InterfaceCopy.localized("Installing Steam…"))
        await environment.settleBottle(named: bottleName)
        SetupLog.log("provision: silent NSIS install")
        let install = await environment.runSteamInstaller(inBottle: bottleName)
        guard install.succeeded else {
            environment.markSteamInstallerFailed(inBottle: bottleName)
            let status = install.status.map(String.init) ?? InterfaceCopy.localized("no exit status")
            let output = install.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProvisionError(
                output.isEmpty
                    ? String(localized: "Steam installer failed (exit \(status)) without printing anything")
                    : String(localized: "Steam installer failed (exit \(status)): \(output.suffix(200))"),
                leavesNothingToStart: true,
            )
        }
    }

    /// Bootstrapper → full client with no login (the lancache-prefill trick).
    /// A complete client is left to update itself, since its own updater owns
    /// the same files; `force` is the rebuild, which stops the client first.
    private func updateClient(inBottle bottleName: String, force: Bool) async throws {
        guard force || !clientFullyUpdated(inBottle: bottleName) else { return }
        beginStage(
            5,
            steamPresent(inBottle: bottleName)
                ? "Updating Steam…"
                : "Downloading Steam (this is the long step)…",
        )
        // The CDN bootstrapper's first update replaces the updater, which
        // then wants the separate win64 package (hundreds of MB); looping
        // until its manifest lands keeps that download out of first launch.
        // Passes continue while each moves bytes into `package/`, because a
        // small fixed cap gives up mid-download on a slow switch.
        var lastPayload = packagePayloadBytes(inBottle: bottleName)
        for pass in 1 ... 6 {
            if pass > 1 {
                SetupLog.log("provision: updater replaced itself — update pass \(pass)")
                activity = .working(InterfaceCopy.localized("Updating Steam…"))
            } else {
                SetupLog.log("provision: headless client update")
            }
            await environment.updateSteamClient(inBottle: bottleName)
            await refreshDetection()
            if clientFullyUpdated(inBottle: bottleName) { return }
            let payload = packagePayloadBytes(inBottle: bottleName)
            if payload == lastPayload, pass > 1 { break }
            lastPayload = payload
        }
        guard steamPresent(inBottle: bottleName)
            || FileManager.default.fileExists(atPath: steamExePath(inBottle: bottleName))
        else {
            throw ProvisionError(
                InterfaceCopy.localized("client update finished but steamclient64.dll is missing"),
                leavesNothingToStart: true,
            )
        }
        // The client applies staged packages at first launch, so an
        // incomplete headless pass is not a failure.
        SetupLog.log("provision: update incomplete after the headless passes — "
            + "the client applies the staged packages at first launch")
    }

    private func steamExePath(inBottle name: String) -> String {
        let bottle = environment.bottlesRoot.appendingPathComponent(name)
        return SteamBottle.steamRoot(inBottle: bottle)
            .appendingPathComponent("Steam.exe").path
    }

    /// Bytes in the client's `package/` staging directory.
    private func packagePayloadBytes(inBottle name: String) -> Int64 {
        let bottle = environment.bottlesRoot.appendingPathComponent(name)
        let package = SteamBottle.steamRoot(inBottle: bottle)
            .appendingPathComponent("package")
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: package.path)) ?? []
        return names.reduce(Int64(0)) { total, name in
            let path = package.appendingPathComponent(name).path
            let size = (try? FileManager.default
                .attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
            return total + size
        }
    }

    /// Whether the client is fully updated: the win64 package manifest is the
    /// last thing the updater installs.
    private func clientFullyUpdated(inBottle name: String) -> Bool {
        guard !environment.isSimulation else {
            return steamPresent(inBottle: name)
        }
        guard steamPresent(inBottle: name) else { return false }
        let bottle = environment.bottlesRoot.appendingPathComponent(name)
        let manifest = SteamBottle.steamRoot(inBottle: bottle)
            .appendingPathComponent("package/steam_client_win64.installed")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    /// Applies the idempotent bottle configuration: tray suppression, the SDL
    /// bus value, the GPU registry entry and the graphics files. CrossOver's
    /// driver ignores the tray values, so `BottleSupervisor.suppressWineTray`
    /// removes its status item once the client is up.
    func configureBottle(named name: String) async {
        // Never touches `activity`: the wizard's Continue button gates on `.done`.
        await environment.configureBottle(named: name)
    }

    /// Ends the bottle's Wine processes when the app quits mid-stage, since
    /// nothing else owns them.
    func endForQuit() async {
        guard isWorking else { return }
        SetupLog.log("provision: quitting mid-setup — ending the bottle's processes")
        await environment.endWineProcesses(inBottle: environment.bottleName)
    }

    /// The wizard's whole sequence: install Steam, then configure the bottle.
    /// The bottle is held (``ProvisioningLease``) throughout so the daemon
    /// starts no client in it.
    func provisionAndConfigure(rebuildingSteam: Bool = false) async {
        holdBottle()
        defer { releaseBottle() }
        await provisionSteam(rebuildingSteam: rebuildingSteam)
        if case .done = activity {
            await configureBottle(named: environment.bottleName)
        }
    }

    /// The prefix this pass holds, and the task renewing the hold.
    private var leasedPrefix: URL?
    private var leaseRenewal: Task<Void, Never>?

    /// Takes the lease on the bottle the stages address, or moves it there.
    private func holdBottle() {
        guard !environment.isSimulation else { return }
        let prefix = environment.bottlesRoot.appendingPathComponent(environment.bottleName)
        if let leasedPrefix, leasedPrefix != prefix { ProvisioningLease.release(leasedPrefix) }
        leasedPrefix = prefix
        ProvisioningLease.take(prefix)
        guard leaseRenewal == nil else { return }
        leaseRenewal = Task(name: "Renew the provisioning lease") { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ProvisioningLease.renewal)
                guard !Task.isCancelled, let prefix = self?.leasedPrefix else { return }
                ProvisioningLease.take(prefix)
            }
        }
    }

    private func releaseBottle() {
        leaseRenewal?.cancel()
        leaseRenewal = nil
        if let leasedPrefix { ProvisioningLease.release(leasedPrefix) }
        leasedPrefix = nil
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
        bottleRecord(named: bottleName)?.hasSteam == true
    }

    private struct ProvisionError: Error, CustomStringConvertible {
        let description: String
        /// Whether the failed stage leaves no engine, bottle or Steam, which
        /// holds the client start until a retry or the user overrides it.
        let leavesNothingToStart: Bool

        init(_ description: String, leavesNothingToStart: Bool = false) {
            self.description = description
            self.leavesNothingToStart = leavesNothingToStart
        }
    }
}
