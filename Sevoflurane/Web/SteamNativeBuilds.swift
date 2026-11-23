import Foundation

/// The choice between a game's macOS and Windows builds, in Steam's own UI
/// (``SteamPlayMacOS``).
///
/// Three places, in Steam's own controls:
/// - **Install**: for a game with a runnable macOS build, a menu with both
///   versions, their download sizes and a verdict line. The choice is mapped
///   with `SpecifyCompatTool`, and Steam's install wizard opens once the
///   game's details show the mapping; a refused mapping is said in the menu
///   with a retry.
/// - **The play bar**: a "Version" entry beside Cloud Status that switches
///   builds, saying first what Steam will download.
/// - **Properties › Compatibility**: Steam's Linux-only page, which
///   ``contextScript`` lists for games with a macOS build.
///
/// The Windows build stays one click away, since some Mac ports run worse.
/// Installs from elsewhere (context menu, `steam://`) follow the current
/// mapping, as on Linux.
enum SteamNativeBuilds {
    /// The ``contextScript`` answers that stop an installer retrying.
    static let settled: Set<String> = ["installed", "installed without the Compatibility page", "reapplied", "removed", "not installed"]

    /// The Apple and Windows logos in `currentColor`, shared with
    /// ``SteamLibraryCompat``.
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

    /// The context page's half: switches native builds on for ``script``,
    /// and lists Properties › Compatibility for games with a macOS build.
    ///
    /// The page-list component adds that page when the platform module's
    /// Linux test passes. The test is a fixed export, so the shared config's
    /// plain `PLATFORM` property becomes a getter answering `linux` only to
    /// that test called from that component (the caller read off the stack,
    /// where JavaScriptCore names frames after functions), and only for a
    /// game with a macOS build (the last game asked of the details store).
    ///
    /// The test is found as the export true for `linux` and false for
    /// `windows` and `macos`; the component by the page's localization key
    /// (``SteamPageResolver``). If either is missing only the Properties
    /// page is lost, as the result says.
    static let contextScript = "(function () {\n" + SteamPageResolver.source + context + "\n})()"

    private static let context = """
      var lib = window.__sevoNativeBuilds;
      if (lib) { lib.enabled = true; return "reapplied"; }
      var steam = steamSurface(window);
      if (!window.appDetailsStore || !steam.ready()) return "waiting";
    
      /* Lists the page, or says why it cannot. */
      function listPage() {
        var test = steam.platformTest();
        if (!test) return "no exported function answers as the Linux test";
        var names = steam.pageListers();
        if (!names.length) return "no function holds the page's label";
        var descriptor = Object.getOwnPropertyDescriptor(test.config, "PLATFORM");
        if (!descriptor || !descriptor.configurable || !("value" in descriptor)) return "the platform is not a plain property";
    
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
    
        /* Asked last: a stack trace on every read of PLATFORM costs more
           than the app-details lookup that rules out most games. */
        function askedByThePageList() {
          var frames = String(new Error().stack || "").split("\\n");
          for (var i = 1; i < frames.length - 1; i++) {
            if (frames[i].indexOf(test.name + "@") !== 0) continue;
            var caller = frames[i + 1];
            return names.indexOf(caller.slice(0, caller.indexOf("@"))) !== -1;
          }
          return false;
        }
    
        var real = descriptor.value;
        Object.defineProperty(test.config, "PLATFORM", {
          configurable: true,
          enumerable: descriptor.enumerable,
          get: function () {
            if (lib.enabled && real !== "linux" && lastAskedHasMacBuild() && askedByThePageList()) return "linux";
            return real;
          },
          set: function (value) { real = value; }
        });
        lib.page = true;
        lib.test = test.name;
        lib.pages = names;
        return null;
      }
    
      lib = window.__sevoNativeBuilds = { enabled: true, page: false };
      var missing = listPage();
      return missing ? "installed without the Compatibility page: " + missing : "installed";
    """

    /// Turns the context half off: Steam's own rule lists the Compatibility
    /// page again, and the desktop half stops drawing.
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
    static let script = "(function () {\n" + SteamPageResolver.source + platformGlyphs + text + desktop + "\n})()"

