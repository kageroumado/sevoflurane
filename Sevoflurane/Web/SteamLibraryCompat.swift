import Foundation

/// The Mac verdict across the whole library: a badge on every game's row in
/// the left list and on its tile in the grids, each with a tooltip naming
/// what it means, and an Apple chip in the filter bar that keeps only the
/// games that play on a Mac.
///
/// Two scripts, one per realm. Steam's UI runs in the shared context page and
/// renders into the desktop window, so the state lives in the context page
/// (``contextScript``), which outlives the window: the library's verdicts,
/// fetched in one `POST /__compat/batch`, and the filter. The desktop
/// window's script (``script``) draws the badges and the chip from that
/// state.
///
/// The filter is Steam's own. The library matches every app against one
/// MobX filter class (`MatchesImpl`, `MatchesScoredImpl`), found through
/// webpack by a string its module logs, and the script wraps both methods
/// on the prototype: while the chip is on, an app that does not play on a
/// Mac fails to match. Only the library's two filters are affected (the
/// left list's and the grids'); dynamic collections build their membership
/// with the same class and are left alone, since they update it in place.
/// The wrappers read a MobX box, so every list that matched through them
/// recomputes when the chip or the verdicts change. A self-test runs the
/// wrapper once against Steam's live filter; when any piece is missing the
/// chip stays hidden and the badges still draw.
enum SteamLibraryCompat {
    /// Where the chip's state is kept in the page's local storage, so the
    /// filter is as the user left it across launches.
    static let storageKey = "sevoMacFilter"

    /// What the context script answers once it has run, the outcomes an
    /// installer stops retrying on.
    static let settled: Set<String> = ["installed", "installed without the filter", "reapplied", "removed", "not installed"]

