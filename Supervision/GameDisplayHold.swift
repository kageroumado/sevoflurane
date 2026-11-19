import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while a game runs: a Wine game is not user
/// activity to macOS, and with the display asleep its Metal present blocks and
/// the game freezes. System sleep is left to the user's settings.
@MainActor
enum GameDisplayHold {
    private static var assertion: IOPMAssertionID = .init(kIOPMNullAssertionID)

    /// The program the hold was taken for, so a window mistaken for a game's
    /// is named in the log.
    private static var heldFor: String?

    /// A game's window is up. Idempotent; a hold already taken for another
    /// program is kept and names this one from now on.
    static func gameDidAppear(for program: String) {
        guard assertion == IOPMAssertionID(kIOPMNullAssertionID) else {
            if heldFor != program {
                heldFor = program
                EventLog.shared.log(.app, "display hold kept for \(program)")
            }
            return
        }
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

    /// No game remains; calling it again does nothing.
    static func gameDidExit() {
        guard assertion != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(assertion)
        assertion = IOPMAssertionID(kIOPMNullAssertionID)
        EventLog.shared.log(.app, "display hold released — \(heldFor ?? "the game") is gone")
        heldFor = nil
    }
}
