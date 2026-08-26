import Foundation

/// The script that turns Steam's Windows chrome into macOS chrome.
///
/// Steam's title strip is a normal part of the page, so the adjustments are
/// too: its window buttons are removed because the traffic lights already do
/// that job, and its menu strip is removed because the macOS menu bar drives
/// those menus through ``SteamMenuMirror``. Everything is anchored on
/// `.TitleBar.title-area`, the one semantic class in that corner of the DOM —
/// the rest of Steam's class names are content hashes that change with every
/// client build.
///
/// The script is idempotent and re-applies itself: Steam writes the popup's
/// document from the opener and keeps copying stylesheets into its head, so an
/// injection that assumed a stable head would be undone.
enum SteamDesktopChrome {
    static let script = """
    (function () {
      if (window.__sevoChrome) { window.__sevoChrome.apply(); return "reapplied"; }
    
      var STYLE_ID = "sevo-macos-chrome";
      /* Every selector is static — anchored on `.TitleBar.title-area`, the one
         semantic class, via `:has()` — so the rules bite from the moment the
         style element exists, before the title row's first paint. An earlier
         version tagged the row with a class from the MutationObserver first,
         and Steam's window controls stayed visible for the beat between paint
         and observer. */
      var CSS = [
        /* The macOS traffic lights are the window controls; Steam's are a
           second set for a window manager this app does not have. Hiding the
           container rather than .title-area itself also releases the ~99px it
           reserves at the row's right edge — the title-area is absolutely
           positioned, so hiding only it leaves the gap. */
        "div:has(> .TitleBar.title-area) { display: none !important; }",
        /* The title row's first cell is the menu strip, mirrored into the
           macOS menu bar, which drives the same menus; two strips would
           fight. */
        "div:has(> div > .TitleBar.title-area) > :first-child { display: none !important; }",
        /* The unified-compact titlebar is 40pt; Steam's 24pt buttons sit at
           y=7 in its 32pt strip. One extra point centers them against the
           traffic lights. The margin sits on the account cluster (the row's
           last visible cell) rather than as row padding: row padding either
           widens the row (content-box) or eats the top point (border-box).
           12px puts the last icon's visual gap to the window edge at the same
           ~20pt the cluster keeps between its own buttons. */
        "div:has(> div > .TitleBar.title-area) { padding-top: 1px !important; }",
        "div:has(> div > .TitleBar.title-area) > :nth-last-child(2) { margin-inline-end: 12px !important; }"
      ].join("\\n");
    
      function titleArea() { return document.querySelector(".TitleBar.title-area"); }
    
      function titleRow() {
        var area = titleArea();
        return area && area.parentElement && area.parentElement.parentElement;
      }
    
      function apply() {
        if (!document.head) return;
        var style = document.getElementById(STYLE_ID);
        if (!style) {
          style = document.createElement("style");
          style.id = STYLE_ID;
          style.textContent = CSS;
          document.head.appendChild(style);
        }
        reportDragRegions();
      }
    
      function rectOf(el) {
        var r = el.getBoundingClientRect();
        return [Math.round(r.left), Math.round(r.top),
                Math.round(r.width), Math.round(r.height)];
      }
    
      /* Steam marks its drag area with `-webkit-app-region: drag`, which WebKit
         neither acts on nor reports — getComputedStyle answers "" for the
         property, so there is nothing to read. What that rule is applied to is
         the strip's one empty stretch, the child with neither text nor
         children of its own, and the host drags the NSWindow by it. */
      function dragRegions() {
        var out = [];
        var row = titleRow();
        if (!row) return out;
        for (var i = 0; i < row.children.length; i++) {
          var child = row.children[i];
          if (!child.children.length && !child.textContent.trim()) {
            out.push(rectOf(child));
          }
        }
        return out;
      }
    
      var pending = 0;
      function reportDragRegions() {
        var handler = window.webkit && window.webkit.messageHandlers
          && window.webkit.messageHandlers.sevoWindow;
        if (!handler) return;
        handler.postMessage({ fn: "__dragRegions", args: [dragRegions()] });
      }
    
      function schedule() {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; apply(); }, 150);
      }
    
      /* Observed on the Document node, not documentElement: this script runs
         against the popup's initial about:blank, and Steam then document.open()s
         it — which replaces the whole element tree but keeps the Document (and
         this observer) alive. An observer on the old documentElement dies with
         it, and the strip then flashes until something else re-applies. Until
         the style is in the *current* head, apply immediately instead of
         debouncing, so the CSS lands before the strip's first paint. */
      new MutationObserver(function () {
        if (document.head && !document.getElementById(STYLE_ID)) apply();
        else schedule();
      }).observe(document, { childList: true, subtree: true });
      window.addEventListener("resize", schedule);
    
      window.__sevoChrome = { apply: apply };
      apply();
      return "installed";
    })()
    """

    /// The same treatment for popup windows (login, controller config,
    /// friends chat…), whose strip has a different shape: there
    /// `.TitleBar.title-area` is the entire title bar, and Steam's window
    /// buttons live in its `.title-bar-actions` cluster.
    static let popupScript = """
    (function () {
      if (window.__sevoChrome) { window.__sevoChrome.apply(); return "reapplied"; }

      var STYLE_ID = "sevo-macos-chrome";
      /* Steam's close/minimize cluster duplicates the traffic lights. Both
         class names are semantic and survive client builds. */
      var CSS = ".TitleBar.title-area .title-bar-actions { display: none !important; }";

      function apply() {
        if (!document.head) return;
        var style = document.getElementById(STYLE_ID);
        if (!style) {
          style = document.createElement("style");
          style.id = STYLE_ID;
          style.textContent = CSS;
          document.head.appendChild(style);
        }
        reportDragRegions();
      }

      function rectOf(el) {
        var r = el.getBoundingClientRect();
        return [Math.round(r.left), Math.round(r.top),
                Math.round(r.width), Math.round(r.height)];
      }

      /* The strip's empty stretch is the drag surface — on the login window
         that is `.title-area-children`, which spans the strip minus the
         controls and renders nothing. A popup that fills it (chat tabs)
         keeps its clicks. `.title-area-highlight` never qualifies: it is a
         full-width visual overlay, and reporting it would turn everything
         under it into a drag handle. */
      function dragRegions() {
        var out = [];
        var area = document.querySelector(".TitleBar.title-area");
        if (!area) return out;
        for (var i = 0; i < area.children.length; i++) {
          var child = area.children[i];
          if (child.classList.contains("title-area-highlight")) continue;
          if (!child.children.length && !child.textContent.trim()) {
            out.push(rectOf(child));
          }
        }
        return out;
      }

      var pending = 0;
      function reportDragRegions() {
        var handler = window.webkit && window.webkit.messageHandlers
          && window.webkit.messageHandlers.sevoWindow;
        if (!handler) return;
        handler.postMessage({ fn: "__dragRegions", args: [dragRegions()] });
      }

      function schedule() {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; apply(); }, 150);
      }

      new MutationObserver(function () {
        if (document.head && !document.getElementById(STYLE_ID)) apply();
        else schedule();
      }).observe(document, { childList: true, subtree: true });
      window.addEventListener("resize", schedule);

      window.__sevoChrome = { apply: apply };
      apply();
      return "installed";
    })()
    """
}