    /// The context page's half: verdicts, the filter patch, and the switch.
    static let contextScript = """
    (function () {
      var lib = window.__sevoLibraryCompat;
      if (lib) { lib.enable(); return "reapplied"; }
      if (!window.webpackChunksteamui || !window.collectionStore || !window.uiStore) return "waiting";
      var req = null;
      try { webpackChunksteamui.push([["sevo-library-" + Date.now()], {}, function (r) { req = r; }]); } catch (e) {}
      if (!req || !req.m) return "waiting";
    
      /* The first module whose source carries the marker and whose exports
         `pick` accepts. Only modules the library has already loaded carry
         either marker, so requiring them runs nothing. */
      function find(marker, pick) {
        for (var id in req.m) {
          if (String(req.m[id]).indexOf(marker) === -1) continue;
          try {
            var found = pick(req(id));
            if (found) return found;
          } catch (e) {}
        }
        return null;
      }
    
      var KEY = \(JSLiteral.string(storageKey));
      var stored = false;
      try { stored = localStorage.getItem(KEY) === "on"; } catch (e) {}
      var plain = { on: stored, version: 0 };
      var box = null;
      var plays = new Set();
      var probing = false;
    
      /* Read through the box, so a list that matched through the filter is
         told when the chip or the verdicts change. */
      function current() { return box ? box.get() : plain; }
      function publish(on) {
        var next = { on: on, version: current().version + 1 };
        if (box) box.set(next); else plain = next;
        if (typeof lib.onChange === "function") { try { lib.onChange(); } catch (e) {} }
      }
    
      function isLibraryFilter(filter) {
        try { return filter === uiStore.currentAppFilter || filter === uiStore.collectionsAppFilter; } catch (e) { return false; }
      }
    
      function hides(filter, app) {
        if (probing) return true;
        var state = current();
        return lib.available && lib.enabled && state.on && isLibraryFilter(filter) && !plays.has(app.appid);
      }
    
      lib = window.__sevoLibraryCompat = {
        enabled: true,
        available: false,
        verdicts: {},
        pending: 0,
        onChange: null,
        isOn: function () { return lib.available && lib.enabled && current().on; },
        toggle: function () {
          var on = !current().on;
          try { localStorage.setItem(KEY, on ? "on" : "off"); } catch (e) {}
          publish(on);
        },
        enable: function () { lib.enabled = true; publish(current().on); refresh(); },
        disable: function () { lib.enabled = false; publish(current().on); },
        sync: function () {
          patch();
          if (libraryCount() !== asked || Date.now() - answeredAt > STALE_AFTER) refresh();
        },
        /* A game's build changed: ask now, and once more after Steam has had
           time to write the mapping the bridge reads. */
        invalidate: function () {
          if (inflight) again = true; else refresh();
          clearTimeout(settle);
          settle = setTimeout(refresh, SETTLE_AFTER);
        }
      };
    
      /* Steam loads the filter's module and makes the library's filter only
         once the library is first drawn, which can be after this script
         runs at boot, so the patch and its self-test are tried again at
         each sync until they hold. */
      var lastPatch = 0;
      function patch() {
        if (lib.available || Date.now() - lastPatch < 5000) return;
        lastPatch = Date.now();
        var Filter = find("Found SteamDeckUnsupported set in AppFilter", function (exports) {
          for (var key in exports) {
            var proto = exports[key] && exports[key].prototype;
            if (proto && typeof proto.MatchesImpl === "function" && typeof proto.MatchesScoredImpl === "function"
                && Object.getOwnPropertyDescriptor(proto, "bIsEmpty")) return exports[key];
          }
          return null;
        });
        var observable = find("[MobX]", function (exports) {
          for (var key in exports) {
            if (typeof exports[key] === "function" && typeof exports[key].box === "function") return exports[key];
          }
          return null;
        });
    
        if (!box && observable) box = observable.box(plain, { deep: false });
        if (Filter && box) {
          var proto = Filter.prototype;
          if (!proto.__sevoMacFilter) {
            var matches = proto.MatchesImpl;
            var scored = proto.MatchesScoredImpl;
            var empty = Object.getOwnPropertyDescriptor(proto, "bIsEmpty");
            proto.MatchesImpl = function (app) { return hides(this, app) ? false : matches.call(this, app); };
            proto.MatchesScoredImpl = function (app) { return hides(this, app) ? 0 : scored.call(this, app); };
            /* An empty filter is skipped outright by some of the library's
               lists; with the chip on, the library's filter is not empty. */
            Object.defineProperty(proto, "bIsEmpty", {
              configurable: true,
              get: function () { return empty.get.call(this) && !(lib.isOn() && isLibraryFilter(this)); }
            });
            proto.__sevoMacFilter = true;
          }
          /* The library's filter is a subclass that matches the app type
             before it calls these, so the wrappers are run on it directly. */
          try {
            var live = uiStore.collectionsAppFilter;
            probing = true;
            lib.available = live instanceof Filter && proto.MatchesImpl.call(live, { appid: -1 }) === false
              && proto.MatchesScoredImpl.call(live, { appid: -1 }) === 0;
          } catch (e) {
            lib.available = false;
          } finally {
            probing = false;
          }
        }
    
        if (lib.available) publish(current().on);
      }
    
      /* The library's games, as the bridge's batch endpoint takes them, and the
         companion apps Steam files under Software. */
      var COMPANIONS = \(GameCompanion.appIDsLiteral);
      function games() {
        var apps = [];
        try {
          collectionStore.allAppsCollection.allApps.forEach(function (o) {
            if ((o.app_type === 1 || COMPANIONS[o.appid]) && !(o.BIsModOrShortcut && o.BIsModOrShortcut())) apps.push([o.appid, o.display_name || ""]);
          });
        } catch (e) {}
        return apps;
      }
    
      function libraryCount() {
        try { return collectionStore.allAppsCollection.allApps.length; } catch (e) { return 0; }
      }
    
      /* The library's size at the last ask; a purchase or a removal asks again.
         An answer older than STALE_AFTER is asked again at the next sync, which
         catches a build changed outside the version menu. */
      var asked = -1;
      var answeredAt = 0;
      var inflight = false;
      var again = false;
      var timer = 0;
      var settle = 0;
      var STALE_AFTER = 120000;
      var SETTLE_AFTER = 15000;
      function later(ms) { clearTimeout(timer); timer = setTimeout(refresh, ms); }
    
      function refresh() {
        if (!lib.enabled || inflight) return;
        var apps = games();
        if (!apps.length) { later(5000); return; }
        inflight = true;
        asked = libraryCount();
        fetch("/__compat/batch", {
          method: "POST", cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ apps: apps })
        })
          .then(function (response) { return response.ok ? response.json() : null; })
          .then(function (answer) {
            inflight = false;
            answeredAt = Date.now();
            if (again) { again = false; refresh(); return; }
            if (!answer || !answer.apps) { later(60000); return; }
            lib.verdicts = answer.apps;
            lib.pending = answer.pending || 0;
            var next = new Set();
            for (var id in answer.apps) {
              var v = answer.apps[id];
              if (v.p) next.add(Number(id));
            }
            plays = next;
            publish(current().on);
            if (lib.pending > 0) later(30000);
          })
          .catch(function () { inflight = false; answeredAt = Date.now(); later(60000); });
      }
    
      patch();
      refresh();
      return lib.available ? "installed" : "installed without the filter";
    })()
    """

