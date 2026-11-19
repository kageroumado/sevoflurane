import Foundation

/// The script that puts the user's own stylesheet (``UserStyles``) into a
/// Steam window, or a store or community page.
///
/// One `<style id="sevo-user-css">` kept as the head's last element, so the
/// user's rules win at equal specificity. Steam keeps adding stylesheets, so
/// an observer on the Document (which survives `document.open()`) moves it
/// back to the end. A second evaluation swaps the text in place.
nonisolated enum SteamUserCSS {
    static let styleID = "sevo-user-css"

    /// Installs `css`, or replaces the stylesheet an earlier evaluation
    /// installed.
    static func script(css: String) -> String {
        """
        (function () {
          var CSS = \(JSLiteral.inlineString(css));
          if (window.__sevoUserCSS) { window.__sevoUserCSS.set(CSS); return "updated"; }
        \(body)
        })()
        """
    }

    /// Takes the stylesheet off the page; the observer stays installed.
    static let removalScript = """
    (function () {
      if (!window.__sevoUserCSS) { return "not installed"; }
      window.__sevoUserCSS.set(null);
      return "removed";
    })()
    """

    /// The installer, run once per page with `CSS` in scope. `css` is
    /// `null` while the style is off.
    private static let body = """
      var STYLE_ID = "\(styleID)";
      var css = CSS;
    
      function apply() {
        var style = document.getElementById(STYLE_ID);
        if (css === null) { if (style) style.remove(); return; }
        var head = document.head;
        if (!head) return;
        if (!style) {
          style = document.createElement("style");
          style.id = STYLE_ID;
          style.textContent = css;
        }
        if (head.lastElementChild !== style) head.appendChild(style);
      }
    
      new MutationObserver(apply).observe(document, { childList: true, subtree: true });
    
      window.__sevoUserCSS = {
        set: function (next) {
          css = next;
          var style = document.getElementById(STYLE_ID);
          if (style && css !== null) style.textContent = css;
          apply();
        }
      };
      apply();
      return "installed";
    """
}