    /// The menu's localized progress and failure lines.
    private static var text: String {
        let lines: [(String, String)] = [
            ("workingMacos", String(localized: "Setting the macOS version…")),
            ("workingWindows", String(localized: "Setting the Windows version…")),
            ("inSteamForMac", String(localized: "In Steam for Mac")),
            ("failedMacos", String(localized: "Steam did not set the macOS version")),
            ("failedWindows", String(localized: "Steam did not set the Windows version")),
            ("failedBody", String(localized: "The game stays on the version it had. Try again, or choose the version in Properties › Compatibility.")),
            ("failedWizard", String(localized: "Steam did not open its installer")),
            ("failedWizardBody", String(localized: "The version is set. Try again, or install from the game's menu in the library.")),
            ("retry", String(localized: "Try Again")),
            ("close", String(localized: "Close")),
        ]
        return "  var TEXT = {"
            + lines.map { "\($0.0): \(JSLiteral.inlineString($0.1))" }.joined(separator: ", ")
            + "};\n"
    }

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
      /* How long Steam gets to show a mapping it accepted in the game's details. */
      var CONFIRM_WITHIN = 4000;
      var CONFIRM_EVERY = 200;
    
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
        "#sevo-native-menu .sevo-native-rule{height:1px;margin:4px 0;background:#4c5564}",
        ".sevo-install-platform{display:inline-flex;align-items:center;margin-inline-start:10px;opacity:1}",
        ".sevo-install-platform svg{width:18px;height:18px}",
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
      var steam = steamSurface(ctx);
      var classes = null;
      var menu = null;
    
      function esc(text) {
        return String(text == null ? "" : text)
          .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
      }
    
