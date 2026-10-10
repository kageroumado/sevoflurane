import Foundation

/// The Mac compatibility strip, on a game's library page and on its store
/// page.
///
/// Steam's own compatibility strip (`DeckVerifiedInfo`) is gated behind
/// `bSteamOS && bSteamDeck`, so the desktop client on a Mac draws nothing in
/// that slot. This script draws the same strip there, with the same geometry,
/// colors and glyphs Steam's stylesheet gives the Deck one: the verdict on the
/// Windows build the bottle runs, the game's own macOS version when it has
/// one, the anti-cheat verdict, and a Details panel that names every source.
/// Both pages read one ``GameCompatRecord``, so a game says the same thing in
/// the library and in the store.
///
/// On the library page the slot is found through webpack rather than a class
/// name: Steam's class names are content hashes, but the module that exports
/// them is a plain `{DeckVerifiedInfo: "hash", Container: "hash", …}` object,
/// so its source text is searched for the semantic key and the current hash
/// is read off it. Steam's UI runs in the opener (the shared context page) and
/// renders into this popup, so the webpack runtime, the router and the app
/// store are all reached through `window.opener`. The record comes from the
/// bridge's `/__compat/<appid>`.
///
/// The store page is a native web view at Steam's own origin, which cannot
/// reach the bridge; it asks the `sevoCompat` message handler instead
/// (``BrowserViewChild``), and the strip sits above Steam's Deck block in the
/// right column.
///
/// Idempotent and self-reapplying, like ``SteamDesktopChrome``: the observer
/// sits on the Document, which survives Steam's `document.open()`.
enum SteamCompatBadge {
    /// The library page's strip.
    static let script = "(function () {\n" + common + library + "\n})()"

    /// The store page's strip, installed as a user script on the store's
    /// child web views.
    static let storeScript = "(function () {\n" + common + store + "\n})()"

    /// The message handler the store page asks for its record, and opens the
    /// sources' pages through.
    static let storeHandler = "sevoCompat"

