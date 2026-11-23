import Foundation
import Observation
import os

/// The idempotent provisioning state machine behind the first-run assistant
/// and Settings › Recovery. Every stage is detect → perform → re-detect, so a
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

    typealias Stage = SetupStage

    private(set) var detection: SetupDetection?
    private(set) var activity: Activity = .idle
    /// The stage a pass is in, kept through a failure so the failed stage
    /// can be named; `nil` before a pass and after one that succeeded.
    private(set) var stage: Stage?
    /// Where each stage of the pass stands. A stage with no entry is pending.
    private(set) var stageStates: [Stage: SetupStageState] = [:]
    /// Progress within the current stage (the engine download), or `nil`
    /// where none is measurable.
    private(set) var stageFraction: Double?
    /// Bytes the current stage has received, where its total is unknown:
    /// Steam's own download.
    private(set) var stageBytes: Int64?
    /// Why the last pass stopped; `nil` once another starts.
    private(set) var failure: SetupFailure?
    /// How long the current stage's download still takes, in seconds: known
    /// only for a download whose total is known, once its rate has settled.
    private(set) var stageSecondsLeft: Int?
    /// When the current stage's download was first measured, and how far it
    /// was then.
    private var downloadOrigin: (at: ContinuousClock.Instant, fraction: Double)?
    /// An engine tarball the engine stage installs in place of a download.
    var engineTarball: URL?
    /// Whether this run installs the whole dependency catalog. `nil` reads
    /// the standing preference, ``BottleDependencies/installsEverything``,
    /// when the stage runs; a test or a fixture names its own.
    var installsEveryDependency: Bool?
    /// What the pass acts on, and what the assistant asks about the Mac.
    let environment: any SetupEnvironment

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

    // MARK: - What a pass reports

    /// The stages of the pass in order, each with its state. Closing Steam
    /// is listed only on a pass that had to.
    var reports: [SetupStageReport] {
        Stage.allCases.compactMap { stage in
            let state = stageStates[stage]
            if stage == .steamStop, state == nil { return nil }
            return SetupStageReport(stage: stage, state: activity == .done ? .done : state ?? .pending)
        }
    }

    /// How far the pass is, 0 to 1: the stages done, plus the known part of
    /// the one under way.
    var passFraction: Double {
        let reports = reports
        guard !reports.isEmpty else { return 0 }
        let done = reports.reduce(0.0) { sum, report in
            switch report.state {
            case .done: sum + 1
            case let .working(fraction): sum + (fraction ?? 0)
            case .pending, .failed: sum
            }
        }
        return done / Double(reports.count)
    }

    /// What the pass is doing, in its own words; `nil` while none runs.
    var phase: String? {
        if case let .working(phase) = activity { phase } else { nil }
    }

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
        // A pass under way owns the activity; the choice moves between passes.
        guard !isWorking else { return false }
        failure = nil
        stageStates = [:]
        if closesSteam(toChoose: name) {
            beginStage(.steamStop, String(localized: "Stopping Steam…"))
            SetupLog.log("provision: stopping the client before moving to bottle \(name)")
            if let refusal = await stopClient({ activity = .working(InterfaceCopy.localized($0)) }) {
                fail(SetupFailure(stage: .steamStop, cause: refusal, advice: nil), saying: refusal)
                SetupLog.log("provision: the bottle stays \(environment.bottleName) — \(refusal)")
                return false
            }
            stageStates[.steamStop] = .done
        }
        stage = nil
        activity = .idle
        environment.chooseBottle(named: name)
        return true
    }

    /// Whether moving to the bottle named `name` closes a Steam first. A
    /// simulated machine has one to close only when told so.
    func closesSteam(toChoose name: String) -> Bool {
        guard !environment.isSimulation else {
            return environment.simulatesRunningSteam && name != environment.bottleName
        }
        return Self.choosingStopsClient(
            chosen: prefixPath(of: name),
            configured: prefixPath(of: environment.bottleName),
            booted: BootedBottle.target?.prefix.standardizedFileURL.path,
        )
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
        failure = nil
        // Closing Steam, when this pass had to, happened before it began.
        stageStates = stageStates.filter { $0.key == .steamStop && $0.value == .done }
        do {
            try await run(.rosetta) { try await installRosettaIfMissing() }
            try await run(.engine) { try await installEngineIfMissing() }
            // The engine stage can move the bottles root; the lease follows.
            holdBottle()
            try await run(.bottle) { try await createBottleIfMissing(bottleName) }
            try await run(.installer) { try await installBootstrapper(inBottle: bottleName, force: rebuildingSteam) }
            try await run(.client) { try await updateClient(inBottle: bottleName, force: rebuildingSteam) }
            try await run(.dependencies) { try await installGameDependencies() }
            stage = nil
            activity = .done
            if !environment.isSimulation { BottleReadiness.recordProvisionSucceeded() }
            SetupLog.log("provision: Steam client present in bottle \(bottleName)")
        } catch {
            let provision = error as? ProvisionError
            let said = provision?.description ?? SetupFailureText.sentence(error)
            let advice = provision.map(\.advice) ?? SetupFailureText.advice(error)
            fail(
                SetupFailure(
                    stage: stage, cause: provision?.cause ?? said,
                    advice: provision.map { $0.pageAdvice ?? $0.advice } ?? advice,
                ),
                saying: [said, advice].compactMap(\.self).joined(separator: " "),
            )
            if !environment.isSimulation {
                BottleReadiness.recordProvisionFailed(
                    said,
                    blocksClientStart: provision?.leavesNothingToStart ?? false,
                )
            }
            SetupLog.log("provision failed: \(provision?.detail ?? "\(error)")")
        }
        stageFraction = nil
        stageBytes = nil
        stageSecondsLeft = nil
    }

    /// Runs one stage of the pass and marks it done; a stage that finds its
    /// product in place is done at once.
    private func run(_ stage: Stage, _ body: () async throws -> Void) async throws {
        self.stage = stage
        stageFraction = nil
        stageBytes = nil
        stageSecondsLeft = nil
        downloadOrigin = nil
        try await body()
        stageStates[stage] = .done
    }

    /// Ends the pass on `failure`, with `text` as what Settings shows.
    private func fail(_ failure: SetupFailure, saying text: String) {
        self.failure = failure
        if let stage = failure.stage { stageStates[stage] = .failed }
        activity = .failed(text)
    }

    /// Re-runs a failed pass from the stage that failed.
    func retry() async {
        guard case .failed = activity else { return }
        activity = .idle
        await refreshDetection()
        await provisionAndConfigure()
    }

    private func beginStage(_ stage: Stage, _ phase: String) {
        self.stage = stage
        stageFraction = nil
        stageBytes = nil
        stageStates[stage] = .working(fraction: nil)
        activity = .working(InterfaceCopy.localized(phase))
    }

    private func installGameDependencies() async throws {
        let all = installsEveryDependency ?? BottleDependencies.installsEverything
        for dependency in BottleDependencies.provisioned(all: all) {
            guard !environment.isDependencyInstalled(dependency) else { continue }
            beginStage(.dependencies, String(localized: "Installing \(dependency.name)…"))
            let result = await environment.installDependency(dependency)
            guard result.succeeded, environment.isDependencyInstalled(dependency) else {
                // Only a required entry ends setup; the rest can be
                // installed later from Settings › Engine.
                guard dependency.required else {
                    SetupLog.log("provision: \(dependency.name) did not install: "
                        + "\(result.output.suffix(200))")
                    continue
                }
                throw ProvisionError(
                    String(localized: "\(dependency.name) installation failed: \(result.output.suffix(300))"),
                    cause: String(localized: "\(dependency.name) did not install."),
                )
            }
        }
    }

    /// The whole stack is x86_64, so nothing runs without Rosetta.
    private func installRosettaIfMissing() async throws {
        guard detection?.rosetta == false else { return }
        beginStage(.rosetta, "Installing Rosetta…")
        SetupLog.log("provision: installing Rosetta")
        let result = await environment.installRosetta()
        guard result.succeeded else {
            // A standard (non-administrator) account can be refused here, so
            // the error names the command an administrator can run.
            throw ProvisionError(
                String(localized: "Rosetta install failed: \(result.output.suffix(200)). If this account isn't an administrator, run \"softwareupdate --install-rosetta --agree-to-license\" in Terminal as one, then Try Again."),
                cause: "",
                pageAdvice: String(localized: "An administrator of this Mac can install it. Then try again."),
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
            beginStage(.engine, "Installing the game engine…")
            SetupLog.log("provision: installing managed engine")
            let result = await environment.installEngine(from: engineTarball, progress: engineProgress())
            guard result.succeeded else {
                throw ProvisionError(
                    String(localized: "engine install failed: \(result.output)"),
                    cause: result.output,
                    advice: result.advice,
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
            throw ProvisionError(
                InterfaceCopy.localized("no usable engine after install"),
                cause: "",
                leavesNothingToStart: true,
            )
        }
    }

    /// Installs an engine tarball or tree from disk outside the provisioning
    /// sequence (Settings › Engine), answering the version installed; the
    /// caller decides whether to switch to it.
    func installEngine(from source: URL) async throws -> String {
        guard !isWorking else {
            let running = InterfaceCopy.localized("setup is already running")
            throw ProvisionError(running, cause: running)
        }
        beginStage(.engine, "Installing the game engine…")
        SetupLog.log("installing engine from \(source.path)")
        let result = await environment.installEngine(from: source, progress: engineProgress())
        stage = nil
        stageStates = [:]
        stageFraction = nil
        activity = .idle
        await refreshDetection()
        guard result.succeeded else {
            throw ProvisionError(
                String(localized: "engine install failed: \(result.output)"), cause: result.output, advice: result.advice,
            )
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
                    // A report that lands after its stage ended belongs to nothing.
                    guard let self, self.stage == .engine, self.isWorking else { return }
                    let localizedPhase = InterfaceCopy.localized(phase)
                    if self.activity != .working(localizedPhase) {
                        SetupLog.log("engine install: \(phase)")
                        self.activity = .working(localizedPhase)
                    }
                    self.stageFraction = fraction
                    self.stageStates[.engine] = .working(fraction: fraction)
                    self.estimateTimeLeft(at: fraction)
                }
            }
        }
    }

    /// How long a download must have run, and how far it must have moved,
    /// before its rate says anything.
    private static let settlingTime = Duration.seconds(8)
    private static let settlingProgress = 0.03

    /// Estimates the rest of a download from its rate since it was first
    /// measured. Nothing is said until the rate has settled.
    private func estimateTimeLeft(at fraction: Double?) {
        guard let fraction, fraction < 1 else {
            stageSecondsLeft = nil
            return
        }
        let now = ContinuousClock.now
        guard let origin = downloadOrigin else {
            downloadOrigin = (now, fraction)
            return
        }
        let elapsed = now - origin.at
        let moved = fraction - origin.fraction
        guard elapsed >= Self.settlingTime, moved >= Self.settlingProgress else { return }
        let seconds = Double(elapsed.components.seconds) * (1 - fraction) / moved
        let rounded = Int(seconds.rounded())
        if rounded != stageSecondsLeft { stageSecondsLeft = rounded }
    }

    #if DEBUG
        /// Gives the stage under way a time left, for the gallery: a
        /// simulated download has no rate.
        func stage(secondsLeft: Int) {
            stageSecondsLeft = secondsLeft
        }
    #endif

    private func createBottleIfMissing(_ bottleName: String) async throws {
        // A Steam-less bottle whose boot never finished, or that Steam's
        // installer failed in, is set aside and rebuilt: the installer would
        // fail the same way again.
        let rebuilding = bottleRecord(named: bottleName).map {
            !$0.hasSteam && (!environment.bottleIsComplete(named: bottleName)
                || environment.steamInstallerFailed(inBottle: bottleName))
        }
        if rebuilding == false { return }
        beginStage(.bottle, "Creating the Steam environment…")
        if rebuilding == true {
            do {
                let aside = try await environment.setAsideBottle(named: bottleName)
                SetupLog.log("provision: bottle \(bottleName) is unfinished or Steam's installer failed in it; set it aside as \(aside) to build it again")
            } catch {
                throw ProvisionError(
                    String(localized: "could not set aside an unfinished bottle: \(error.localizedDescription)"),
                    cause: SetupFailureText.sentence(error),
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
                cause: "",
                leavesNothingToStart: true,
            )
        }
        await refreshDetection()
        guard environment.bottleIsComplete(named: bottleName) else {
            SetupLog.log("provision: bottle \(bottleName) booted without its 32-bit system DLLs (syswow64)")
            throw ProvisionError(
                String(localized: "the new bottle has no 32-bit Windows files, so the engine may be damaged"),
                cause: String(localized: "It came out incomplete."),
                leavesNothingToStart: true,
            )
        }
    }

    private func installBootstrapper(
        inBottle bottleName: String, force: Bool,
    ) async throws {
        guard force || !steamPresent(inBottle: bottleName) else { return }

        beginStage(.installer, "Downloading the Steam installer…")
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
                cause: "",
                pageAdvice: String(localized: "Try Again runs it from the start."),
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
            .client,
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
            await updateWhileCountingBytes(inBottle: bottleName)
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
                cause: "",
                advice: SetupFailureText.networkAdvice,
                leavesNothingToStart: true,
            )
        }
        // The client applies staged packages at first launch, so an
        // incomplete headless pass is not a failure.
        SetupLog.log("provision: update incomplete after the headless passes — "
            + "the client applies the staged packages at first launch")
    }

    /// One headless update, with ``stageBytes`` following what lands in the
    /// client's staging folder: the updater reports nothing, and its total
    /// is Steam's to know.
    private func updateWhileCountingBytes(inBottle name: String) async {
        let counting = Task(name: "Count Steam's download") { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                let bytes = packagePayloadBytes(inBottle: name)
                if bytes > 0, bytes != stageBytes { stageBytes = bytes }
            }
        }
        await environment.updateSteamClient(inBottle: name)
        counting.cancel()
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
        // Never touches `activity`: the assistant moves on when a pass reads `.done`.
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
        /// What failed and why, as Settings says it and the log keeps it.
        let description: String
        /// The cause alone, for a page that names the failed stage itself.
        let cause: String
        /// What to do about it, on every surface.
        let advice: String?
        /// What to do about it on a first-run page, where `description`
        /// says the same to someone with a terminal.
        let pageAdvice: String?
        /// Whether the failed stage leaves no engine, bottle or Steam, which
        /// holds the client start until a retry or the user overrides it.
        let leavesNothingToStart: Bool

        var detail: String {
            description
        }

        init(
            _ description: String, cause: String, advice: String? = nil, pageAdvice: String? = nil,
            leavesNothingToStart: Bool = false,
        ) {
            self.description = description
            self.cause = cause
            self.advice = advice
            self.pageAdvice = pageAdvice
            self.leavesNothingToStart = leavesNothingToStart
        }
    }
}