      /* Steam's classes for the Play button, the play bar and its compact
         button. */
      function resolve() {
        if (!classes) classes = steam.classes(["play", "bar"], ["button"]);
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
    
      /* Installed on this Mac: an overview's own `installed` is also true for
         a game another signed-in computer has, which Steam offers to stream. */
      function installedHere(o) {
        var here = o && o.local_per_client_data;
        return here ? !!here.installed : !!(o && o.installed);
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
    
      /* The build on disk, from the depots the manifest lists; the mapping
         when the depots serve both builds. A switch still downloading keeps
         the build it had. */
      function installedBuild(appid, info) {
        return info.installed || chosen(appid, info);
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
    
      function item(platform, info, current, mode, installed) {
        var hint = platform === "macos" ? info.macHint : info.windowsHint;
        var tag = "";
        if (mode === "switch" && platform === installed) tag = '<span class="sevo-native-tag">Installed</span>';
        var amount = size(download(info, platform));
        /* A switch names what it downloads; the build already on disk needs no size. */
        var right = mode !== "switch" ? amount
          : platform === installed ? ""
          : info.sameFiles ? "No download" : amount;
        /* Steam for Mac's copy is cloned in at the install gate, and Steam only checks it. */
        if (mode === "install" && platform === "macos" && info.steamForMacCopy) {
          right = "No download";
          hint = hint + " · " + TEXT.inSteamForMac;
        }
        return '<div class="sevo-native-item' + (platform === current ? " sevo-native-current" : "") + '" role="menuitemradio" tabindex="0"'
          + ' aria-checked="' + (platform === current) + '" data-platform="' + platform + '">'
          + platformGlyph(platform)
          + '<span class="sevo-native-text"><span class="sevo-native-name">' + NAMES[platform] + tag + "</span>"
          + '<span class="sevo-native-hint">' + esc(hint) + "</span></span>"
          + '<span class="sevo-native-size">' + esc(right) + "</span></div>";
      }
    
      function menuHTML(appid, info, mode, devices) {
        var current = chosen(appid, info);
        var installed = installedBuild(appid, info);
        /* Steam's own ▾ lists the devices that can stream the game; with it
           taken over, its list is one item away. */
        var other = devices
          ? '<div class="sevo-native-item sevo-native-devices" role="menuitem" tabindex="0">'
            + '<span class="sevo-native-text"><span class="sevo-native-name">Play on another device…</span>'
            + '<span class="sevo-native-hint">Steam Link and Remote Play</span></span></div>'
          : "";
        return '<div class="sevo-native-head">' + (mode === "install" ? "Install which version?" : "Version") + "</div>"
          + item("macos", info, current, mode, installed)
          + item("windows", info, current, mode, installed)
          + (other ? '<div class="sevo-native-rule"></div>' + other : "")
          + '<div class="sevo-native-foot">' + (ctx.__sevoNativeBuilds && ctx.__sevoNativeBuilds.page
            ? "You can switch any time from the play bar or Properties › Compatibility."
            : "You can switch any time from the play bar.") + "</div>";
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
    
      function workingHTML(target) {
        return '<div class="sevo-native-confirm" aria-busy="true">'
          + '<div class="sevo-native-body">' + esc(target === "macos" ? TEXT.workingMacos : TEXT.workingWindows) + "</div></div>";
      }
    
      /* Steam refused the mapping, or never showed it: the game keeps the
         build it had, and the choice can be made again from here. */
      function failedHTML(target, mode, what) {
        var wizard = what === "wizard";
        var title = wizard ? TEXT.failedWizard : target === "macos" ? TEXT.failedMacos : TEXT.failedWindows;
        return '<div class="sevo-native-confirm" role="alert">'
          + '<div class="sevo-native-title">' + esc(title) + "</div>"
          + '<div class="sevo-native-body">' + esc(wizard ? TEXT.failedWizardBody : TEXT.failedBody) + "</div>"
          + '<div class="sevo-native-buttons">'
          + '<button type="button" class="DialogButton _DialogLayout Primary sevo-native-retry" data-platform="' + target + '" data-mode="' + mode + '">' + esc(TEXT.retry) + "</button>"
          + '<button type="button" class="DialogButton _DialogLayout Secondary sevo-native-cancel">' + esc(TEXT.close) + "</button>"
          + "</div></div>";
      }
    
      function openMenu(anchor, appid, info, mode, devices) {
        openPanel(anchor, appid, mode, menuHTML(appid, info, mode, devices), devices);
        var first = menu.element.querySelector(".sevo-native-item");
        if (first) first.focus();
      }
    
      function openPanel(anchor, appid, mode, html, devices) {
        closeMenu();
        var element = document.createElement("div");
        element.id = MENU_ID;
        element.setAttribute("role", "menu");
        element.innerHTML = html;
        document.body.appendChild(element);
        menu = { element: element, appid: appid, mode: mode, anchor: anchor, devices: devices || null };
        place();
      }
    
      /* Shows `html` in the menu still open for the game, or reopens it at
         the anchor it had. */
      function showInMenu(appid, mode, anchor, html) {
        if (menu && menu.appid === appid) {
          menu.element.innerHTML = html;
          place();
        } else if (anchor && anchor.isConnected && currentAppID() === appid) {
          openPanel(anchor, appid, mode, html);
        } else {
          return;
        }
        var button = menu.element.querySelector(".sevo-native-retry");
        if (button) button.focus();
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
    
      /* Maps the game, then carries on once Steam shows the mapping in the
         game's details: the install wizard for Install, nothing more for a
         switch, which Steam answers by downloading the other build's depots.
         A refused or unconfirmed mapping leaves the game as it was and says
         so in the menu, with the choice one click away. */
      /* Steam's install wizard for one game on this computer: the second
         argument names the client the install is for, "0" being this one.
         Steam answers a wizard it opens with its show event, so one that
         never comes is said under the button rather than left as a click
         that did nothing. */
      var THIS_CLIENT = "0";
      var WIZARD_WITHIN = 8000;
      function openWizard(appid, done) {
        var installs = ctx.SteamClient && ctx.SteamClient.Installs;
        var settled = false, registration = null, timer = 0;
        function finish(opened) {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          try { if (registration && registration.unregister) registration.unregister(); } catch (e) {}
          done(opened);
        }
        if (!installs) { finish(false); return; }
        try {
          registration = installs.RegisterForShowInstallWizard(function (info) {
            if (!info || !info.currentAppID || String(info.currentAppID) === String(appid)) finish(true);
          });
        } catch (e) {}
        try { installs.OpenInstallWizard([appid], THIS_CLIENT); } catch (e) { finish(false); return; }
        /* A Steam without the show event cannot confirm; the call is all there is. */
        if (!registration) { finish(true); return; }
        timer = setTimeout(function () { finish(false); }, WIZARD_WITHIN);
      }
    
      /* Sets the game to `platform`, then in install mode opens Steam's
         wizard. `at` is where the progress and any failure show when no menu
         is open: the Install button pressed directly. */
      function choose(appid, platform, mode, at) {
        var info = answer(appid);
        var steam = ctx.SteamClient;
        if (!info || !steam || !steam.Apps) return;
        var tool = platform === "macos" ? info.tool : "";
        var anchor = menu && menu.appid === appid ? menu.anchor : at || null;
        function effective() {
          var d = details(appid);
          if (!d) return false;
          return platform === "macos" ? d.strCompatToolName === info.tool : d.strCompatToolName !== info.tool;
        }
        function confirmed() {
          delete answers[appid];
          if (ctx.__sevoLibraryCompat && typeof ctx.__sevoLibraryCompat.invalidate === "function") {
            try { ctx.__sevoLibraryCompat.invalidate(); } catch (e) {}
          }
          if (mode !== "install") {
            if (menu && menu.appid === appid) closeMenu();
            schedule();
            return;
          }
          openWizard(appid, function (opened) {
            if (opened) { if (menu && menu.appid === appid) closeMenu(); }
            else showInMenu(appid, mode, anchor, failedHTML(platform, mode, "wizard"));
            schedule();
          });
        }
        function failed() {
          delete answers[appid];
          showInMenu(appid, mode, anchor, failedHTML(platform, mode));
          schedule();
        }
        function check(waited) {
          if (effective()) { confirmed(); return; }
          if (waited >= CONFIRM_WITHIN) { failed(); return; }
          setTimeout(function () { check(waited + CONFIRM_EVERY); }, CONFIRM_EVERY);
        }
        /* Already set to it: nothing to map, straight to the wizard. */
        if (mode === "install" && effective()) { confirmed(); return; }
        showInMenu(appid, mode, anchor, workingHTML(platform));
        Promise.resolve()
          .then(function () { return steam.Apps.SpecifyCompatTool(appid, tool); })
          .then(function () { check(0); }, failed);
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
        var show = info && installedHere(o);
        var platform = show ? installedBuild(appid, info) : null;
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
    
      /* The Install button of a game with a macOS version carries the version
         it is set to, so the choice is visible before the menu opens, and a ▾
         beside it says there is a choice to make. */
      function placeInstallMarker(appid, info) {
        var buttons = document.querySelectorAll("." + classes.play.PlayButton);
        var o = info && overview(appid);
        var platform = info && o && !installedHere(o) ? chosen(appid, info) : null;
        for (var i = 0; i < buttons.length; i++) {
          var button = buttons[i];
          var marker = button.querySelector(".sevo-install-platform");
          if (!platform || !button.querySelector(".SVGIcon_Download")) {
            if (marker) marker.remove();
            placeSelector(button, false);
            continue;
          }
          placeSelector(button, true);
          if (marker && marker.dataset.platform === platform) continue;
          if (marker) marker.remove();
          marker = document.createElement("span");
          marker.className = "sevo-install-platform";
          marker.dataset.platform = platform;
          marker.title = "Installs the " + NAMES[platform] + ". The ▾ chooses the other.";
          marker.innerHTML = platformGlyph(platform);
          button.appendChild(marker);
        }
      }
    
      /* Steam's split-button ▾, the one it draws beside Play for streaming:
         its own classes and its own arrow, so its stylesheet draws the
         segment, its hover and its focus. Where Steam draws its ▾ itself,
         that one opens the version menu and none is added. */
      var FLAT_ARROW = '<svg xmlns="http://www.w3.org/2000/svg" class="SVGIcon_Button SVGIcon_FlatArrow" viewBox="0 0 256 256" style="transform:rotate(180deg)"><polygon points="13.913,141 128,59 242.087,141" fill="#ffffff"></polygon></svg>';
    
      function placeSelector(button, show) {
        var box = button.parentElement;
        if (!box) return;
        var own = box.querySelector(":scope > .sevo-install-selector");
        var steams = classes.play.StreamingSelector && box.querySelector(":scope > ." + classes.play.StreamingSelector + ":not(.sevo-install-selector)");
        if (!show || steams) {
          if (own) {
            own.remove();
            if (box.dataset.sevoSplit) { box.classList.remove(classes.play.ShowingStreaming); delete box.dataset.sevoSplit; }
          }
          return;
        }
        if (!own) {
          own = document.createElement("div");
          own.className = "sevo-install-selector " + classes.play.StreamingSelector + " " + classes.play.ButtonChild + " Focusable";
          own.setAttribute("role", "button");
          own.setAttribute("tabindex", "0");
          own.setAttribute("aria-haspopup", "menu");
          own.setAttribute("aria-label", "Choose the version to install");
          own.title = "Choose the version to install";
          own.innerHTML = FLAT_ARROW;
          own.addEventListener("keydown", function (event) {
            if (event.key === "Enter" || event.key === " ") { event.preventDefault(); own.click(); }
          });
          box.appendChild(own);
        }
        if (classes.play.ShowingStreaming && !box.classList.contains(classes.play.ShowingStreaming)) {
          box.classList.add(classes.play.ShowingStreaming);
          box.dataset.sevoSplit = "1";
        }
      }
    
      function clear() {
        closeMenu();
        var markers = document.querySelectorAll(".sevo-install-platform");
        for (var m = 0; m < markers.length; m++) markers[m].remove();
        var selectors = document.querySelectorAll(".sevo-install-selector");
        for (var n = 0; n < selectors.length; n++) {
          var box = selectors[n].parentElement;
          if (box && box.dataset.sevoSplit) { box.classList.remove(classes.play.ShowingStreaming); delete box.dataset.sevoSplit; }
          selectors[n].remove();
        }
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
        /* A copy another evaluation replaced leaves the page to its successor:
           clearing here would take the successor's marks down at every change
           it makes, and the two would redraw the play bar in turn. */
        if (window.__sevoNativeMenu !== self) { observer.disconnect(); return; }
        if (!self.enabled) { clear(); return; }
        if (!resolve() || !ensureStyle()) return;
        var appid = currentAppID();
        if (menu && menu.appid !== appid) closeMenu();
        if (menu) place();
        var info = appid ? offered(appid) : null;
        placeStats(appid, info);
        placeInstallMarker(appid, info);
      }
    
      // MARK: Events
    
      /* The Install button of a game that is not installed: Steam draws it
         with its download icon in every language. */
      function installButton(target) {
        var button = target.closest && target.closest("." + classes.play.PlayButton);
        return button && button.querySelector(".SVGIcon_Download") ? button : null;
      }
    
      /* Set while a click is handed back to Steam's own ▾. */
      var passThrough = false;
    
      function streamingSelector(target) {
        var name = classes.play.StreamingSelector;
        return name && target.closest ? target.closest("." + name) : null;
      }
    
      function onClick(event) {
        if (!classes || !active()) return;
        if (passThrough) { passThrough = false; return; }
        var target = event.target;
        if (menu && menu.element.contains(target)) {
          event.preventDefault();
          event.stopPropagation();
          if (target.closest(".sevo-native-devices") && menu.devices) {
            var devices = menu.devices;
            closeMenu();
            passThrough = true;
            devices.click();
            return;
          }
          var pick = target.closest(".sevo-native-item");
          var go = target.closest(".sevo-native-go");
          var retry = target.closest(".sevo-native-retry");
          if (target.closest(".sevo-native-cancel")) { closeMenu(); return; }
          if (go) { choose(menu.appid, go.getAttribute("data-platform"), "switch"); return; }
          if (retry) { choose(menu.appid, retry.getAttribute("data-platform"), retry.getAttribute("data-mode")); return; }
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
          /* Asked before the answer arrived: wait for it, then install the
             version the game is set to, through Steam's own wizard either way. */
          event.preventDefault();
          event.stopPropagation();
          waiting.then(function () {
            var ready = offered(appid);
            if (ready && currentAppID() === appid) choose(appid, chosen(appid, ready), "install", pressed.parentElement || pressed);
            else openWizard(appid, function () {});
          });
          return;
        }
        /* The ▾ added beside Install opens the version menu. */
        var own = info && target.closest && target.closest(".sevo-install-selector");
        if (own) {
          event.preventDefault();
          event.stopPropagation();
          var split = own.parentElement || own;
          if (menu && menu.anchor === split) { closeMenu(); return; }
          openMenu(split, appid, info, "install");
          return;
        }
        /* Steam's ▾ beside Install picks a streaming device; for a game with a
           macOS version it opens the version menu, devices one item below. */
        var selector = info && streamingSelector(target);
        var o = selector && overview(appid);
        if (selector && o && !installedHere(o)) {
          event.preventDefault();
          event.stopPropagation();
          var box = selector.parentElement || selector;
          if (menu && menu.anchor === box) { closeMenu(); return; }
          openMenu(box, appid, info, "install", selector);
          return;
        }
        /* Install itself installs the version its mark names; the ▾ beside
           it is where the choice is made. */
        var install = info && pressed;
        if (install) {
          event.preventDefault();
          event.stopPropagation();
          closeMenu();
          choose(appid, chosen(appid, info), "install", install.parentElement || install);
          return;
        }
        var stat = target.closest && target.closest(".sevo-native-switch");
        if (stat) {
          event.preventDefault();
          event.stopPropagation();
          if (menu && menu.anchor === stat) { closeMenu(); return; }
          if (!info) return;
          openMenu(stat, appid, info, "switch");
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
    
      var observer = new MutationObserver(function () { schedule(); });
      observer.observe(document, { childList: true, subtree: true });
      document.addEventListener("click", onClick, true);
      document.addEventListener("keydown", onKey, true);
      window.addEventListener("resize", function () { if (menu) place(); });
    
      var self = window.__sevoNativeMenu = { apply: apply, openMenu: openMenu, choose: choose, enabled: true };
      apply();
      return "installed";
    """

    /// Takes the menu and play bar entry off the window; evaluating
    /// ``script`` turns them on again.
    static let removalScript = """
    (function () {
      if (!window.__sevoNativeMenu) { return "not installed"; }
      window.__sevoNativeMenu.enabled = false;
      window.__sevoNativeMenu.apply();
      return "removed";
    })()
    """
}
