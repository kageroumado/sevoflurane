import Foundation
import Testing
@testable import Sevoflurane

/// The onboarding flow, run end to end against the dry-run harness — the same
/// `Provisioner` policy the wizard drives, machine untouched.
@MainActor
struct OnboardingDryRunTests {
    private func makeProvisioner(
        _ scenario: SetupScenario,
    ) -> (Provisioner, DryRunSetupEnvironment) {
        let env = DryRunSetupEnvironment(scenario: scenario, stepDelay: .zero)
        return (Provisioner(environment: env), env)
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
    func `expired trial is not a usable engine`() async {
        let (provisioner, _) = makeProvisioner(.trialExpired)
        await provisioner.refreshDetection()
        #expect(provisioner.detection?.crossover != nil)
        #expect(provisioner.detection?.usableCrossOver == nil)
        #expect(provisioner.needsSetup)
    }
}
