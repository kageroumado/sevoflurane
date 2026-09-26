import Foundation
import Testing
@testable import Sevoflurane

/// The onboarding flow, run end to end against the dry-run harness — the same
/// `Provisioner` policy the wizard drives, machine untouched.
@MainActor
struct OnboardingDryRunTests {
    /// `everything` is the "Download everything" switch, named here rather
    /// than read from the stored one so a test says what it is testing.
    private func makeProvisioner(
        _ scenario: SetupScenario, everything: Bool = false,
    ) -> (Provisioner, DryRunSetupEnvironment) {
        let env = DryRunSetupEnvironment(scenario: scenario, stepDelay: .zero)
        let provisioner = Provisioner(environment: env)
        provisioner.installsEveryDependency = everything
        return (provisioner, env)
    }

    @Test
    func `happy path provisions the simulated machine`() async {
        let (provisioner, env) = makeProvisioner(.licensedNoBottle)
        await provisioner.refreshDetection()
        #expect(provisioner.needsSetup)
        #expect(provisioner.isDryRun)
        await provisioner.provisionAndConfigure()
        #expect(provisioner.activity == .done)
        #expect(env.state.steamBottles.count == 1)
        #expect(!provisioner.needsSetup)
        #expect(env.installedDependencies == ["vcredist", "d3dcompiler"])
    }

    @Test
    func `download everything stocks the bottle with the whole catalog`() async {
        let (provisioner, env) = makeProvisioner(.licensedNoBottle, everything: true)
        await provisioner.refreshDetection()
        await provisioner.provisionAndConfigure()
        #expect(provisioner.activity == .done)
        #expect(env.installedDependencies == Set(BottleDependencies.catalog.map(\.id)))
    }

    @Test
    func `a font pack that will not install does not end the setup`() async {
        let (provisioner, env) = makeProvisioner(.licensedNoBottle, everything: true)
        env.failingDependencies = ["cjkfonts"]
        await provisioner.refreshDetection()
        await provisioner.provisionAndConfigure()
        // Steam and its games run without it, so the run finishes and the
        // package stays installable from Settings.
        #expect(provisioner.activity == .done)
        #expect(!env.installedDependencies.contains("cjkfonts"))
        #expect(env.installedDependencies.contains("vcredist"))
    }

    @Test
    func `provisioning preserves installed dependencies`() async {
        let (provisioner, env) = makeProvisioner(.provisioned)
        env.installedDependencies = ["vcredist", "d3dcompiler"]
        await provisioner.refreshDetection()
        await provisioner.provisionAndConfigure()
        #expect(provisioner.activity == .done)
        #expect(env.dependencyInstalls.isEmpty)
    }

    @Test
    func `shader compiler failure can resume without reinstalling completed runtimes`() async {
        let (provisioner, env) = makeProvisioner(.provisioned)
        env.installedDependencies = ["vcredist"]
        env.dependencyFailure = "download interrupted"
        await provisioner.refreshDetection()
        await provisioner.provisionAndConfigure()
        guard case let .failed(reason) = provisioner.activity else {
            Issue.record("expected a dependency failure, got \(provisioner.activity)")
            return
        }
        #expect(reason.contains("Direct3D shader compiler"))
        env.dependencyFailure = nil
        await provisioner.retry()
        #expect(provisioner.activity == .done)
        #expect(env.installedDependencies == ["vcredist", "d3dcompiler"])
        #expect(env.dependencyInstalls == ["d3dcompiler", "d3dcompiler"])
    }

    @Test
    func `missing rosetta is installed before the bottle`() async {
        let (provisioner, env) = makeProvisioner(.noRosetta)
        await provisioner.refreshDetection()
        await provisioner.provisionAndConfigure()
        #expect(env.state.rosetta)
        #expect(provisioner.activity == .done)
    }

