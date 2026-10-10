import Foundation

/// The choice between a game's macOS and Windows builds, in Steam's own UI
/// (``SteamPlayMacOS``).
///
/// Three places, each drawn in Steam's own controls:
/// - **Install**: for a game with a macOS build that runs here, the game
///   page's Install button opens a menu with both versions, each with its
///   download size and a line from the compatibility verdicts. The choice is
///   mapped with `SpecifyCompatTool`, then Steam's own install wizard opens.
/// - **The play bar**: an installed game gets a "Version" entry beside Cloud
///   Status, in the same shape. It switches builds, saying first what Steam
///   will download.
/// - **Properties › Compatibility**: Steam's own page, the one a Linux user
///   expects, with its "Force the use of a specific Steam Play compatibility
///   tool" switch. Steam lists it only on Linux; ``contextScript`` lists it for
///   games with a macOS build and leaves every other Linux check as it is.
///
/// Every game stays in one library, and the Windows build stays one click
/// away, because some Mac ports run worse than their Windows build here.
/// Install from anywhere else (the library's context menu, a `steam://` link)
/// follows the game's current mapping, as it does on Linux.
enum SteamNativeBuilds {
    /// What ``contextScript`` answers once it has run, the outcomes an
    /// installer stops retrying on.
    static let settled: Set<String> = ["installed", "reapplied", "removed", "not installed", "unavailable"]

    /// Simple platform marks, drawn in `currentColor`: the Apple logo for the
    /// macOS build, the Windows logo for the Windows one. Shared with the
    /// library's badges (``SteamLibraryCompat``).
    static let platformGlyphs = """
      var PLATFORM_PATHS = {
        macos: "M14.6 10.7c0-1.9 1.6-2.8 1.6-2.9-.9-1.3-2.3-1.5-2.8-1.5-1.2-.1-2.3.7-2.9.7-.6 0-1.5-.7-2.5-.7-1.3 0-2.5.8-3.1 1.9-1.4 2.3-.4 5.7.9 7.6.6.9 1.4 2 2.4 1.9.9 0 1.3-.6 2.5-.6s1.5.6 2.5.6c1 0 1.7-.9 2.3-1.9.7-1.1 1-2.1 1-2.2 0 0-1.9-.7-1.9-2.9zM12.7 5c.5-.6.9-1.5.8-2.4-.8 0-1.7.5-2.3 1.1-.5.6-.9 1.5-.8 2.3.9.1 1.8-.4 2.3-1z",
        windows: "M2 3.6l6.6-.9v6.4H2zm7.4-1l8.6-1.2v7.7H9.4zM2 9.9h6.6v6.4L2 15.4zm7.4 0H18v7.7l-8.6-1.2z"
      };
    
      function platformGlyph(platform) {
        return '<span class="sevo-platform sevo-platform-' + platform + '"><svg viewBox="0 0 20 20" xmlns="http://www.w3.org/2000/svg"><path d="' + PLATFORM_PATHS[platform] + '" fill="currentColor"></path></svg></span>';
      }
    
    """

    // MARK: - The context page