    /// Stands the context page's half down: the filter matches as Steam's
    /// own again and the window's badges and chip come off.
    static let contextRemovalScript = """
    (function () {
      if (!window.__sevoLibraryCompat) return "not installed";
      window.__sevoLibraryCompat.disable();
      return "removed";
    })()
    """

    /// The desktop window's half: badges on rows and tiles, the chip beside
    /// the search, and the tooltip that names what each means. The rows and
    /// tiles carry no app id in the DOM; React's fiber on each holds the
    /// props it was drawn from, the app id among them. Idempotent and
    /// self-reapplying, like ``SteamCompatBadge``.
    static var script: String {
        "(function () {\n" + SteamCompatBadge.glyphs + SteamNativeBuilds.platformGlyphs + text + desktop + "\n})()"
    }

    /// What the tooltip says over each mark and over the filter, in the
    /// app's language: a name and one line of what it means, then the line
    /// naming where the verdict comes from.
    private static var text: String {
        let lines: [(String, String, String)] = [
            ("platinum", String(localized: "Platinum"), String(localized: "Runs perfectly.")),
            ("gold", String(localized: "Gold"), String(localized: "Runs perfectly after tweaks.")),
            ("silver", String(localized: "Silver"), String(localized: "Runs with minor issues; generally playable.")),
            ("bronze", String(localized: "Bronze"), String(localized: "Runs, but with crashes or issues that get in the way of playing.")),
            ("borked", String(localized: "Borked"), String(localized: "Does not run: it crashes, or its anti-cheat refuses to run.")),
            ("fromMac", "", String(localized: "Rated on a Mac, by Sevoflurane players' runs or AppleGamingWiki.")),
            ("fromLinux", "", String(localized: "Rated on Linux by ProtonDB; untested on a Mac.")),
            ("macAvailable", String(localized: "macOS version available"), String(localized: "Steam has a macOS version of this game that runs on Apple silicon. The version menu beside Install chooses it.")),
            ("macSet", String(localized: "Set to its macOS version"), String(localized: "Steam installs and plays this game's own macOS version.")),
            ("companion", String(localized: "Plays through Phosphene"), String(localized: "Phosphene finds the wallpapers Steam downloads and plays them as your Mac's wallpaper.")),
            ("filterOn", String(localized: "Showing games that play on this Mac"), String(localized: "Click to show every game.")),
            ("filterOff", String(localized: "Show games that play on this Mac"), String(localized: "Keeps the games Mac players rate Verified or Playable, and those with a macOS version that runs on Apple silicon.")),
        ]
        return "  var TEXT = {"
            + lines.map { "\($0.0): [\(JSLiteral.inlineString($0.1)), \(JSLiteral.inlineString($0.2))]" }.joined(separator: ", ")
            + "};\n"
    }