    /// Steam's four state glyphs, the colors its stylesheet gives each state,
    /// and `glyph(state)` drawing one. The strip and the library's badges
    /// (``SteamLibraryCompat``) share them, so a game reads alike in both.
    static let glyphs = """
      /* Steam's four state glyphs, verbatim from its compatibility module, so
         the strip reads as the client's own. */
      var PATHS = {
        verified: "M10 19C14.9706 19 19 14.9706 19 10C19 5.02944 14.9706 1 10 1C5.02944 1 1 5.02944 1 10C1 14.9706 5.02944 19 10 19ZM8.33342 11.9222L14.4945 5.76667L16.4556 7.72779L8.33342 15.8556L3.26675 10.7833L5.22786 8.82223L8.33342 11.9222Z",
        playable: "M10 19C14.9706 19 19 14.9706 19 10C19 5.02944 14.9706 1 10 1C5.02944 1 1 5.02944 1 10C1 14.9706 5.02944 19 10 19ZM8.61079 9.44444V15H11.3886V9.44444H8.61079ZM9.07372 8.05245C9.34781 8.23558 9.67004 8.33333 9.99967 8.33333C10.4417 8.33333 10.8656 8.15774 11.1782 7.84518C11.4907 7.53262 11.6663 7.10869 11.6663 6.66667C11.6663 6.33703 11.5686 6.0148 11.3855 5.74072C11.2023 5.46663 10.942 5.25301 10.6375 5.12687C10.3329 5.00072 9.99783 4.96771 9.67452 5.03202C9.35122 5.09633 9.05425 5.25507 8.82116 5.48815C8.58808 5.72124 8.42934 6.01821 8.36503 6.34152C8.30072 6.66482 8.33373 6.99993 8.45988 7.30447C8.58602 7.60902 8.79964 7.86931 9.07372 8.05245Z",
        unsupported: "M14.1931 15.6064C13.0246 16.4816 11.5733 17 10.001 17C6.13498 17 3.00098 13.866 3.00098 10C3.00098 8.42766 3.51938 6.97641 4.39459 5.80783L14.1931 15.6064ZM15.6074 14.1922C16.4826 13.0236 17.001 11.5723 17.001 10C17.001 6.13401 13.867 3 10.001 3C8.42864 3 6.97739 3.5184 5.80881 4.39362L15.6074 14.1922ZM19.001 10C19.001 14.9706 14.9715 19 10.001 19C5.03041 19 1.00098 14.9706 1.00098 10C1.00098 5.02944 5.03041 1 10.001 1C14.9715 1 19.001 5.02944 19.001 10Z",
        unknown: "M17.3972 11.2461L18.8767 11.4932C18.9578 11.0075 19 10.5087 19 10C19 9.49131 18.9578 8.99248 18.8767 8.50682L17.3972 8.75386C17.4647 9.15821 17.5 9.57442 17.5 10C17.5 10.4256 17.4647 10.8418 17.3972 11.2461ZM17.0295 7.3783L18.4348 6.8539C18.0814 5.90668 17.5729 5.03501 16.9403 4.26971L15.7842 5.22538C16.3119 5.86387 16.7354 6.59021 17.0295 7.3783ZM14.7746 4.21582L15.7303 3.05967C14.965 2.42708 14.0933 1.91864 13.1461 1.56519L12.6217 2.97054C13.4098 3.26461 14.1361 3.68805 14.7746 4.21582ZM11.2461 2.60281L11.4932 1.1233C11.0075 1.0422 10.5087 1 10 1C9.49131 1 8.99248 1.0422 8.50682 1.1233L8.75386 2.60281C9.15821 2.5353 9.57442 2.5 10 2.5C10.4256 2.5 10.8418 2.5353 11.2461 2.60281ZM7.3783 2.97054L6.8539 1.56519C5.90668 1.91864 5.03501 2.42708 4.26971 3.05967L5.22538 4.21582C5.86387 3.68805 6.59021 3.26461 7.3783 2.97054ZM4.21582 5.22538L3.05967 4.26971C2.42708 5.03501 1.91864 5.90668 1.56519 6.8539L2.97054 7.3783C3.26461 6.59022 3.68805 5.86387 4.21582 5.22538ZM1 10C1 9.49131 1.0422 8.99248 1.1233 8.50682L2.60281 8.75386C2.5353 9.15821 2.5 9.57442 2.5 10C2.5 10.4256 2.5353 10.8418 2.60281 11.2461L1.1233 11.4932C1.0422 11.0075 1 10.5087 1 10ZM2.97054 12.6217L1.56519 13.1461C1.91864 14.0933 2.42708 14.965 3.05967 15.7303L4.21582 14.7746C3.68805 14.1361 3.26461 13.4098 2.97054 12.6217ZM5.22538 15.7842L4.26971 16.9403C5.03501 17.5729 5.90668 18.0814 6.8539 18.4348L7.3783 17.0295C6.59022 16.7354 5.86387 16.3119 5.22538 15.7842ZM8.75386 17.3972L8.50682 18.8767C8.99248 18.9578 9.49131 19 10 19C10.5087 19 11.0075 18.9578 11.4932 18.8767L11.2461 17.3972C10.8418 17.4647 10.4256 17.5 10 17.5C9.57442 17.5 9.15821 17.4647 8.75386 17.3972ZM12.6217 17.0295L13.1461 18.4348C14.0933 18.0814 14.965 17.5729 15.7303 16.9403L14.7746 15.7842C14.1361 16.3119 13.4098 16.7354 12.6217 17.0295ZM15.7842 14.7746L16.9403 15.7303C17.5729 14.965 18.0814 14.0933 18.4348 13.1461L17.0295 12.6217C16.7354 13.4098 16.3119 14.1361 15.7842 14.7746ZM9.2425 14.7702C9.46679 14.92 9.73048 15 10.0002 15C10.362 15 10.7089 14.8563 10.9646 14.6006C11.2204 14.3448 11.3641 13.998 11.3641 13.6363C11.3641 13.3666 11.2841 13.1029 11.1343 12.8787C10.9844 12.6544 10.7714 12.4796 10.5222 12.3764C10.2729 12.2732 9.99872 12.2462 9.73415 12.2988C9.46958 12.3514 9.22656 12.4813 9.03582 12.672C8.84508 12.8628 8.71518 13.1057 8.66255 13.3703C8.60993 13.6348 8.63694 13.909 8.74016 14.1582C8.84339 14.4074 9.01821 14.6203 9.2425 14.7702ZM11.0981 10.3552C11.1722 10.2348 11.2765 10.1358 11.4005 10.068C11.8099 9.82315 12.1479 9.47526 12.3808 9.05903C12.6137 8.64279 12.7333 8.17276 12.7278 7.69584C12.7223 7.21892 12.5918 6.75179 12.3493 6.34105C12.1069 5.93031 11.7609 5.59033 11.346 5.35502C10.9311 5.11972 10.4617 4.99732 9.98466 5.00004C9.50764 5.00277 9.03969 5.13052 8.62748 5.37054C8.21527 5.61057 7.87321 5.95448 7.63545 6.36796C7.39769 6.78144 7.27253 7.25004 7.27246 7.72699H9.23191C9.23191 7.6261 9.25178 7.52621 9.29039 7.43301C9.32901 7.3398 9.3856 7.25511 9.45694 7.18378C9.52829 7.11244 9.61299 7.05586 9.70621 7.01725C9.79942 6.97865 9.89933 6.95878 10.0002 6.95878C10.1659 6.96387 10.3255 7.02207 10.4556 7.12479C10.5856 7.22751 10.6792 7.3693 10.7225 7.52925C10.7658 7.6892 10.7565 7.85883 10.6961 8.01311C10.6356 8.16739 10.5271 8.29816 10.3867 8.3861C9.97322 8.62846 9.63003 8.97429 9.39088 9.38955C9.15173 9.80482 9.02487 10.2752 9.02278 10.7544V11.3635H10.9777V10.7544C10.9825 10.6131 11.024 10.4755 11.0981 10.3552Z"
      };
      var STATE_CSS = [
        ".sevo-compat-icon{display:flex;flex:none}",
        ".sevo-compat-icon>svg{width:20px;height:20px}",
        ".sevo-compat-verified{color:#59bf40}",
        ".sevo-compat-playable{color:#ffc82c}",
        ".sevo-compat-unsupported,.sevo-compat-unknown{color:#dcdedf}"
      ].join("\\n");
    
      function glyph(state) {
        var s = PATHS[state] ? state : "unknown";
        return '<span class="sevo-compat-icon sevo-compat-' + s + '"><svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg"><path fill-rule="evenodd" clip-rule="evenodd" d="' + PATHS[s] + '" fill="currentColor"></path></svg></span>';
      }
    
    """