    /// The context page's half: Steam's Properties › Compatibility page for
    /// games with a macOS build.
    ///
    /// The page list is built in one component (`dt` in this build), which
    /// adds the Compatibility page when the platform module's Linux test
    /// (`function C(){return"linux"==a.TS.PLATFORM}`) passes. The module's
    /// exports are fixed getters, so the test itself cannot be replaced;
    /// `TS.PLATFORM` is a plain property of the shared config object, and it
    /// becomes a getter that answers `linux` to that one test called from
    /// that one component, and the real platform to every other reader. The
    /// caller is read off the stack: JavaScriptCore names each frame after its
    /// function. Both names are found in the modules' own source at install
    /// time, so a new Steam build that renames them still matches, and one
    /// that changes the shape leaves every reader with the real platform.
    ///
    /// The page appears only for a game with a macOS build: Steam's details
    /// store is the one the component reads its game through, so the last
    /// game asked of it during that render is the game the list is for.
    static let contextScript = """
    (function () {
      var lib = window.__sevoNativeBuilds;
      if (lib) { lib.enabled = true; return "reapplied"; }
      if (!window.webpackChunksteamui || !window.appDetailsStore) return "waiting";
      var req = null;
      try { webpackChunksteamui.push([["sevo-native-" + Date.now()], {}, function (r) { req = r; }]); } catch (e) {}
      if (!req || !req.m) return "waiting";
    
      var gate = null, gateExport = null, platformModule = null, pages = [];
      for (var id in req.m) {
        var source = String(req.m[id]);
        if (!gate && source.length < 20000) {
          var test = source.match(/function (\\w+)\\(\\)\\{return"linux"==\\w+\\.TS\\.PLATFORM\\}/);
          if (test) {
            var exported = source.match(new RegExp("(\\\\w+):\\\\(\\\\)=>" + test[1] + "\\\\b"));
            if (exported) { gate = test[1]; gateExport = exported[1]; platformModule = id; }
          }
        }
        if (source.indexOf('"#AppProperties_CompatibilityPage"') !== -1) pages.push(source);
      }
      if (!gate) return "unavailable";
    
      /* The component that lists the page: the function around the gated
         push of the Compatibility page. */
      var names = [];
      var site = new RegExp("\\\\(0,\\\\w+\\\\." + gateExport + "\\\\)\\\\(\\\\)&&\\\\w+\\\\.push\\\\(\\\\{title:\\\\(0,\\\\w+\\\\.\\\\w+\\\\)\\\\(\\"#AppProperties_CompatibilityPage\\"\\\\)", "g");
      pages.forEach(function (source) {
        var hit;
        while ((hit = site.exec(source))) {
          var start = source.lastIndexOf("function ", hit.index);
          var name = start === -1 ? null : (source.slice(start, start + 64).match(/^function (\\w+)\\(/) || [])[1];
          if (name && names.indexOf(name) === -1) names.push(name);
        }
      });
      if (!names.length) return "unavailable";
    
      var ts = null;
      try { ts = req(platformModule).TS; } catch (e) {}
      var descriptor = ts && Object.getOwnPropertyDescriptor(ts, "PLATFORM");
      if (!descriptor || !descriptor.configurable || !("value" in descriptor)) return "unavailable";
    
      var store = window.appDetailsStore;
      var details = store.GetAppDetails;
      var lastAsked = 0;
      store.GetAppDetails = function (appid) {
        lastAsked = appid;
        return details.apply(this, arguments);
      };
    
      function lastAskedHasMacBuild() {
        try {
          var d = lastAsked && details.call(store, lastAsked);
          return !!(d && d.vecPlatforms && d.vecPlatforms.indexOf("osx") !== -1);
        } catch (e) { return false; }
      }
    
      /* frames[0] is this function, [1] the getter, [2] the Linux test,
         [3] its caller. Asked last: a stack trace on every read of PLATFORM costs more
         than the app-details lookup that rules out most games. */
      function askedByThePageList() {
        var frames = String(new Error().stack || "").split("\\n");
        if (frames.length < 4 || frames[2].indexOf(gate + "@") !== 0) return false;
        for (var i = 0; i < names.length; i++) {
          if (frames[3].indexOf(names[i] + "@") === 0) return true;
        }
        return false;
      }
    
      var real = descriptor.value;
      Object.defineProperty(ts, "PLATFORM", {
        configurable: true,
        enumerable: descriptor.enumerable,
        get: function () {
          if (lib.enabled && real !== "linux" && lastAskedHasMacBuild() && askedByThePageList()) return "linux";
          return real;
        },
        set: function (value) { real = value; }
      });
    
      lib = window.__sevoNativeBuilds = { enabled: true, pages: names };
      return "installed";
    })()
    """

