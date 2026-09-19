import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while a game is running.
///
/// A Wine game never counts as user activity to macOS, so the display sleeps
/// on the idle timer even while the game renders. When it does, the game's
/// Metal present has nowhere to go and the render thread blocks on it: the
/// game freezes on whatever frame it had, its log stops, and it stays that
/// way until the panel comes back. Measured with Subnautica 2 on D3DMetal —
/// ten minutes frozen with the display off, every shader thread parked.
///
/// The hold is a power-management assertion against display sleep, taken
/// when a game's window appears and released when the last one is gone or
/// the app quits. System sleep is left to the user's settings.
@MainActor
enum GameDisplayHold {
    private static var assertion: IOPMAssertionID = .init(kIOPMNullAssertionID)

    /// The program whose window the hold was taken for. A window a probe
    /// mistakes for a game's is otherwise indistinguishable in the log from a
    /// game that really started, and the hold that follows is the symptom.
    private static var heldFor: String?

    /// A game's window is up. Idempotent.
    static func gameDidAppear(for program: String) {
        guard assertion == IOPMAssertionID(kIOPMNullAssertionID) else { return }
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sevoflurane: a game is running" as CFString,
            &id,
        )
        guard status == kIOReturnSuccess else {
            EventLog.shared.log(.app, "display hold refused: IOReturn \(status)")
            return
        }
        assertion = id
        heldFor = program
        EventLog.shared.log(.app, "display held awake for \(program)")
    }

    /// No game window remains.
    static func gameDidExit() {
        guard assertion != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(assertion)
        assertion = IOPMAssertionID(kIOPMNullAssertionID)
        EventLog.shared.log(.app, "display hold released — \(heldFor ?? "the game") is gone")
        heldFor = nil
    }
}
