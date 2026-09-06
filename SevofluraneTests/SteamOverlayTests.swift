import Foundation
import Testing
@testable import Sevoflurane

/// The game overlay's classification: the popup names Steam gives it, and the
/// window policy that role carries.
@MainActor
struct GameOverlayRoleTests {
    @Test
    func `desktop and gamepad overlays classify as the game overlay`() {
        #expect(SteamWindowRole(popupName: "desktopoverlay_uid1688") == .gameOverlay)
        #expect(SteamWindowRole(popupName: "gamepadoverlay_uid42") == .gameOverlay)
        // The base name alone (no uid suffix) classifies too.
        #expect(SteamWindowRole(popupName: "desktopoverlay") == .gameOverlay)
    }

    @Test
    func `the overlay role's window policy`() {
        let role = SteamWindowRole.gameOverlay
        // Never promotes the app or takes key on Steam's behalf…
        #expect(role.isPanel)
        // …renders while covered (it sits over another app's window and would
        // otherwise read as occluded and stop)…
        #expect(!role.allowsOcclusionDetection)
        // …may be shown, and carries no chrome of its own.
        #expect(role.isShowable)
        #expect(!role.hasPopupChrome)
    }

    @Test
    func `the overlay names do not disturb the other roles`() {
        // Regression: adding the overlay prefixes left every prior mapping
        // intact.
        #expect(SteamWindowRole(popupName: "SP Desktop_uid1") == .desktop)
        #expect(SteamWindowRole(popupName: "SP BPM_uid1") == .bigPicture)
        #expect(SteamWindowRole(popupName: "contextmenu_3") == .menu)
        #expect(SteamWindowRole(popupName: "friendslist_uid9") == .friends)
        #expect(SteamWindowRole(popupName: "chat_1") == .chat)
        #expect(SteamWindowRole(popupName: "notificationtoasts_1_desktop") == .toast)
        #expect(SteamWindowRole(popupName: "something_unknown") == .auxiliary)
    }
}

/// When the overlay group is on screen. The rule is the whole of "travels with
/// the game and covers nothing else", so the cases that are hard to produce by
/// hand — a second app in front, a window that raised itself — are pinned here.
struct OverlayPresenceTests {
    private let game: pid_t = 100
    private let ours: pid_t = 200
    private let other: pid_t = 300

    @Test
    func `shown only while active and the game or this app is frontmost`() {
        // Active, and the frontmost app is the game or the overlay's own app.
        #expect(SteamWebHost.overlayShouldShow(active: true, front: game, gamePID: game, ourPID: ours))
        #expect(SteamWebHost.overlayShouldShow(active: true, front: ours, gamePID: game, ourPID: ours))
        // Active, but a third app is frontmost — the user switched away, or a
        // window grabbed focus itself: off screen, so it never covers that app.
        #expect(!SteamWebHost.overlayShouldShow(active: true, front: other, gamePID: game, ourPID: ours))
        // Active, but nothing is frontmost (no app reported).
        #expect(!SteamWebHost.overlayShouldShow(active: true, front: nil, gamePID: game, ourPID: ours))
        // Not active: never shown, whatever is in front.
        for front in [game, ours, other] {
            #expect(!SteamWebHost.overlayShouldShow(active: false, front: front, gamePID: game, ourPID: ours))
        }
    }

    @Test
    func `with no game window found, only this app in front keeps it up`() {
        // The game window could not be resolved (gamePID nil): the overlay
        // stays hidden unless its own app is frontmost, so it is never a
        // stuck window over the desktop.
        #expect(!SteamWebHost.overlayShouldShow(active: true, front: game, gamePID: nil, ourPID: ours))
        #expect(!SteamWebHost.overlayShouldShow(active: true, front: nil, gamePID: nil, ourPID: ours))
        #expect(SteamWebHost.overlayShouldShow(active: true, front: ours, gamePID: nil, ourPID: ours))
    }
}

/// Which on-screen window is a game's, by the resolved Windows program name.
struct GameProgramTests {
    @Test
    func `a game exe is one, the client's own infrastructure is not`() {
        #expect(WineWindowWatch.isGameProgram("subnautica2-win64-shipping.exe"))
        #expect(WineWindowWatch.isGameProgram("game.exe"))
        for infrastructure in [
            "steam.exe", "steamwebhelper.exe", "steamservice.exe",
            "explorer.exe", "conhost.exe", "gameoverlayui64.exe",
        ] {
            #expect(!WineWindowWatch.isGameProgram(infrastructure))
        }
        // Not an executable window at all.
        #expect(!WineWindowWatch.isGameProgram("steam_osx"))
        #expect(!WineWindowWatch.isGameProgram(""))
    }
}
