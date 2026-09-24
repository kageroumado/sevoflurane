import Foundation
import Observation
import os

/// The idempotent provisioning state machine behind the first-run assistant
/// and Settings › Repair. Every stage is
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
        static let count = 6
    }

    private(set) var detection: SetupDetection?
    private(set) var activity: Activity = .idle
    private(set) var stage: Stage?
    /// Progress within the current stage (the engine download), or `nil`
    /// where none is measurable.
    private(set) var stageFraction: Double?
    /// An engine tarball to install in place of a download — chosen in the
    /// wizard or Settings by someone who has the file, the release asset
    /// saved by hand on a Mac the release feed does not reach. The engine
    /// stage consumes it.
    var engineTarball: URL?
    /// Whether this run installs the whole dependency catalog rather than the
    /// required entries alone. `nil` reads
    /// ``BottleDependencies/installsEverything`` when the stage runs, which is
    /// what the wizard needs: its switch is pressed after this object exists.
    var installsEveryDependency: Bool?
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
    /// Steam sitting in some other bottle is not a provisioned machine.
    var needsSetup: Bool {
        guard detection != nil else { return false }
        let ours = bottleRecord(named: environment.bottleName)?.hasSteam == true
        return !(detection?.hasEngine == true && ours)
    }

    /// The record for `name` under the *active engine's* bottle root. A
    /// CrossOver bottle and a managed prefix can share a name, and only the
    /// active engine's one counts — matching by name alone let CrossOver's
    /// "Steam" satisfy a managed-engine check and skip provisioning
    /// entirely.
    ///
    /// The roots are compared as paths: `appendingPathComponent` gives a
    /// directory URL a trailing slash only when that directory is already on
    /// disk, so on a Mac whose bottle root does not exist yet the one
    /// directory spelled two ways is two unequal URLs.
    private func bottleRecord(named name: String) -> SetupDetection.Bottle? {
        ownBottles.first { $0.name == name }
    }

    /// The bottles under the active engine's root: the ones a name chosen in
    /// the wizard can mean. CrossOver's bottles and a managed engine's live
    /// in different folders and can share names, "Steam" above all.
    var ownBottles: [SetupDetection.Bottle] {
        let root = environment.bottlesRoot.standardizedFileURL.path
        return detection?.bottles.filter {
            $0.url.deletingLastPathComponent().standardizedFileURL.path == root
        } ?? []
    }

    /// Whether what still needs doing starts with the engine: none on disk
    /// and the built-in one wanted. The wizard offers the file route only
    /// then — a failure past the engine has nothing a tarball fixes.
    var engineInstallPending: Bool {
        guard let detection else { return false }
        return detection.managedEngineVersions.isEmpty
            && (detection.usableCrossOver == nil || environment.wantsManagedEngine)
    }

    /// Names the bottle the remaining stages address. The wizard asks only
    /// where detection found more than one Steam; a dry run's answer stays
    /// inside the fixture.
    func chooseBottle(named name: String) {
        environment.chooseBottle(named: name)
    }

    func refreshDetection() async {
        detection = await environment.detect()
    }

    // MARK: - Stage actions

    /// Creates the Steam bottle if missing, silent-installs the Steam
    /// bootstrapper, then runs the headless full-client update. Each stage is
    /// skipped when detection says its product already exists.
    ///
    /// `rebuildingSteam` runs the two Steam stages over a bottle detection
    /// already calls provisioned: the bootstrapper is fetched and run again
    /// and the headless update follows it, which is how a client whose own
    /// files are damaged is made whole. Rosetta, the engine and the prefix
    /// stay as they are, and so do the games and saves inside it.
    func provisionSteam(rebuildingSteam: Bool = false) async {
        guard detection != nil else { return }
        let interval = PerfProbe.setup.beginInterval("Provision")
        defer { PerfProbe.setup.endInterval("Provision", interval) }
        let bottleName = environment.bottleName
        do {
            try await installRosettaIfMissing()
            try await installEngineIfMissing()
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

    private func installGameDependencies() async throws {
        let all = installsEveryDependency ?? BottleDependencies.installsEverything
        for dependency in BottleDependencies.provisioned(all: all) {
            guard !environment.isDependencyInstalled(dependency) else { continue }
            beginStage(6, "Installing \(dependency.name)…")
            let result = await environment.installDependency(dependency)
            guard result.succeeded, environment.isDependencyInstalled(dependency) else {
                // A bottle without a font pack or a legacy runtime still runs
                // Steam and its games, so only a required entry is worth
                // ending the whole setup over; the rest are installable again
                // from Settings › Engine.
                guard dependency.required else {
                    SetupLog.log("provision: \(dependency.name) did not install: "
                        + "\(result.output.suffix(200))")
                    continue
                }
                throw ProvisionError("\(dependency.name) installation failed: \(result.output.suffix(300))")
            }
        }
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
            // A standard (non-administrator) macOS account can be refused
            // here; the one honest exit is naming the command an admin can
            // run, in the wizard instead of a forum.
            throw ProvisionError(
                "Rosetta install failed: \(result.output.suffix(200)). "
                    + "If this account isn't an administrator, run "
                    + "\"softwareupdate --install-rosetta --agree-to-license\" "
                    + "in Terminal as one, then Try Again.",
            )
        }
        await refreshDetection()
    }

    /// The managed engine is downloaded from the manifest when nothing else
    /// can run Steam — or when the stored engine
    /// choice asks for it despite a usable CrossOver, which is how the
    /// Engine pane's "Built-in engine (downloads on switch)" option lands.
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
                    "engine install failed: \(result.output.suffix(200))",
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
            throw ProvisionError("no usable engine after install", leavesNothingToStart: true)
        }
    }

    /// Installs an engine already on disk — a release tarball or a tree built
    /// here — outside the provisioning sequence, which is Settings › Engine's
    /// route for adding a release by hand. Narrates through `activity` while
    /// it runs and rests at `.idle` after; the version installed comes back,
    /// and the caller decides whether to switch to it.
    func installEngine(from source: URL) async throws -> String {
        guard !isWorking else {
            throw ProvisionError("setup is already running")
        }
        beginStage(2, "Installing the game engine…")
        SetupLog.log("installing engine from \(source.path)")
        let result = await environment.installEngine(from: source, progress: engineProgress())
        stage = nil
        stageFraction = nil
        activity = .idle
        await refreshDetection()
        guard result.succeeded else {
            throw ProvisionError("engine install failed: \(result.output.suffix(200))")
        }
        return result.output
    }

    private var isWorking: Bool {
        if case .working = activity { true } else { false }
    }

    /// The engine stage's narration: each new phase is logged once and shown,
    /// the fraction rides along for the progress bar.
    private func engineProgress() -> @Sendable (String, Double?) -> Void {
        { [weak self] phase, fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self?.activity != .working(phase) {
                        SetupLog.log("engine install: \(phase)")
                        self?.activity = .working(phase)
                    }
                    self?.stageFraction = fraction
                }
            }
        }
    }

    private func createBottleIfMissing(_ bottleName: String) async throws {
        guard bottleRecord(named: bottleName) == nil else {
            return
        }
        beginStage(3, "Creating the Steam environment…")
        SetupLog.log("provision: creating bottle \(bottleName) (win10_64)")
        let create = await environment.createBottle(named: bottleName)
        guard create.succeeded else {
            throw ProvisionError(
                "bottle creation failed: \(create.output.suffix(200))",
                leavesNothingToStart: true,
            )
        }
        await refreshDetection()
    }

    private func installBootstrapper(
        inBottle bottleName: String, force: Bool,
    ) async throws {
        guard force || !steamPresent(inBottle: bottleName) else { return }

        beginStage(4, "Downloading the Steam installer…")
        SetupLog.log("provision: downloading SteamSetup.exe")
        try await environment.downloadSteamInstaller(intoBottle: bottleName)

        activity = .working("Installing Steam…")
        await environment.settleBottle(named: bottleName)
        SetupLog.log("provision: silent NSIS install")
        let install = await environment.runSteamInstaller(inBottle: bottleName)
        guard install.succeeded else {
            let status = install.status.map(String.init) ?? "no exit status"
            let output = install.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProvisionError(
                "Steam installer failed (exit \(status))"
                    + (output.isEmpty
                        ? " without printing anything"
                        : ": \(output.suffix(200))"),
                leavesNothingToStart: true,
            )
        }
    }

    /// Bootstrapper → full client, no login needed (the lancache-prefill
    /// trick). On a bottle whose client is unfinished this is the update pass
    /// — `-forcesteamupdate -forcepackagedownload` brings a client of any age
    /// up to current. A complete client is left to update itself: the
    /// updater would run inside the bottle of the client that is up, and
    /// that client's own updater owns the same files. `force` is the rebuild,
    /// which stops the client first.
    private func updateClient(inBottle bottleName: String, force: Bool) async throws {
        guard force || !clientFullyUpdated(inBottle: bottleName) else { return }
        beginStage(
            5,
            steamPresent(inBottle: bottleName)
                ? "Updating Steam…"
                : "Downloading Steam (this is the long step)…",
        )
        // The CDN's bootstrapper is old enough that its first update replaces
        // the updater itself, and the new updater then wants the separate
        // win64 client package. One pass leaves that package — hundreds of
        // megabytes behind an updater window — for the user's first launch
        // to download; looping until the win64 manifest lands absorbs it here,
        // where "Updating Steam…" is already on screen. Passes continue
        // while each one moves bytes into `package/`, because a small fixed
        // cap gives up mid-download on a slow switch.
        var lastPayload = packagePayloadBytes(inBottle: bottleName)
        for pass in 1 ... 6 {
            if pass > 1 {
                SetupLog.log("provision: updater replaced itself — update pass \(pass)")
                activity = .working("Updating Steam…")
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
                "client update finished but steamclient64.dll is missing",
                leavesNothingToStart: true,
            )
        }
        // The tree is there with packages staged: the client's own
        // bootstrapper applies them on its first launch, so an incomplete
        // headless pass is a note, never a wall.
        SetupLog.log("provision: update incomplete after the headless passes — "
            + "the client applies the staged packages at first launch")
    }

    private func steamExePath(inBottle name: String) -> String {
        let bottle = environment.bottlesRoot.appendingPathComponent(name)
        return SteamBottle.steamRoot(inBottle: bottle)
            .appendingPathComponent("Steam.exe").path
    }

    /// Bytes sitting in the client's `package/` staging directory — the
    /// updater's visible progress between self-replacements.
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

    /// Whether the bottle's client is current enough that a launch goes
    /// straight through: the win64 package manifest is what the self-updated
    /// updater installs last. A dry run has no bottle on disk to ask.
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

    /// Applies the idempotent bottle configuration every adoption gets —
    /// today the tray suppression; renderer/msync knobs land here too.
    ///
    /// Dormison's Mac driver reads `Mac Driver\StatusItems` and, off, hands
    /// Steam's tray icon to explorer.exe's own systray window, which the
    /// Explorer tray values keep hidden: no status item ever appears.
    /// CrossOver's driver makes one regardless, and
    /// `BottleSupervisor.suppressWineTray` removes it once the client is up.
    func configureBottle(named name: String) async {
        // Leaves `activity` alone: the wizard's Continue button gates on
        // `.done`, which this reassert must not overwrite.
        await environment.configureBottle(named: name)
    }

    /// The quit's half of setup: a stage still running has Wine processes in
    /// the bottle that nothing else owns, so they end with the app.
    func endForQuit() async {
        guard isWorking else { return }
        SetupLog.log("provision: quitting mid-setup — ending the bottle's processes")
        await environment.endWineProcesses(inBottle: environment.bottleName)
    }

    /// The wizard's whole sequence: install Steam, then apply the idempotent
    /// bottle configuration the boot path also reasserts.
    func provisionAndConfigure(rebuildingSteam: Bool = false) async {
        await provisionSteam(rebuildingSteam: rebuildingSteam)
        if case .done = activity {
            await configureBottle(named: environment.bottleName)
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
        bottleRecord(named: bottleName)?.hasSteam == true
    }

    private struct ProvisionError: Error, CustomStringConvertible {
        let description: String
        /// Whether the stage that threw leaves nothing to start: no engine,
        /// no bottle, no Steam in it. The client start is held until such a
        /// failure is retried or the user asks for it anyway.
        let leavesNothingToStart: Bool

        init(_ description: String, leavesNothingToStart: Bool = false) {
            self.description = description
            self.leavesNothingToStart = leavesNothingToStart
        }
    }
}