    private static let desktop = """
      if (window.__sevoLibraryBadges) {
        window.__sevoLibraryBadges.apply();
        return "reapplied";
      }
    
      var ctx = window.opener || window;
      var STYLE_ID = "sevo-library-style";
      var CHIP_ID = "sevo-mac-chip";
      var TIP_ID = "sevo-lib-tip";
      var TIP_DELAY = 350;
      /* Small medals in ProtonDB's colors; on a tile they sit on a dark
         disc so they read over any art. The apple is muted while the macOS
         version is only available and Steam's link blue once the game is
         set to it. The chip is sized like the filter button beside it. */
      var CSS = STATE_CSS + "\\n" + MEDAL_CSS + "\\n" + [
        ".sevo-lib-badge{display:flex;align-items:center;flex:none;gap:3px;cursor:default}",
        /* The left list's rows size every svg in them, color it, and stroke
           every path 40% white; a badge keeps its state's color and the
           filled discs take no outline. */
        ".sevo-lib-badge svg{width:16px !important;height:16px !important;color:inherit !important}",
        ".sevo-lib-badge svg path{stroke:none !important}",
        ".sevo-lib-row{margin-inline-start:auto;padding:0 8px 0 6px}",
        /* A row is sized to its title; held to the list's width, a long title
           ends in an ellipsis and the badge stays in view. */
        ".Panel:has(.sevo-lib-row){max-width:100%}",
        "*:has(> .sevo-lib-row) > :not(.sevo-lib-badge):not([class]){min-width:0;overflow:hidden;text-overflow:ellipsis}",
        ".sevo-lib-tile{position:absolute;top:6px;left:6px;z-index:3;padding:3px;border-radius:12px;background-color:rgba(14,20,27,0.85)}",
        ".sevo-lib-badge .sevo-platform{display:flex}",
        ".sevo-lib-badge .sevo-mac-available{color:#8b929a}",
        ".sevo-lib-badge .sevo-mac-set{color:#1a9fff}",
        "#sevo-mac-chip:not(.sevo-in-bar){display:flex;align-items:center;gap:5px;height:32px;padding:0 8px;margin-inline-start:2px;border-radius:2px;color:#8b929a;font-size:10px;font-weight:700;text-transform:uppercase;cursor:pointer;user-select:none;flex:none}",
        "#sevo-mac-chip:not(.sevo-in-bar):hover{background-color:#3d4450;color:#fff}",
        "#sevo-mac-chip.sevo-on:not(.sevo-in-bar){background-color:#3d4450;color:#fff}",
        "#sevo-mac-chip .sevo-compat-icon>svg{width:16px;height:16px}",
        /* In the bar, Steam's CheckboxWithImage class sizes the button and
           colors its icon through the svg's fill, gray or the active blue,
           with a stroke on every path for its own outline-drawn icons. The
           apple is a filled shape: it takes the fill and no stroke. */
        "#sevo-mac-chip.sevo-in-bar .sevo-platform{display:flex;align-items:center;justify-content:center}",
        "#sevo-mac-chip.sevo-in-bar svg{width:20px;height:20px}",
        "#sevo-mac-chip.sevo-in-bar svg path{fill:inherit !important;stroke:none !important}",
        /* The tooltip, in the look of Steam's own menus and panels. */
        "#sevo-lib-tip{position:fixed;z-index:100000;max-width:280px;padding:8px 10px;border-radius:3px;background:#3d4450;color:#dfe3e6;font-size:12px;line-height:16px;box-shadow:0 10px 32px rgba(0,0,0,0.67);pointer-events:none;opacity:0;transition:opacity 0.12s ease-out}",
        "#sevo-lib-tip.sevo-shown{opacity:1}",
        "#sevo-lib-tip>div+div{margin-top:6px}",
        "#sevo-lib-tip>.sevo-tip-source{margin-top:2px;color:#b8bcbf}",
        "#sevo-lib-tip b{display:block;color:#fff;font-weight:600}"
      ].join("\\n");
    
      var names = null;
    
      /* The class modules behind the library search, the left list's rows
         and the grid's tiles, found by their semantic keys like the strip's. */
      function resolve() {
        if (names) return names;
        var chunk = ctx.webpackChunksteamui;
        if (!chunk || typeof chunk.push !== "function") return null;
        var req = null;
        try { chunk.push([["sevo-library-" + Date.now()], {}, function (r) { req = r; }]); } catch (e) { return null; }
        if (!req || !req.m) return null;
        var found = {};
        var wanted = {
          search: "AdvancedSearchContainer", row: "GameListEntryContainer", tile: "LibraryItemBox",
          filters: "ViewFiltersBar"
        };
        for (var id in req.m) {
          var source = String(req.m[id]);
          if (source.length > 20000) continue;
          for (var role in wanted) {
            if (found[role] || source.indexOf(wanted[role] + ':"') === -1) continue;
            try {
              var exports = req(id);
              if (exports && exports[wanted[role]]) found[role] = exports;
            } catch (e) {}
          }
        }
        if (!found.search || !found.row || !found.tile) return null;
        names = found;
        return names;
      }
    
      function appidOf(element) {
        var keys = Object.keys(element);
        var fiber = null;
        for (var i = 0; i < keys.length; i++) {
          if (keys[i].indexOf("__reactFiber$") === 0) { fiber = element[keys[i]]; break; }
        }
        for (var depth = 0; fiber && depth < 15; depth++, fiber = fiber.return) {
          var props = fiber.memoizedProps;
          if (!props || typeof props !== "object") continue;
          if (typeof props.appid === "number") return props.appid;
          if (props.app && typeof props.app.appid === "number") return props.app.appid;
        }
        return null;
      }
    
      /* The marks a verdict earns: its medal when rated, and an apple for a
         macOS version, muted while it is only available and blue once the
         game is set to it. Unrated with no macOS version draws nothing. Each
         mark names the tooltip lines that explain it, the medal's followed by
         where the rating comes from. */
      function badge(verdict) {
        var html = "";
        var tips = [];
        if (verdict.c) {
          html += glyph("verified");
          tips.push("companion");
        }
        if (TEXT[verdict.t]) {
          html += medal(verdict.t);
          tips.push(verdict.t, verdict.l ? "fromLinux" : "fromMac");
        }
        if (verdict.m || verdict.n) {
          var which = verdict.m ? "macSet" : "macAvailable";
          html += platformGlyph("macos").replace("sevo-platform-macos", "sevo-platform-macos " + (verdict.m ? "sevo-mac-set" : "sevo-mac-available"));
          tips.push(which);
        }
        return html ? { html: html, tips: tips } : null;
      }
    
      function decorate(selector, kind, verdicts) {
        var hosts = document.querySelectorAll(selector);
        for (var i = 0; i < hosts.length; i++) {
          var host = hosts[i];
          var existing = host.querySelector(":scope > .sevo-lib-badge");
          var appid = appidOf(host);
          var verdict = appid != null ? verdicts[appid] : null;
          var drawn = verdict ? badge(verdict) : null;
          if (!drawn) {
            if (existing) existing.remove();
            continue;
          }
          var key = appid + ":" + verdict.t + ":" + (verdict.l ? 1 : 0) + (verdict.n ? 1 : 0) + (verdict.m ? 1 : 0) + (verdict.c ? 1 : 0);
          if (existing && existing.dataset.key === key && existing === host.lastElementChild) continue;
          var element = existing || document.createElement("span");
          element.className = "sevo-lib-badge " + kind;
          element.dataset.key = key;
          element.dataset.tips = drawn.tips.join(" ");
          element.setAttribute("role", "img");
          element.setAttribute("aria-label", drawn.tips.map(function (t) { return TEXT[t][0]; }).filter(Boolean).join(", "));
          element.innerHTML = drawn.html;
          host.appendChild(element);
        }
      }
    
      /* Steam for Mac draws an Apple filter first in the bar beside the
         collection picker (Recent, Ready to Play); Steam on Windows leaves the
         slot out. The toggle goes there, in Steam's own button classes. */
      function filtersBar() {
        var f = names.filters;
        if (!f || !f.ViewFiltersBar || !f.Filters || !f.CheckboxWithImage) return null;
        return document.querySelector("." + f.ViewFiltersBar + " ." + f.Filters);
      }
    
      function placeChip(lib) {
        var bar = filtersBar();
        var anchor = bar ? null : document.querySelector("." + names.search.Container + " ." + names.search.AdvancedSearchContainer);
        var chip = document.getElementById(CHIP_ID);
        if (!lib.available || (!bar && !anchor)) {
          if (chip) chip.remove();
          return;
        }
        var on = lib.isOn();
        var tip = on ? "filterOn" : "filterOff";
        if (bar) {
          if (!chip || chip.parentElement !== bar || bar.firstElementChild !== chip) {
            if (chip) chip.remove();
            chip = document.createElement("div");
            chip.id = CHIP_ID;
            chip.setAttribute("role", "button");
            chip.tabIndex = 0;
            chip.innerHTML = platformGlyph("macos");
            bar.insertBefore(chip, bar.firstElementChild);
          }
          chip.className = names.filters.CheckboxWithImage + " sevo-in-bar" + (on && names.filters.Active ? " " + names.filters.Active : "");
        } else {
          if (!chip || chip.previousElementSibling !== anchor) {
            if (chip) chip.remove();
            chip = document.createElement("div");
            chip.id = CHIP_ID;
            chip.setAttribute("role", "button");
            chip.tabIndex = 0;
            chip.innerHTML = glyph("verified") + "<span>Mac</span>";
            anchor.insertAdjacentElement("afterend", chip);
          }
          chip.className = on ? "sevo-on" : "";
        }
        chip.setAttribute("aria-pressed", on ? "true" : "false");
        chip.setAttribute("aria-label", TEXT[tip][0]);
        if (chip.dataset.tips !== tip) {
          chip.dataset.tips = tip;
          if (tipFor === chip) showTip(chip);
        }
      }
    
      /* One tooltip for every mark and the chip, shown after a short hover
         like Steam's own, below its mark or above when the window ends. */
      var tipFor = null;
      var tipPending = null;
      var tipTimer = 0;
      function tipElement() {
        var tip = document.getElementById(TIP_ID);
        if (!tip && document.body) {
          tip = document.createElement("div");
          tip.id = TIP_ID;
          tip.setAttribute("role", "tooltip");
          document.body.appendChild(tip);
        }
        return tip;
      }
    
      function showTip(target) {
        var tip = tipElement();
        if (!tip || !target.isConnected) return;
        var html = "";
        (target.dataset.tips || "").split(" ").forEach(function (key) {
          if (!TEXT[key]) return;
          html += TEXT[key][0] ? "<div><b>" + esc(TEXT[key][0]) + "</b>" + esc(TEXT[key][1]) + "</div>" : '<div class="sevo-tip-source">' + esc(TEXT[key][1]) + "</div>";
        });
        if (!html) return;
        tip.innerHTML = html;
        var rect = target.getBoundingClientRect();
        tip.style.left = "0px";
        tip.style.top = "0px";
        var width = tip.offsetWidth;
        var height = tip.offsetHeight;
        var left = Math.max(8, Math.min(rect.left, window.innerWidth - width - 8));
        var top = rect.bottom + 6;
        if (top + height > window.innerHeight - 8) top = rect.top - height - 6;
        tip.style.left = left + "px";
        tip.style.top = top + "px";
        tip.classList.add("sevo-shown");
        tipFor = target;
      }
    
      function hideTip() {
        clearTimeout(tipTimer);
        tipTimer = 0;
        tipPending = null;
        tipFor = null;
        var tip = document.getElementById(TIP_ID);
        if (tip) tip.classList.remove("sevo-shown");
      }
    
      function esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
      }
    
      function hover(event) {
        var target = event.target.closest && event.target.closest(".sevo-lib-badge, #" + CHIP_ID);
        if (target === tipFor || target === tipPending) return;
        hideTip();
        if (!target) return;
        tipPending = target;
        tipTimer = setTimeout(function () { tipTimer = 0; tipPending = null; showTip(target); }, TIP_DELAY);
      }
    
      function unhover(event) {
        var target = event.target.closest && event.target.closest(".sevo-lib-badge, #" + CHIP_ID);
        if (!target) return;
        var to = event.relatedTarget;
        if (to && to.closest && to.closest(".sevo-lib-badge, #" + CHIP_ID) === target) return;
        hideTip();
      }
    
      function clear() {
        hideTip();
        var chip = document.getElementById(CHIP_ID);
        if (chip) chip.remove();
        var badges = document.querySelectorAll(".sevo-lib-badge");
        for (var i = 0; i < badges.length; i++) badges[i].remove();
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
      function schedule(ms) {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; apply(); }, ms || 150);
      }
    
      function apply() {
        var lib = ctx.__sevoLibraryCompat;
        if (!lib || !lib.enabled) {
          clear();
          /* The context half installs on its own schedule; look again. */
          if (!lib) schedule(2000);
          return;
        }
        if (!resolve() || !ensureStyle()) return;
        lib.onChange = function () { schedule(); };
        lib.sync();
        placeChip(lib);
        decorate("." + names.row.GameListEntryContainer, "sevo-lib-row", lib.verdicts);
        decorate("." + names.tile.LibraryItemBox, "sevo-lib-tile", lib.verdicts);
        if (tipFor && !tipFor.isConnected) hideTip();
      }
    
      function toggle(event) {
        var chip = event.target.closest && event.target.closest("#" + CHIP_ID);
        if (!chip) return;
        if (event.type === "keydown" && event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        event.stopPropagation();
        var lib = ctx.__sevoLibraryCompat;
        if (lib) lib.toggle();
      }
    
      new MutationObserver(function () { schedule(); }).observe(document, { childList: true, subtree: true });
      document.addEventListener("click", toggle, true);
      document.addEventListener("keydown", toggle, true);
      document.addEventListener("mouseover", hover, true);
      document.addEventListener("mouseout", unhover, true);
      document.addEventListener("scroll", hideTip, true);
      window.addEventListener("blur", hideTip);
    
      window.__sevoLibraryBadges = { apply: apply };
      apply();
      return "installed";
    """

    /// Takes the badges and chip off the window. The script stays installed
    /// and reads the context half's switch, which ``contextRemovalScript``
    /// turns off; this redraws the window at once.
    static let removalScript = """
    (function () {
      if (!window.__sevoLibraryBadges) { return "not installed"; }
      window.__sevoLibraryBadges.apply();
      return "removed";
    })()
    """
}
