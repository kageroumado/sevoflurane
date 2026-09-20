import Foundation
import Testing
@testable import Sevoflurane

/// The supervisor's health verdict, as a function of its inputs.
struct ClientSupervisorHealthTests {
    private typealias Inputs = ClientSupervisor.HealthInputs

    private func health(_ inputs: Inputs) -> ClientSupervisor.Health {
        ClientSupervisor.evaluateHealth(inputs)
    }

    @Test
    func `a healthy client needs both CDP and Steam's services`() {
        #expect(health(Inputs(lastProbe: .up, pageServicesUp: true, hasBeenHealthy: true))
            == .healthy)
        #expect(health(Inputs(lastProbe: .up, pageServicesUp: false, hasBeenHealthy: true))
            == .starting)
        #expect(health(Inputs(lastProbe: .down, pageServicesUp: true, hasBeenHealthy: true))
            == .starting)
    }

    @Test
    func `a session that has never seen a client is launching, not failing`() {
        let launching = health(Inputs(lastProbe: .down))
        #expect(launching == .launching("Steam is starting. A first launch takes a minute."))
    }

    @Test
    func `a pause outranks everything the client is doing`() {
        var inputs = Inputs(isPaused: true, lastProbe: .up, pageServicesUp: true)
        #expect(health(inputs) == .paused)
        inputs.isRestarting = true
        inputs.fault = .gaveUp("crash loop")
        inputs.isAwaitingSignIn = true
        #expect(health(inputs) == .paused)
    }

    @Test
    func `a crash loop stands until something clears it`() {
        var inputs = Inputs(hasBeenHealthy: true, fault: .gaveUp("client keeps dying"))
        #expect(health(inputs) == .gaveUp("client keeps dying"))
        // A restart in flight does not hide it; clearing the fault is what
        // ends it, which is why the ladder clears it by name.
        inputs.isRestarting = true
        inputs.restartPhase = "stopping the client"
        #expect(health(inputs) == .gaveUp("client keeps dying"))
        inputs.fault = nil
        #expect(health(inputs) == .restarting("stopping the client"))
    }

    @Test
    func `a signed-out client outranks progress and faults alike`() {
        var inputs = Inputs(lastProbe: .up, hasBeenHealthy: true, isAwaitingSignIn: true)
        #expect(health(inputs) == .waitingForSignIn)
        inputs.progressPhase = "waiting for Steam's services…"
        #expect(health(inputs) == .waitingForSignIn)
        inputs.fault = ClientSupervisor.Fault.degraded("page not answering (eval timeout)")
        #expect(health(inputs) == .waitingForSignIn)
        // A restart the user asked for still shows: the ladder is acting, and
        // the login window it is about to replace is not the state to report.
        inputs.isRestarting = true
        inputs.restartPhase = "stopping the client"
        #expect(health(inputs) == .restarting("stopping the client"))
    }

    @Test
    func `a progress phase reads as a first launch until a client has answered`() {
        var inputs = Inputs(progressPhase: "waiting for the client (12s)")
        #expect(health(inputs) == .launching("waiting for the client (12s)"))
        inputs.hasBeenHealthy = true
        #expect(health(inputs) == .restarting("waiting for the client (12s)"))
    }

    @Test
    func `progress outranks a fault, so a slow boot never reads as a failure`() {
        let inputs = Inputs(
            progressPhase: "waiting for Steam's services…",
            lastProbe: .up,
            hasBeenHealthy: true,
            fault: .degraded("CDP unreachable — client down"),
        )
        #expect(health(inputs) == .restarting("waiting for Steam's services…"))
    }

    @Test
    func `a page that has just been sent to a new client is starting`() {
        let inputs = Inputs(isPageBooting: true, lastProbe: .up, hasBeenHealthy: true)
        #expect(health(inputs) == .starting)
    }

    @Test
    func `a fault is reported once nothing else claims the cycle`() {
        let inputs = Inputs(
            lastProbe: .down,
            hasBeenHealthy: true,
            fault: .degraded("CDP unreachable — client down"),
        )
        #expect(health(inputs) == .degraded("CDP unreachable — client down"))
    }

    @Test
    func `every input left at rest derives a healthy-looking idle`() {
        // The default inputs are "nothing has happened yet": no client seen,
        // no probe answered. That must read as a launch, never as a fault.
        #expect(health(Inputs()) == .launching(
            "Steam is starting. A first launch takes a minute.",
        ))
    }

    @Test
    func `the ladder starting the first client reads as a launch, and as a restart once one has been up`() {
        var inputs = Inputs(isRestarting: true, restartPhase: "Starting Windows and Steam")
        #expect(health(inputs) == .launching("Starting Windows and Steam"))
        inputs.hasBeenHealthy = true
        #expect(health(inputs) == .restarting("Starting Windows and Steam"))
    }

    @Test
    func `a first launch stays a launch while the client answers and Steam's services are still coming up`() {
        let inputs = Inputs(progressPhase: "Waiting for Steam’s services… (14s)", lastProbe: .up)
        #expect(health(inputs) == .launching("Waiting for Steam’s services… (14s)"))
    }
}

/// A login window vetoes every path that would reload the page.
///
/// The veto has two sources, and both are pure: the page's own adopted popups
/// (``SteamWebHost/isAwaitingSignIn(popupRoles:)``), and the client's own
/// sign-in window as the boot's popup sweep names it
/// (``ClientLifecycle/isLoginWindow(_:)``). Between them they gate the boot's
/// page boot, the 90-second services grace, and the Dock-reopen rebuild —
/// each of which reloaded a page holding the login popup, which reaches Steam
/// as the user closing its sign-in window, and closing it quits.
@MainActor
struct SignInVetoTests {
    @Test
    func `an adopted login popup is the veto, whether or not it is on screen`() {
        #expect(SteamWebHost.isAwaitingSignIn(popupRoles: [.desktop, .login]))
        #expect(SteamWebHost.isAwaitingSignIn(popupRoles: [.login]))
        #expect(!SteamWebHost.isAwaitingSignIn(popupRoles: [.desktop, .chat, .menu]))
        #expect(!SteamWebHost.isAwaitingSignIn(popupRoles: []))
    }

    @Test
    func `the client's own sign-in window is recognized by name`() {
        #expect(ClientLifecycle.isLoginWindow("SP DesktopLoginWindow_uid0"))
        #expect(ClientLifecycle.isLoginWindow("desktoploginwindow"))
        #expect(!ClientLifecycle.isLoginWindow("notificationtoasts_1_desktop"))
        #expect(!ClientLifecycle.isLoginWindow("SP Desktop_uid0"))
        #expect(!ClientLifecycle.isLoginWindow(""))
    }

    @Test
    func `a vetoing sign-in state is what the health verdict reports`() {
        // The health the veto produces is the state every recovery timer
        // consults, so the two cannot drift apart.
        let inputs = ClientSupervisor.HealthInputs(
            isAwaitingSignIn: SteamWebHost.isAwaitingSignIn(popupRoles: [.login]),
        )
        #expect(ClientSupervisor.evaluateHealth(inputs) == .waitingForSignIn)
    }
}