    @Test
    func `existing bottle is adopted, not recreated`() async {
        let (provisioner, env) = makeProvisioner(.bottleWithoutSteam)
        await provisioner.refreshDetection()
        await provisioner.provisionAndConfigure()
        #expect(provisioner.activity == .done)
        #expect(env.state.bottles.count == 1)
        #expect(env.state.steamBottles.count == 1)
    }

    @Test
    func `installer failure surfaces as failed`() async {
        let (provisioner, env) = makeProvisioner(.installerFails)
        await provisioner.refreshDetection()
        await provisioner.provisionAndConfigure()
        guard case let .failed(reason) = provisioner.activity else {
            Issue.record("expected .failed, got \(provisioner.activity)")
            return
        }
        #expect(reason.contains("installer"))
        #expect(env.state.steamBottles.isEmpty)
    }

    @Test
    func `steam in a differently named bottle still needs setup`() async {
        let (provisioner, env) = makeProvisioner(.provisioned)
        env.renameSteamBottle(to: "SomeOtherBottle")
        await provisioner.refreshDetection()
        #expect(provisioner.needsSetup)
    }

    @Test
    func `provisioned machine needs no setup`() async {
        let (provisioner, _) = makeProvisioner(.provisioned)
        await provisioner.refreshDetection()
        #expect(!provisioner.needsSetup)
    }

    @Test
    func `fresh machine provisions through the built-in engine`() async {
        let (provisioner, env) = makeProvisioner(.freshMachine)
        await provisioner.refreshDetection()
        #expect(provisioner.detection?.usableCrossOver == nil)
        await provisioner.provisionAndConfigure()
        #expect(provisioner.activity == .done)
        #expect(env.state.managedEngineVersions == ["dry-run-engine"])
        #expect(env.state.steamBottles.count == 1)
    }

    @Test
    func `fresh machine blocks on the engine step until crossover appears`() async {
        let (provisioner, _) = makeProvisioner(.freshMachine)
        await provisioner.refreshDetection()
        #expect(provisioner.detection?.usableCrossOver == nil)
        // "Check again" a few times — the simulated user installs CrossOver.
        for _ in 0 ..< 4 {
            await provisioner.refreshDetection()
        }
        #expect(provisioner.detection?.usableCrossOver != nil)
    }

    @Test
    func `the fixture's bottle root is one no Mac has on disk`() async {
        // `appendingPathComponent` gives a directory URL a trailing slash only
        // where that directory already exists, so an absent root is the state
        // every Mac is in before its first bottle — and the state the GitHub
        // runner is always in.
        #expect(!FileManager.default.fileExists(atPath: SetupScenario.bottlesRoot.path))
        let (provisioner, _) = makeProvisioner(.provisioned)
        await provisioner.refreshDetection()
        #expect(!provisioner.needsSetup)
    }

    @Test
    func `choosing a bottle in a dry run stays inside the fixture`() async {
        let stored = SteamBottle.name
        let (provisioner, env) = makeProvisioner(.multipleBottles)
        var stops = 0
        await provisioner.chooseBottle(named: "Steam Beta") { _ in
            stops += 1
            return nil
        }
        await provisioner.refreshDetection()
        #expect(stops == 0)
        #expect(env.bottleName == "Steam Beta")
        #expect(!provisioner.needsSetup)
        #expect(SteamBottle.name == stored)
    }

    @Test
    func `another engine's bottle of the same name is no candidate`() async {
        let (provisioner, _) = makeProvisioner(.multipleBottles)
        await provisioner.refreshDetection()
        #expect(provisioner.detection?.bottles.count { $0.name == "Steam" } == 2)
        #expect(provisioner.ownBottles.count { $0.name == "Steam" } == 1)
        #expect(provisioner.ownBottles.map(\.name) == ["Steam", "Steam Beta", "Games", "Office"])
    }

    @Test
    func `expired trial is not a usable engine`() async {
        let (provisioner, _) = makeProvisioner(.trialExpired)
        await provisioner.refreshDetection()
        #expect(provisioner.detection?.crossover != nil)
        #expect(provisioner.detection?.usableCrossOver == nil)
        #expect(provisioner.needsSetup)
    }
}
