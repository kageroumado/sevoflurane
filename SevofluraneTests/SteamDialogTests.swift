import Foundation
import Testing
@testable import Sevoflurane

/// Steam's generic modal dialog popups: how they classify and the window
/// policy that keeps them from dragging the library forward.
@MainActor
struct SteamDialogRoleTests {
    @Test
    func `PopupWindow popups classify as dialogs`() {
        // The "Shutting down Steam" notice, as Steam names it.
        #expect(SteamWindowRole(popupName: "PopupWindow_«rc»") == .dialog)
        #expect(SteamWindowRole(popupName: "PopupWindow_3_uid0") == .dialog)
    }

    @Test
    func `the dialog role's window policy`() {
        let role = SteamWindowRole.dialog
        // Never activates the app: the desktop must not become key on a quit.
        #expect(role.isPanel)
        // Steam draws its own frame.
        #expect(!role.hasPopupChrome)
        #expect(role.isShowable)
        // Genuinely on screen, so it may stop rendering when covered.
        #expect(role.allowsOcclusionDetection)
    }
}
