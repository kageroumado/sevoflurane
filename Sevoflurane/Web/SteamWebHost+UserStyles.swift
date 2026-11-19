import Foundation
import WebKit

extension SteamWebHost {
    /// The custom stylesheet for store and community pages, or `nil` while
    /// those pages keep Steam's own look.
    var webPageStylesheet: String? {
        Preferences.userStyles && Preferences.userStylesOnWebPages ? userStylesheet : nil
    }

    /// Puts the Styles folder's stylesheet on or off every open window (and
    /// store and community page, if chosen) to match Settings, watching the
    /// folder while the style is on.
    func applyUserStyles() {
        guard Preferences.userStyles else {
            userStylesWatch = nil
            userStylesheet = ""
            restyleWindows()
            return
        }
        if userStylesWatch == nil {
            try? UserStyles.prepareFolder()
            userStylesWatch = FolderWatch(folder: UserStyles.folder) { [weak self] in
                self?.reloadUserStyles()
            }
        }
        userStylesheet = UserStyles.stylesheet()
        restyleWindows()
    }

    /// Rereads the folder and restyles the windows when the stylesheet changed.
    private func reloadUserStyles() {
        let stylesheet = UserStyles.stylesheet()
        guard Preferences.userStyles, stylesheet != userStylesheet else { return }
        userStylesheet = stylesheet
        EventLog.shared.log(.page, "custom style reloaded (\(stylesheet.utf8.count) bytes)")
        restyleWindows()
    }

    private func restyleWindows() {
        let script = Preferences.userStyles
            ? SteamUserCSS.script(css: userStylesheet)
            : SteamUserCSS.removalScript
        let webPages = webPageStylesheet
        for window in popups.values {
            window.webView.evaluateJavaScript(script)
            window.styleWebPages(with: webPages)
        }
    }
}