    /// Stands the context half down: the Compatibility page is listed by
    /// Steam's own rule again, and the play bar's half stops drawing.
    static let contextRemovalScript = """
    (function () {
      if (!window.__sevoNativeBuilds) return "not installed";
      window.__sevoNativeBuilds.enabled = false;
      return "removed";
    })()
    """

    // MARK: - The desktop window

    /// The desktop window's half: the install menu and the play bar's Version
    /// entry. Idempotent and self-reapplying, like ``SteamCompatBadge``.
    static let script = "(function () {\n" + platformGlyphs + desktop + "\n})()"

    private static let desktop = """
      if (window.__sevoNativeMenu) {
        window.__sevoNativeMenu.enabled = true;
        window.__sevoNativeMenu.apply();
        return "reapplied";
      }
    
      var ctx = window.opener || window;
      var STYLE_ID = "sevo-native-style";
      var MENU_ID = "sevo-native-menu";
      var STAT_CLASS = "sevo-native-stat";
      var ANSWER_LIFE = 20000;
    
      /* Steam's context menu, values from its stylesheet: #3d4450, 13px
         items padded 8px 18px, the desktop hover inverting to light. The
         play bar entry borrows Steam's own GameStat classes. */
      var CSS = [
        ".sevo-platform{display:inline-flex;flex:none}",
        ".sevo-platform>svg{width:16px;height:16px}",
        "#sevo-native-menu{position:fixed;z-index:10000;min-width:300px;max-width:380px;background:#3d4450;color:#dcdedf;box-shadow:0 0 12px rgba(0,0,0,.6);font-size:13px;line-height:17px;user-select:none}",
        "#sevo-native-menu .sevo-native-head{padding:10px 18px 6px;font-size:10px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:#8b929a}",
        "#sevo-native-menu .sevo-native-item{position:relative;display:flex;align-items:center;gap:12px;padding:8px 18px;cursor:pointer}",
        "#sevo-native-menu .sevo-native-item:hover,#sevo-native-menu .sevo-native-item:focus{background:#dcdedf;color:#3d4450;outline:none}",
        "#sevo-native-menu .sevo-native-item:hover .sevo-native-hint,#sevo-native-menu .sevo-native-item:focus .sevo-native-hint,#sevo-native-menu .sevo-native-item:hover .sevo-native-size,#sevo-native-menu .sevo-native-item:focus .sevo-native-size{color:#3d4450}",
        "#sevo-native-menu .sevo-native-current::before{content:'';position:absolute;left:0;top:8px;bottom:8px;width:4px;background:#6dcff6}",
        "#sevo-native-menu .sevo-platform>svg{width:20px;height:20px}",
        "#sevo-native-menu .sevo-native-text{display:flex;flex-direction:column;flex:1;min-width:0}",
        "#sevo-native-menu .sevo-native-name{font-size:14px;color:inherit}",
        "#sevo-native-menu .sevo-native-hint{font-size:12px;color:#8b929a}",
        "#sevo-native-menu .sevo-native-tag{margin-inline-start:6px;padding:0 5px;border-radius:2px;background:#1a9fff;color:#fff;font-size:10px;font-weight:700;text-transform:uppercase;vertical-align:1px}",
        "#sevo-native-menu .sevo-native-size{font-size:12px;color:#8b929a;white-space:nowrap}",
        "#sevo-native-menu .sevo-native-foot{padding:6px 18px 10px;font-size:11px;color:#8b929a;border-top:1px solid #4c5564;margin-top:4px}",
        "#sevo-native-menu .sevo-native-confirm{padding:14px 18px;display:flex;flex-direction:column;gap:8px}",
        "#sevo-native-menu .sevo-native-title{font-size:15px;color:#fff}",
        "#sevo-native-menu .sevo-native-body{font-size:13px;color:#b8bcbf}",
        "#sevo-native-menu .sevo-native-buttons{display:flex;gap:8px;margin-top:6px}",
        "#sevo-native-menu .sevo-native-buttons .DialogButton{flex:1;min-width:0}",
        ".sevo-native-stat .sevo-platform>svg{width:18px;height:18px;color:#8b929a}"
      ].join("\\n");
    
      var NAMES = { macos: "macOS version", windows: "Windows version" };
      var SHORT = { macos: "macOS", windows: "Windows" };
      var answers = {};
      var classes = null;
      var menu = null;
    
      function esc(text) {
        return String(text == null ? "" : text)
          .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
      }
    
      /* The play bar's class modules, found by their semantic keys like the
         compat strip's. */
      function resolve() {
        if (classes) return classes;
        var chunk = ctx.webpackChunksteamui;
        if (!chunk || typeof chunk.push !== "function") return null;
        var req = null;
        try { chunk.push([["sevo-native-" + Date.now()], {}, function (r) { req = r; }]); } catch (e) { return null; }
        if (!req || !req.m) return null;
        var found = {};
        for (var id in req.m) {
          var source = String(req.m[id]);
          if (source.length > 20000) continue;
          try {
            if (!found.play && source.indexOf('PlayButtonContainer:"') !== -1 && source.indexOf('StreamingSelector:"') !== -1) found.play = req(id);
            if (!found.bar && source.indexOf('ActionSection:"') !== -1 && source.indexOf('GameStatsSection:"') !== -1) found.bar = req(id);
            if (!found.button && source.indexOf('AppDetailsButton:"') !== -1) found.button = req(id);
          } catch (e) {}
        }
        if (!found.play || !found.bar || !found.play.PlayButton || !found.bar.GameStatsSection) return null;
        classes = found;
        return classes;
      }
    
      function currentAppID() {
        try {
          var manager = ctx.MainWindowBrowserManager;
          var path = manager && manager.m_lastLocation && manager.m_lastLocation.pathname;
          var match = path && path.match(/^\\/library\\/app\\/(\\d+)/);
          return match ? Number(match[1]) : null;
        } catch (e) { return null; }
      }
    
      function overview(appid) {
        try { return ctx.appStore.GetAppOverviewByAppID(appid) || null; } catch (e) { return null; }
      }
    
      function details(appid) {
        try { return ctx.appDetailsStore.GetAppDetails(appid) || null; } catch (e) { return null; }
      }
    
      function steamPlayOn() {
        try { return !!ctx.settingsStore.settings.bCompatEnabled; } catch (e) { return false; }
      }
    
      /* The bridge's answer for the game, asked once and kept a short while:
         sizes and the installed build change only through Steam. */
      function answer(appid) {
        var entry = answers[appid];
        if (entry && (entry.pending || Date.now() - entry.at < ANSWER_LIFE)) return entry.value;
        var o = overview(appid);
        var asked = fetch("/__native/" + appid + "?name=" + encodeURIComponent((o && o.display_name) || ""), { cache: "no-store" })
          .then(function (response) { return response.ok ? response.json() : null; })
          .catch(function () { return null; })
          .then(function (value) { answers[appid] = { at: Date.now(), value: value }; schedule(); return value; });
        answers[appid] = { pending: true, at: Date.now(), value: entry ? entry.value : null, asked: asked };
        return entry ? entry.value : null;
      }
    
      /* The answer still on its way, for an Install pressed before it came. */
      function answerOnItsWay(appid) {
        answer(appid);
        var entry = answers[appid];
        return entry && entry.pending ? entry.asked : null;
      }
    
      /* Whether the game gets the choice at all: the engine runs macOS
         builds, Steam Play is on in the client, and the game has a macOS
         build this Mac can run. Anything else keeps Steam's own behavior. */
      function offered(appid) {
        var o = overview(appid);
        if (!o || o.app_type !== 1 || (o.BIsModOrShortcut && o.BIsModOrShortcut())) return null;
        var info = answer(appid);
        if (!active() || !info || !info.enabled || !info.hasMacBuild || !info.runnable) return null;
        if (!ctx.__sevoNativeBuilds || !ctx.__sevoNativeBuilds.enabled || !steamPlayOn()) return null;
        var d = details(appid);
        if (d && d.vecPlatforms && d.vecPlatforms.indexOf("osx") === -1) return null;
        return info;
      }
    
      /* The build the game is set to: Steam's own mapping. */
      function chosen(appid, info) {
        var d = details(appid);
        return d && d.strCompatToolName === info.tool ? "macos" : "windows";
      }
    
      function size(bytes) {
        if (typeof bytes !== "number" || !(bytes > 0)) return "";
        if (bytes >= 1e9) return (bytes / 1e9).toFixed(1) + " GB";
        return Math.max(1, Math.round(bytes / 1e6)) + " MB";
      }
    
      function download(info, platform) {
        return platform === "macos" ? info.macDownload : info.windowsDownload;
      }
    
      // MARK: The menu
    
      function item(platform, info, current, mode) {
        var hint = platform === "macos" ? info.macHint : info.windowsHint;
        var tag = "";
        if (mode === "switch" && platform === current) tag = '<span class="sevo-native-tag">Installed</span>';
        else if (platform === info.recommended) tag = '<span class="sevo-native-tag">Recommended</span>';
        var amount = size(download(info, platform));
        /* A switch names what it downloads; the build already on disk needs no size. */
        var right = mode !== "switch" ? amount
          : platform === current ? ""
          : info.sameFiles ? "No download" : amount;
        return '<div class="sevo-native-item' + (platform === current ? " sevo-native-current" : "") + '" role="menuitemradio" tabindex="0"'
          + ' aria-checked="' + (platform === current) + '" data-platform="' + platform + '">'
          + platformGlyph(platform)
          + '<span class="sevo-native-text"><span class="sevo-native-name">' + NAMES[platform] + tag + "</span>"
          + '<span class="sevo-native-hint">' + esc(hint) + "</span></span>"
          + '<span class="sevo-native-size">' + esc(right) + "</span></div>";
      }
    
      function menuHTML(appid, info, mode) {
        var current = chosen(appid, info);
        return '<div class="sevo-native-head">' + (mode === "install" ? "Install which version?" : "Version") + "</div>"
          + item("macos", info, current, mode)
          + item("windows", info, current, mode)
          + '<div class="sevo-native-foot">You can switch any time from the play bar or Properties › Compatibility.</div>';
      }
    
      function confirmHTML(target, info) {
        var other = target === "macos" ? "windows" : "macos";
        var amount = size(download(info, target));
        var body = "Steam downloads the " + NAMES[target] + (amount ? " (about " + amount + ")" : "")
          + " in place of the " + NAMES[other] + ".";
        return '<div class="sevo-native-confirm">'
          + '<div class="sevo-native-title">Switch to the ' + NAMES[target] + "?</div>"
          + '<div class="sevo-native-body">' + esc(body) + "</div>"
          + '<div class="sevo-native-buttons">'
          + '<button type="button" class="DialogButton _DialogLayout Primary sevo-native-go" data-platform="' + target + '">Switch</button>'
          + '<button type="button" class="DialogButton _DialogLayout Secondary sevo-native-cancel">Cancel</button>'
          + "</div></div>";
      }
    
      function openMenu(anchor, appid, info, mode) {
        closeMenu();
        var element = document.createElement("div");
        element.id = MENU_ID;
        element.setAttribute("role", "menu");
        element.innerHTML = menuHTML(appid, info, mode);
        document.body.appendChild(element);
        menu = { element: element, appid: appid, mode: mode, anchor: anchor };
        place();
        var first = element.querySelector(".sevo-native-item");
        if (first) first.focus();
      }
    
      /* Under the anchor, kept inside the window. */
      function place() {
        if (!menu) return;
        var rect = menu.anchor.getBoundingClientRect();
        var width = menu.element.offsetWidth;
        var height = menu.element.offsetHeight;
        var left = Math.max(8, Math.min(rect.left, window.innerWidth - width - 8));
        var top = rect.bottom + 4;
        if (top + height > window.innerHeight - 8) top = Math.max(8, rect.top - height - 4);
        menu.element.style.left = left + "px";
        menu.element.style.top = top + "px";
      }
    
      function closeMenu() {
        if (menu && menu.element.isConnected) menu.element.remove();
        menu = null;
      }
    
      /* Maps the game, then carries on: the install wizard for Install,
         nothing more for a switch, which Steam answers by downloading the
         other build's depots. */
      function choose(appid, platform, mode) {
        var info = answer(appid);
        var steam = ctx.SteamClient;
        if (!info || !steam || !steam.Apps) return;
        closeMenu();
        var tool = platform === "macos" ? info.tool : "";
        Promise.resolve()
          .then(function () { return steam.Apps.SpecifyCompatTool(appid, tool); })
          .catch(function () {})
          .then(function () {
            delete answers[appid];
            if (mode === "install") steam.Installs.OpenInstallWizard([appid]);
            schedule();
          });
      }
    
      // MARK: The play bar
    
      function statHTML(platform) {
        var bar = classes.bar;
        /* Cloud Status's button: Steam's compact secondary button. */
        var compact = classes.button && classes.button.AppDetailsButton ? classes.button.AppDetailsButton + " " : "";
        return '<div class="' + bar.GameStatIcon + '">' + platformGlyph(platform) + "</div>"
          + '<div class="' + bar.GameStatRight + '">'
          + '<div class="' + bar.PlayBarLabel + '">Version</div>'
          + '<div class="' + bar.PlayBarDetailLabel + '">'
          + '<button type="button" class="' + compact + bar.ClickablePlayBarItem + ' DialogButton _DialogLayout Secondary sevo-native-switch"'
          + ' title="Switch between the macOS and Windows versions">' + SHORT[platform] + " ▾</button>"
          + "</div></div>";
      }
    
      function placeStats(appid, info) {
        var sections = document.querySelectorAll("." + classes.bar.GameStatsSection);
        var o = overview(appid);
        var show = info && o && o.installed;
        var platform = show ? chosen(appid, info) : null;
        for (var i = 0; i < sections.length; i++) {
          var section = sections[i];
          var stat = section.querySelector(":scope > ." + STAT_CLASS);
          if (!show) {
            if (stat) stat.remove();
            continue;
          }
          var key = appid + ":" + platform;
          if (stat && stat.dataset.key === key && stat === section.firstElementChild) continue;
          if (!stat) {
            stat = document.createElement("div");
            stat.className = STAT_CLASS + " " + classes.bar.GameStat + " Panel";
          }
          stat.dataset.key = key;
          stat.dataset.appid = String(appid);
          stat.innerHTML = statHTML(platform);
          section.insertBefore(stat, section.firstChild);
        }
      }
    
      function clear() {
        closeMenu();
        var stats = document.querySelectorAll("." + STAT_CLASS);
        for (var i = 0; i < stats.length; i++) stats[i].remove();
      }
    
      function ensureStyle() {
        if (!document.head) return false;
        if (!document.getElementById(STYLE_ID)) {
          var style = document.createElement("style");
          style.id = STYLE_ID;
          style.textContent = CSS;
          document.head.appendChild(style);
        }
        return true;
      }
    
      var pending = 0;
      function schedule() {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; apply(); }, 150);
      }
    
      /* This copy is the one installed and it is switched on. */
      function active() {
        return window.__sevoNativeMenu === self && self.enabled;
      }
    
      function apply() {
        if (!active()) { clear(); return; }
        if (!resolve() || !ensureStyle()) return;
        var appid = currentAppID();
        if (menu && menu.appid !== appid) closeMenu();
        if (menu) place();
        placeStats(appid, appid ? offered(appid) : null);
      }
    
      // MARK: Events
    
      /* The Install button of a game that is not installed: Steam draws it
         with its download icon in every language. */
      function installButton(target) {
        var button = target.closest && target.closest("." + classes.play.PlayButton);
        return button && button.querySelector(".SVGIcon_Download") ? button : null;
      }
    
      function onClick(event) {
        if (!classes || !active()) return;
        var target = event.target;
        if (menu && menu.element.contains(target)) {
          event.preventDefault();
          event.stopPropagation();
          var pick = target.closest(".sevo-native-item");
          var go = target.closest(".sevo-native-go");
          if (target.closest(".sevo-native-cancel")) { closeMenu(); return; }
          if (go) { choose(menu.appid, go.getAttribute("data-platform"), "switch"); return; }
          if (!pick) return;
          var platform = pick.getAttribute("data-platform");
          var info = answer(menu.appid);
          if (!info) return;
          if (menu.mode === "install") { choose(menu.appid, platform, "install"); return; }
          if (platform === chosen(menu.appid, info)) { closeMenu(); return; }
          if (info.sameFiles) { choose(menu.appid, platform, "switch"); return; }
          menu.element.innerHTML = confirmHTML(platform, info);
          place();
          var confirm = menu.element.querySelector(".sevo-native-go");
          if (confirm) confirm.focus();
          return;
        }
        var appid = currentAppID();
        var info = appid && offered(appid);
        var pressed = appid && installButton(target);
        var d = pressed && !info && details(appid);
        var waiting = d && d.vecPlatforms && d.vecPlatforms.indexOf("osx") !== -1 && steamPlayOn() && answerOnItsWay(appid);
        if (waiting) {
          /* Asked before the answer arrived: wait for it, then offer the
             choice, or carry on into Steam's own wizard. */
          event.preventDefault();
          event.stopPropagation();
          waiting.then(function () {
            var ready = offered(appid);
            if (ready && currentAppID() === appid) openMenu(pressed.parentElement || pressed, appid, ready, "install");
            else ctx.SteamClient.Installs.OpenInstallWizard([appid]);
          });
          return;
        }
        var install = info && pressed;
        var stat = target.closest && target.closest(".sevo-native-switch");
        if (install || stat) {
          event.preventDefault();
          event.stopPropagation();
          var anchor = install ? install.parentElement || install : stat;
          if (menu && menu.anchor === anchor) { closeMenu(); return; }
          if (stat && !info) return;
          openMenu(anchor, appid, info, install ? "install" : "switch");
          return;
        }
        if (menu) closeMenu();
      }
    
      function onKey(event) {
        if (!menu || !active()) return;
        if (event.key === "Escape") { event.preventDefault(); closeMenu(); return; }
        var focused = document.activeElement;
        if ((event.key === "Enter" || event.key === " ") && focused && menu.element.contains(focused)) {
          event.preventDefault();
          focused.click();
          return;
        }
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          var items = Array.prototype.slice.call(menu.element.querySelectorAll(".sevo-native-item"));
          if (!items.length) return;
          event.preventDefault();
          var index = items.indexOf(focused);
          var next = event.key === "ArrowDown" ? index + 1 : index - 1;
          items[(next + items.length) % items.length].focus();
        }
      }
    
      new MutationObserver(function () { schedule(); }).observe(document, { childList: true, subtree: true });
      document.addEventListener("click", onClick, true);
      document.addEventListener("keydown", onKey, true);
      window.addEventListener("resize", function () { if (menu) place(); });
    
      var self = window.__sevoNativeMenu = { apply: apply, enabled: true };
      apply();
      return "installed";
    """

    /// Takes the menu and the play bar entry off the window. The script stays
    /// installed, so turning the feature on again is one evaluation of
    /// ``script`` away.
    static let removalScript = """
    (function () {
      if (!window.__sevoNativeMenu) { return "not installed"; }
      window.__sevoNativeMenu.enabled = false;
      window.__sevoNativeMenu.apply();
      return "removed";
    })()
    """
}
