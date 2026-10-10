import Testing
@testable import Sevoflurane

/// The updater's veto: a swap restarts the app, and a quit takes Steam down with it.
struct SilentUpdatesTests {
    @Test
    func `an update installs only when no run, launch or game window is in play`() {
        #expect(SilentUpdates.mayInstall(recording: false, activeLaunch: false, gameWindow: false))
        #expect(!SilentUpdates.mayInstall(recording: true, activeLaunch: false, gameWindow: false))
        #expect(!SilentUpdates.mayInstall(recording: false, activeLaunch: true, gameWindow: false))
        #expect(!SilentUpdates.mayInstall(recording: false, activeLaunch: false, gameWindow: true))
        #expect(!SilentUpdates.mayInstall(recording: false, activeLaunch: false, gameWindow: false, settingUp: true))
    }
}