    /// Everything both pages draw with: Steam's glyphs and strip styles, and
    /// the strip and Details panel built from a record.
    private static let common = glyphs + """
      var STYLE_ID = "sevo-compat-style";
      var SLOT_ID = "sevo-compat-slot";
      var STRIP_ID = "sevo-compat";
      var PANEL_ID = "sevo-compat-panel";
    
      /* Steam's rules for the Deck strip, values copied from its stylesheet:
         the strip, its 16px title, the 10px uppercase label, and the Details
         pill and its hover swap.
         The store's right column is narrow, so there the cells stack. */
      var CSS = STATE_CSS + "\\n" + [
        ".sevo-compat-slot{padding:6px 20px 0}",
        ".sevo-compat-slot.sevo-compat-store{padding:0 0 12px}",
        ".sevo-compat{background-color:#23262e;padding:8px 22px;border-radius:2px;display:flex;flex-direction:row;align-items:center;flex-wrap:wrap;gap:10px;color:#fff}",
        ".sevo-compat-store .sevo-compat{padding:10px 14px;column-gap:14px;row-gap:6px}",
        ".sevo-compat-store .sevo-compat-sep{display:none}",
        ".sevo-compat-store .sevo-compat-title{font-size:13px;flex:1 1 55%}",
        ".sevo-compat-store .sevo-compat-details{margin-inline-start:0;margin-top:4px}",
        ".sevo-compat-title{font-size:16px}",
        ".sevo-compat-label{display:flex;flex-direction:row;align-items:center;gap:8px;font-size:10px;font-weight:700;text-transform:uppercase}",
        ".sevo-compat-sep{width:1px;height:20px;background-color:#3d4450;margin:0 8px}",
        ".sevo-compat-details{background-color:#3d4450;padding:6px 14px;font-size:12px;border-radius:2px;color:#fff;text-decoration:none;cursor:pointer;margin-inline-start:auto;user-select:none}",
        ".sevo-compat-details:hover{background-color:#fff;color:#000}",
        ".sevo-compat-panel{background-color:#23262e;padding:12px 22px 14px;margin-top:2px;border-radius:2px;color:#dcdedf;font-size:12px;display:flex;flex-direction:column;gap:6px}",
        ".sevo-compat-store .sevo-compat-panel{padding:10px 14px 12px}",
        /* An author `display` beats the UA's `[hidden]` rule; say it again. */
        ".sevo-compat-panel[hidden]{display:none}",
        ".sevo-compat-row{display:flex;flex-direction:row;align-items:flex-start;gap:10px;line-height:20px}",
        ".sevo-compat-row b{color:#fff;font-weight:600}",
        ".sevo-compat-link{color:#1a9fff;cursor:pointer;text-decoration:none;white-space:nowrap}",
        ".sevo-compat-link:hover{color:#00bbff}",
        ".sevo-compat-note{font-style:italic;color:#8b929a;margin-inline-start:30px;line-height:18px}"
      ].join("\\n");
    
      var records = {};
      var open = {};
    
      function esc(text) {
        return String(text == null ? "" : text)
          .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
      }
    
      var DECK = { 1: ["unsupported", "Unsupported"], 2: ["playable", "Playable"], 3: ["verified", "Verified"] };
    
      function tierWord(tier) {
        return tier && tier !== "na" && tier !== "unknown" ? tier : null;
      }
    
      function panelHTML(record, appid) {
        var rows = [];
        var mac = record.mac || {};
        var ac = record.antiCheatBadge || {};
        var c = record.community;
        rows.push(row(mac.state, "<b>Windows version:</b> " + esc(mac.reason), record.wiki && link(record.wiki.pageURL, "AppleGamingWiki")));
        var arch = record.macArchitectures;
        if (record.nativeBadge) {
          var play = record.nativeBadge.state !== "unsupported" && !playsInThisSteam()
            ? '<a class="sevo-compat-link sevo-compat-play" data-appid="' + esc(appid) + '">Play in Steam for Mac</a>' : "";
          rows.push(row(record.nativeBadge.state, "<b>macOS version:</b> " + esc(record.nativeBadge.reason), play));
        } else if (arch && arch.intel32 === true && arch.intel64 !== true && arch.arm !== true) {
          rows.push(row("unsupported", "<b>macOS version:</b> 32-bit only, which no Apple silicon Mac can run. The Windows version is the one that plays here.", link(arch.pageURL, "PCGamingWiki")));
        }
        rows.push(row(ac.state, "<b>Anti-cheat:</b> " + esc(ac.reason), record.antiCheat && link(record.antiCheat.sourceURL, "AreWeAntiCheatYet")));
        if (record.antiCheat && record.antiCheat.notes) {
          record.antiCheat.notes.slice(0, 3).forEach(function (note) {
            rows.push('<div class="sevo-compat-note">' + esc(note) + "</div>");
          });
        }
        if (c) {
          var verdict = tierWord(c.verdict) ? c.verdict : "not rated yet";
          var fps = typeof c.medianFPS === "number" ? ", " + Math.round(c.medianFPS) + " fps median" : "";
          rows.push(row(null, "<b>Sevoflurane players:</b> " + esc(verdict) + " (" + Number(c.runs).toLocaleString() + " runs on " + (c.installs === 1 ? "1 Mac" : Number(c.installs).toLocaleString() + " Macs") + esc(fps) + ")", link(c.pageURL, "Game database")));
        }
        if (record.wiki) {
          var tiers = [];
          if (tierWord(record.wiki.native)) tiers.push("native Mac build " + record.wiki.native);
          if (tierWord(record.wiki.rosetta2)) tiers.push("Rosetta 2 " + record.wiki.rosetta2);
          if (tierWord(record.wiki.crossover)) tiers.push("CrossOver " + record.wiki.crossover);
          if (tierWord(record.wiki.wine)) tiers.push("Wine " + record.wiki.wine);
          if (tierWord(record.wiki.parallels)) tiers.push("Parallels " + record.wiki.parallels);
          if (tiers.length) rows.push(row(null, "<b>AppleGamingWiki:</b> " + esc(tiers.join(" · "))));
        }
        var deck = DECK[record.deckCategory];
        if (deck) rows.push(row(deck[0], "<b>Steam Deck:</b> " + deck[1] + " (Valve's own program)"));
        if (record.proton) {
          var p = record.proton;
          rows.push(row(null, "<b>Linux / Proton:</b> " + esc(p.tier) + " (" + Number(p.total).toLocaleString() + " reports, " + esc(p.confidence) + " confidence). A Linux measurement.", link(p.sourceURL, "ProtonDB")));
        }
        return rows.join("");
      }
    
      function row(state, html, trailing) {
        return '<div class="sevo-compat-row">' + (state ? glyph(state) : '<span class="sevo-compat-icon"></span>')
          + "<span>" + html + (trailing ? " " + trailing : "") + "</span></div>";
      }
    
      function link(url, text) {
        if (!url) return "";
        return '<a class="sevo-compat-link" data-href="' + esc(url) + '">' + esc(text) + " ↗</a>";
      }
    
      function cell(title, badge) {
        return '<div class="sevo-compat-title">' + esc(title) + "</div>"
          + '<div class="sevo-compat-label">' + glyph(badge.state) + "<span>" + esc(badge.label) + "</span></div>";
      }
    
      var SEP = '<span class="sevo-compat-sep"></span>';
    
      function render(strip, panel, appid, record) {
        var mac = record ? record.mac : { state: "unknown", label: "Checking…" };
        var ac = record ? record.antiCheatBadge : { state: "unknown", label: "Checking…" };
        var native = record && record.nativeBadge;
        /* With a macOS build beside it, each cell names the build it rates,
           so "Unknown" and "Native" read as two builds rather than one
           contradiction. */
        strip.innerHTML = (native ? cell("Windows version", mac) + SEP + cell("macOS version", native) : cell("Mac Compatibility", mac))
          + SEP + cell("Anti-Cheat", ac)
          + '<div class="sevo-compat-details" role="button" tabindex="0">' + (open[appid] ? "Hide" : "Details") + "</div>";
        if (record) {
          panel.innerHTML = panelHTML(record, appid);
          panel.hidden = !open[appid];
        } else {
          panel.hidden = true;
        }
      }
    
      var UNREACHABLE = {
        mac: { state: "unknown", label: "Unknown", reason: "The compatibility databases could not be reached." },
        antiCheatBadge: { state: "unknown", label: "Unknown", reason: "The compatibility databases could not be reached." }
      };
    
      /* Draws the record once it arrives, if the strip is still the one it
         was asked for. */
      function settle(strip, panel, appid, record) {
        if (record && record.mac) records[appid] = record;
        if (strip.isConnected && strip.dataset.appid === appid) render(strip, panel, appid, records[appid] || UNREACHABLE);
      }
    
      function onClick(event) {
        var target = event.target;
        var play = target.closest && target.closest(".sevo-compat-play");
        if (play) {
          event.preventDefault();
          playMac(play.getAttribute("data-appid"));
          return;
        }
        var anchor = target.closest && target.closest(".sevo-compat-link");
        if (anchor) {
          event.preventDefault();
          openExternal(anchor.getAttribute("data-href"));
          return;
        }
        var details = target.closest && target.closest(".sevo-compat-details");
        if (details) {
          var strip = document.getElementById(STRIP_ID);
          var panel = document.getElementById(PANEL_ID);
          if (!strip || !panel) return;
          var appid = strip.dataset.appid;
          open[appid] = !open[appid];
          if (records[appid]) render(strip, panel, appid, records[appid]);
        }
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
    
      /* A fresh slot holding an empty strip and a hidden panel. */
      function makeSlot(appid, extraClass) {
        var slot = document.createElement("div");
        slot.id = SLOT_ID;
        slot.className = "sevo-compat-slot" + (extraClass ? " " + extraClass : "");
        slot.dataset.appid = appid;
        var strip = document.createElement("div");
        strip.id = STRIP_ID;
        strip.className = "sevo-compat";
        strip.dataset.appid = appid;
        var panel = document.createElement("div");
        panel.id = PANEL_ID;
        panel.className = "sevo-compat-panel";
        panel.hidden = true;
        slot.appendChild(strip);
        slot.appendChild(panel);
        return slot;
      }
    
      var pending = 0;
      function schedule() {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; apply(); }, 150);
      }
    
    """

