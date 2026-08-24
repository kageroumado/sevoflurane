import AppKit
import WebKit

// MARK: - React hover relay

extension SteamWindow {
    /// Runs Steam's own `onMouseEnter`/`onMouseLeave` handlers for the
    /// element path under the cursor.
    ///
    /// In a key window React's hover works off WKWebView's own tracking, but
    /// a menu panel is never key — and there, no deliverable mouse event runs
    /// a React enter/leave handler: forwarded native events and script
    /// dispatches both reach the document and its React root listener with
    /// no handler firing (clicks work; hover does not — measured). The
    /// handlers are still right there on each node's `__reactProps$…`, so
    /// the native tracking calls them directly: diff the ancestor path under
    /// the cursor against the last one, leave the departed nodes, enter the
    /// new ones. This is what keeps a hover menu open (the menu root's enter
    /// handler arms Steam's keep-alive flag) and what highlights its rows.
    func relayReactHover(contentPoint: NSPoint, contentHeight: CGFloat) {
        let x = Int(contentPoint.x)
        let y = Int(contentHeight - contentPoint.y)
        webView.evaluateJavaScript("""
        (function (x, y) {
          var el = document.elementFromPoint(x, y) || document.documentElement;
          var path = [];
          for (var n = el; n; n = n.parentElement) path.push(n);
          var prev = window.__sevoHoverPath || [];
          function props(n) {
            var k = Object.keys(n).find(function (k) { return k.indexOf("__reactProps$") === 0; });
            return k ? n[k] : null;
          }
          function ev(n, type) {
            return { target: el, currentTarget: n, clientX: x, clientY: y,
                     relatedTarget: null, bubbles: true, type: type, buttons: 0,
                     preventDefault: function () {}, stopPropagation: function () {},
                     nativeEvent: { clientX: x, clientY: y } };
          }
          prev.forEach(function (n) {
            if (path.indexOf(n) >= 0) return;
            var p = props(n);
            if (p && p.onMouseLeave) try { p.onMouseLeave(ev(n, "mouseleave")); } catch (e) {}
          });
          for (var i = path.length - 1; i >= 0; i--) {
            var n = path[i];
            if (prev.indexOf(n) >= 0) continue;
            var p = props(n);
            if (p && p.onMouseEnter) try { p.onMouseEnter(ev(n, "mouseenter")); } catch (e) {}
          }
          window.__sevoHoverPath = path;
          return "";
        })(\(x), \(y))
        """)
    }

    /// The cursor left the window: run the leave handlers for everything
    /// still marked hovered, so Steam's dismiss logic arms.
    func relayReactHoverExit() {
        webView.evaluateJavaScript("""
        (function () {
          var prev = window.__sevoHoverPath || [];
          window.__sevoHoverPath = [];
          prev.forEach(function (n) {
            var k = Object.keys(n).find(function (k) { return k.indexOf("__reactProps$") === 0; });
            var p = k ? n[k] : null;
            if (p && p.onMouseLeave) {
              try {
                p.onMouseLeave({ target: n, currentTarget: n, relatedTarget: null,
                                 bubbles: true, type: "mouseleave",
                                 preventDefault: function () {}, stopPropagation: function () {},
                                 nativeEvent: {} });
              } catch (e) {}
            }
          });
          return "";
        })()
        """)
    }
}