    /// The library page: the slot under the game page's tab bar, the record
    /// from the bridge.
    private static let library = """
      if (window.__sevoCompat) {
        window.__sevoCompat.enabled = true;
        window.__sevoCompat.apply();
        return "reapplied";
      }
    
      /* Steam's UI runs in the opener; this popup is where it renders. */
      var ctx = window.opener || window;
      var classes = null;
    
      /* The class module behind Steam's own strip, found by its semantic keys.
         Class-name modules are pure `e.exports = {…}` objects, so requiring
         one has no side effect; every other module is left alone. */
      function resolveClasses() {
        if (classes) return classes;
        var chunk = ctx.webpackChunksteamui;
        if (!chunk || typeof chunk.push !== "function") return null;
        var req = null;
        try { chunk.push([["sevo-compat-" + Date.now()], {}, function (r) { req = r; }]); } catch (e) { return null; }
        if (!req || !req.m) return null;
        for (var id in req.m) {
          var source = String(req.m[id]);
          if (source.length > 4000 || source.indexOf('DeckVerifiedInfo:"') === -1) continue;
          try {
            var exports = req(id);
            if (exports && exports.Container && exports.DeckVerifiedInfo) {
              classes = { container: exports.Container };
              return classes;
            }
          } catch (e) {}
        }
        return null;
      }
    
      function currentAppID() {
        try {
          var manager = ctx.MainWindowBrowserManager;
          var path = manager && manager.m_lastLocation && manager.m_lastLocation.pathname;
          var match = path && path.match(/^\\/library\\/app\\/(\\d+)/);
          return match ? match[1] : null;
        } catch (e) { return null; }
      }
    
      function overview(appid) {
        try { return ctx.appStore.GetAppOverviewByAppID(Number(appid)) || null; } catch (e) { return null; }
      }
    
      function openExternal(url) {
        try {
          window.webkit.messageHandlers.sevoWindow.postMessage({ fn: "__openExternalURL", args: [url] });
        } catch (e) {}
      }
    
      function playMac(appid) {
        try {
          window.webkit.messageHandlers.sevoWindow.postMessage({ fn: "__playMacBuild", args: [appid] });
        } catch (e) {}
      }
    
      /* The macOS build installs and plays through this Steam
         (``SteamNativeBuilds``), so Steam for Mac is the way to it only when the
         person turned that option on (``NativeSteam/isOffered``). */
      function playsInThisSteam() {
        if (window.__sevoSteamForMac === true) return false;
        try { return !!(ctx.__sevoNativeBuilds && ctx.__sevoNativeBuilds.enabled); } catch (e) { return false; }
      }
    
      function load(appid, strip, panel) {
        if (records[appid]) { render(strip, panel, appid, records[appid]); return; }
        var o = overview(appid);
        var name = (o && o.display_name) || "";
        var deck = o && typeof o.steam_deck_compat_category === "number" ? o.steam_deck_compat_category : "";
        var url = "/__compat/" + appid + "?name=" + encodeURIComponent(name) + "&deck=" + deck;
        fetch(url, { cache: "no-store" })
          .then(function (response) { return response.ok ? response.json() : null; })
          .then(function (record) { settle(strip, panel, appid, record); })
          .catch(function () { settle(strip, panel, appid, null); });
      }
    
      /* Steam's own slot is inside the game-info block, which the desktop
         page keeps collapsed behind its (i) button — a strip there would be
         invisible until someone opened it. The strip goes right under the
         page's tab bar instead (Store Page · DLC · Community Hub …), the
         next sibling of that collapsed block, where it spans the page like
         the bar above it. The block itself is the fallback slot. */
      function placement() {
        var names = resolveClasses();
        var container = names && document.querySelector("." + names.container);
        if (!container) return null;
        var block = container.parentElement;
        var tabBar = block && block.nextElementSibling;
        return tabBar ? { after: tabBar } : { inside: container };
      }
    
      function placed(slot, where) {
        if (!slot) return false;
        if (where.after) return slot.previousElementSibling === where.after;
        return slot.parentElement === where.inside;
      }
    
      function apply() {
        var slot;
        if (window.__sevoCompat && !window.__sevoCompat.enabled) {
          slot = document.getElementById(SLOT_ID);
          if (slot) slot.remove();
          return;
        }
        if (!ensureStyle()) return;
        var appid = currentAppID();
        slot = document.getElementById(SLOT_ID);
        var where = appid && placement();
        var o = appid && overview(appid);
        /* Only games get a strip: shortcuts, mods, tools and soundtracks have
           no entry anywhere, and Steam skips its own strip for them too. */
        var eligible = where && o && !(o.BIsModOrShortcut && o.BIsModOrShortcut()) && o.app_type === 1;
        if (!eligible) {
          if (slot) slot.remove();
          return;
        }
        if (slot && slot.dataset.appid === appid && placed(slot, where)) return;
        if (slot) slot.remove();
        slot = makeSlot(appid);
        if (where.after) where.after.insertAdjacentElement("afterend", slot);
        else where.inside.appendChild(slot);
        var strip = slot.firstChild;
        var panel = slot.lastChild;
        render(strip, panel, appid, records[appid] || null);
        load(appid, strip, panel);
      }
    
      new MutationObserver(schedule).observe(document, { childList: true, subtree: true });
      document.addEventListener("click", onClick, true);
    
      window.__sevoCompat = { apply: apply, enabled: true };
      apply();
      return "installed";
    """

    /// The store page: the slot above Steam's Deck block, the record from
    /// the `sevoCompat` handler, drawn once it arrives. The handler answers
    /// `{"off": true}` while Settings has the strip off, which the page
    /// takes as the switch. DLC and soundtracks carry Steam's own bubbles and
    /// get no strip.
    private static let store = """
      if (location.hostname !== "store.steampowered.com") return "not the store";
      if (window.__sevoCompat) {
        window.__sevoCompat.enabled = true;
        window.__sevoCompat.apply();
        return "reapplied";
      }
    
      var asked = {};
    
      function handler() {
        try { return window.webkit.messageHandlers.\(storeHandler); } catch (e) { return null; }
      }
    
      function openExternal(url) {
        var h = handler();
        if (h) h.postMessage({ open: url });
      }
    
      function playMac(appid) {
        var h = handler();
        if (h) h.postMessage({ playMac: Number(appid) });
      }
    
      function playsInThisSteam() { return false; }
    
      function currentAppID() {
        var match = location.pathname.match(/^\\/app\\/(\\d+)/);
        return match ? match[1] : null;
      }
    
      function isGame() {
        return !document.querySelector(".game_area_dlc_bubble, .game_area_soundtrack_bubble");
      }
    
      function placement() {
        var deck = document.querySelector('[data-featuretarget="deck-verified-results"]');
        if (deck) return { before: deck };
        var purchase = document.getElementById("game_area_purchase");
        return purchase ? { before: purchase } : null;
      }
    
      function ask(appid) {
        var h = handler();
        if (!h || asked[appid]) return;
        asked[appid] = true;
        var title = document.getElementById("appHubAppName");
        h.postMessage({ appid: Number(appid), name: title ? title.textContent.trim() : "" })
          .then(function (json) {
            var record = json ? JSON.parse(json) : null;
            if (record && record.off) { window.__sevoCompat.enabled = false; delete asked[appid]; }
            else { records[appid] = record && record.mac ? record : UNREACHABLE; }
            apply();
          })
          .catch(function () { records[appid] = UNREACHABLE; apply(); });
      }
    
      function apply() {
        var slot = document.getElementById(SLOT_ID);
        if (!window.__sevoCompat.enabled) {
          if (slot) slot.remove();
          return;
        }
        if (!ensureStyle()) return;
        var appid = currentAppID();
        var where = appid && isGame() && placement();
        if (!where) {
          if (slot) slot.remove();
          return;
        }
        if (!records[appid]) { ask(appid); return; }
        if (slot && slot.dataset.appid === appid && slot.nextElementSibling === where.before) return;
        if (slot) slot.remove();
        slot = makeSlot(appid, "sevo-compat-store");
        where.before.insertAdjacentElement("beforebegin", slot);
        render(slot.firstChild, slot.lastChild, appid, records[appid]);
      }
    
      new MutationObserver(schedule).observe(document, { childList: true, subtree: true });
      document.addEventListener("click", onClick, true);
    
      window.__sevoCompat = { apply: apply, enabled: true };
      apply();
      return "installed";
    """

    /// Takes the strip off the page and stops the observer putting it back.
    /// The script itself stays installed, so turning the strip on again is
    /// one evaluation of ``script`` away.
    static let removalScript = """
    (function () {
      if (!window.__sevoCompat) { return "not installed"; }
      window.__sevoCompat.enabled = false;
      window.__sevoCompat.apply();
      return "removed";
    })()
    """
}
