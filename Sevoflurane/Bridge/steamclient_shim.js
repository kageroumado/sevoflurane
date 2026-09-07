/* Sevoflurane — window.SteamClient shim.
 *
 * Steam's UI bundle is renderer-agnostic: it parses and runs in WebKit with a
 * single missing global. This file supplies that global by forwarding every
 * call over a WebSocket to the bridge, which replays it against the real
 * client's SharedJSContext and streams results and callbacks back.
 *
 * Loaded before the deferred UI bundles, so SteamClient exists by the time the
 * app boots. Transport is a plain WebSocket, so the same file works unchanged
 * in a browser and in WKWebView.
 */
(function () {
  if (window.__sevoInstalled) return;
  window.__sevoInstalled = true;

  /* ---- page-error capture -------------------------------------------------
     The library's React error boundary swallows the stack behind the
     intermittent "undefined is not an object (evaluating 'e.removeEventListener')"
     crash — it shows only a reference id. Capture the real stack, and React's
     componentStack (which the boundary console.errors), and hand them to the
     app log so the next occurrence names the component. Bounded, deduped,
     never throws, always calls through. */
  (function () {
    var seen = {}, sent = 0, MAX = 40;
    function report(kind, detail) {
      try {
        if (sent >= MAX) return;
        var key = kind + "|" + (detail.message || "").slice(0, 120)
          + "|" + (detail.stack || "").slice(0, 80);
        if (seen[key]) return;
        seen[key] = 1; sent++;
        var h = window.webkit && window.webkit.messageHandlers
          && window.webkit.messageHandlers.sevoWindow;
        if (!h) return;
        detail.kind = kind;
        detail.at = String(location.href).slice(0, 200);
        h.postMessage({ fn: "__jsError", args: [JSON.stringify(detail).slice(0, 4000)] });
      } catch (e) {}
    }
    window.addEventListener("error", function (e) {
      try {
        var err = e && e.error;
        report("uncaught", {
          message: (e && e.message) || String(err),
          stack: (err && err.stack) || "",
          where: (e && e.filename ? e.filename + ":" + e.lineno + ":" + e.colno : ""),
        });
      } catch (x) {}
    }, true);
    window.addEventListener("unhandledrejection", function (e) {
      try {
        var r = e && e.reason;
        report("rejection", {
          message: (r && r.message) || String(r), stack: (r && r.stack) || "",
        });
      } catch (x) {}
    });
    var origError = console.error;
    console.error = function () {
      try {
        var text = Array.prototype.map.call(arguments, function (a) {
          if (a && a.stack) return String(a.stack);
          if (a && typeof a === "object") {
            try { return JSON.stringify(a).slice(0, 600); } catch (e) { return String(a); }
          }
          return String(a);
        }).join(" ");
        if (/removeEventListener|went wrong while displaying|Error Reference|componentStack|The above error/i
            .test(text)) {
          report("boundary", { message: text.slice(0, 3500) });
        }
      } catch (x) {}
      return origError.apply(this, arguments);
    };
  })();

  var WS_URL = "ws://127.0.0.1:%PAGE_PORT%";
  var seq = 0;
  var pending = new Map();   // request id  → {resolve, reject}
  var callbacks = new Map(); // callback id → local function
  var tunnels = new Map();   // tunnel id   → TunnelSocket
  var queue = [];            // sends issued before the socket opens
  var ws;

  /* Callback and tunnel ids must be unique across every page the bridge
     serves: they name a function in *this* page, and a bare counter would
     have two pages both claiming "cb7". */
  var PAGE_PREFIX = "p" + Math.floor(Math.random() * 1e9) + "_";

  function connect() {
    ws = new WebSocket(WS_URL);
    ws.onopen = function () {
      while (queue.length) ws.send(queue.shift());
    };
    ws.onmessage = function (ev) {
      var m = JSON.parse(ev.data);
      if (m.type === "sc_result") {
        var p = pending.get(m.id);
        if (!p) return;
        pending.delete(m.id);
        if (m.error !== undefined) {
          var err = dec(JSON.parse(m.error));
          p.reject(err && err.__sevoErr ? new Error(err.message) : err);
        }
        else p.resolve(m.value === undefined ? undefined : dec(JSON.parse(m.value)));
      } else if (m.type === "sc_callback") {
        var fn = callbacks.get(m.cb);
        if (!fn) return;
        // Callback arguments arrive as a live array inside the envelope, while
        // sc_result values arrive as a JSON string; the two paths differ.
        try { fn.fn.apply(null, dec(m.args)); }
        catch (e) {
          console.error("[sevo] callback " + m.cb + " " + fn.path + ": "
            + (e && e.message ? e.message : String(e)));
        }
      } else if (m.type === "ws_event") {
        var sock = tunnels.get(m.id);
        if (sock) sock.__event(m);
      } else if (m.type === "eval") {
        /* The bridge's /__eval endpoint: the one programmatic channel into
           this page's DOM and globals (Safari's Web Inspector is the manual
           one). Indirect eval so the expression runs at global scope. */
        Promise.resolve().then(function () { return (0, eval)(m.expr); }).then(
          function (v) {
            var out; try { out = JSON.stringify(v); } catch (e) { out = JSON.stringify(String(v)); }
            send({ cmd: "eval_result", id: m.id, ok: true, v: out });
          },
          function (e) {
            send({ cmd: "eval_result", id: m.id, ok: false,
                   v: JSON.stringify(String(e && e.message || e)) });
          });
      }
    };
    ws.onclose = function () { setTimeout(connect, 1000); };
  }
  connect();

  /* Steam passes binary as ArrayBuffers and as typed-array views; JSON drops
     both, so they cross the bridge as base64 envelopes that carry the view
     type — some callbacks reject an ArrayBuffer where a Uint8Array is due. */
  function enc(v) {
    if (v instanceof ArrayBuffer) return { __sevoBin: b64(new Uint8Array(v)), __sevoView: "" };
    if (ArrayBuffer.isView(v)) {
      return { __sevoBin: b64(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)),
               __sevoView: v.constructor.name };
    }
    if (Array.isArray(v)) return v.map(enc);
    if (v && typeof v === "object" && Object.getPrototypeOf(v) === Object.prototype) {
      var eo = {};
      Object.keys(v).forEach(function (k) { eo[k] = enc(v[k]); });
      return eo;
    }
    return v;
  }
  function dec(v) {
    if (v && typeof v === "object" && typeof v.__sevoBin === "string") {
      var s = atob(v.__sevoBin), u = new Uint8Array(s.length);
      for (var i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
      if (!v.__sevoView) return u.buffer;
      var Ctor = window[v.__sevoView] || Uint8Array;
      return Ctor === Uint8Array ? u : new Ctor(u.buffer);
    }
    if (Array.isArray(v)) return v.map(dec);
    if (v && typeof v === "object" && Object.getPrototypeOf(v) === Object.prototype) {
      var dobj = {};
      Object.keys(v).forEach(function (k) { dobj[k] = dec(v[k]); });
      return dobj;
    }
    return v;
  }
  function b64(u8) {
    var s = "";
    for (var i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]);
    return btoa(s);
  }

  function send(obj) {
    var s = JSON.stringify(obj);
    if (ws && ws.readyState === 1) ws.send(s); else queue.push(s);
  }

  /* Register* handlers return {unregister}, everything else returns a Promise.
     The distinction is by name — the same convention the real bindings use. */
  function isRegistration(path) {
    var leaf = path.slice(path.lastIndexOf(".") + 1);
    return leaf.indexOf("Register") === 0;
  }

  function call(path, args) {
    var id = ++seq;
    var wire = Array.prototype.map.call(args, function (a) {
      if (typeof a !== "function") return a;
      var cb = PAGE_PREFIX + "cb" + (++seq);
      callbacks.set(cb, { fn: a, path: path });
      return { __sevoCb: cb };
    }).map(function (a) {
      return (a && a.__sevoCb) ? a : enc(a);
    });
    send({ cmd: "sc", id: id, path: path, args: wire });
    return id;
  }

  /* Built from a shape snapshot of the real client (namespace tree, 1 = method)
     injected as window.__sevoShape. Mirroring the real shape matters: the
     desktop client lacks namespaces the Deck has (System.Audio, …) and the UI
     feature-detects them — a Proxy that answers every property would make it
     call methods that do not exist. */
  /* Calls the host answers itself instead of the bottle's client: OS-facing
     actions that would otherwise surface Wine UI (explorer.exe, a Wine
     browser). Only active inside the app — in a plain browser there is no
     message handler and the calls forward like any other. */
  var NATIVE_ROUTES = {
    "SteamClient.System.OpenLocalDirectoryInSystemExplorer": "__openLocalDirectory",
    "SteamClient.System.OpenInSystemBrowser": "__openExternalURL",
    "SteamClient.System.OpenFileDialog": "__openFileDialog",
    "SteamClient.Apps.BrowseScreenshotForApp": "__browseScreenshots",
    "SteamClient.Screenshots.ShowScreenshotsOnDisk": "__browseScreenshots",
    "SteamClient.Settings.OpenWindowsMicSettings": "__openSoundSettings",
  };

  /* Calls the host wants to *see*, which still reach the client. Steam's
     friends UI posts its unread-conversation count on every change, for the
     client's own tray badge; tapping it here is how the menu bar learns what
     is waiting without anything asking. */
  var NATIVE_TAPS = {
    "SteamClient.WebChat.SetNumChatsWithUnreadPriorityMessages": "__unreadChats",
  };

  /* Routes whose target is a path only the client knows: resolved here, where
     the API lives, and then opened through the directory route above. */
  var NATIVE_RESOLVERS = {
    "SteamClient.InstallFolder.BrowseFilesInFolder": function (args) {
      var index = args[0];
      return window.SteamClient.InstallFolder.GetInstallFolders()
        .then(function (folders) {
          var hit = (folders || []).filter(function (f) {
            return f.nFolderIndex === index;
          })[0] || (folders || [])[index];
          return hit && (hit.strFolderPath || hit.strDriveName);
        });
    },
  };
  function nativeTap(path, args) {
    var fn = NATIVE_TAPS[path];
    if (!fn) return;
    var handler = window.webkit && window.webkit.messageHandlers
      && window.webkit.messageHandlers.sevoWindow;
    if (!handler) return;
    try {
      handler.postMessage({ fn: fn, args: Array.prototype.slice.call(args) });
    } catch (e) {}
  }

  function nativeRoute(path, args) {
    var handler = window.webkit && window.webkit.messageHandlers
      && window.webkit.messageHandlers.sevoWindow;
    if (!handler) return null;
    var list = Array.prototype.slice.call(args);
    var fn = NATIVE_ROUTES[path];
    /* A route that answers `__sevoReject` is reporting the outcome the caller
       catches rather than a value it can use — a cancelled file dialog. */
    if (fn) {
      return handler.postMessage({ fn: fn, args: list }).then(function (value) {
        if (value && value.__sevoReject) return Promise.reject(value.__sevoReject);
        return value;
      });
    }
    var resolve = NATIVE_RESOLVERS[path];
    if (!resolve) return null;
    return Promise.resolve(resolve(list)).then(function (path_) {
      if (!path_) return null;
      return handler.postMessage({ fn: "__openLocalDirectory", args: [path_] });
    });
  }

  /* steam:// URLs the UI itself can handle. The client broadcasts RunSteamURL
     to *every* UI including its own hidden one, which then raises real Wine
     windows; dispatching to the handlers this page registered keeps the whole
     round trip local. Registration is still forwarded so client-originated
     broadcasts keep working. */
  var steamURLHandlers = [];
  window.__sevoRunSteamURL = function (url) {
    var rest = String(url).replace(/^steam:\/\//, "");
    var hit = 0;
    steamURLHandlers.forEach(function (h) {
      var c = String(h.command);
      if (rest === c || rest.indexOf(c + "/") === 0 || rest.indexOf(c + "?") === 0) {
        hit++;
        /* The client invokes these as cb(nCount, strSteamURL). */
        try { h.fn(1, String(url)); }
        catch (e) { console.error("[sevo] steam url handler " + c + ":", e); }
      }
    });
    return hit;
  };

  function mk(path, node) {
    var fn = function () {
      var routed = nativeRoute(path, arguments);
      if (routed) return routed;
      nativeTap(path, arguments);
      var entry;
      if (path === "SteamClient.URL.RegisterForRunSteamURL"
          && typeof arguments[1] === "function") {
        entry = { command: arguments[0], fn: arguments[1] };
        steamURLHandlers.push(entry);
      }
      var id = call(path, arguments);
      if (isRegistration(path)) {
        return {
          unregister: function () {
            if (entry) {
              var i = steamURLHandlers.indexOf(entry);
              if (i >= 0) steamURLHandlers.splice(i, 1);
            }
            send({ cmd: "sc_unregister", id: id });
          },
        };
      }
      return new Promise(function (resolve, reject) {
        pending.set(id, { resolve: resolve, reject: reject });
      });
    };
    /* A namespace is an object and a method is a function, exactly as in the
       real bindings: the UI's feature check (`library.js`, module 736) walks
       the path with `typeof === "object"` on every node before the leaf, and
       treats a function-shaped namespace as the whole feature being absent —
       get this wrong and the friends settings and friends list silently
       never open. */
    return new Proxy(node ? {} : fn, {
      get: function (t, prop) {
        if (typeof prop === "symbol" || prop === "then" || prop === "inspect") {
          return undefined;
        }
        var child = node ? node[prop] : undefined;
        if (child === undefined) return undefined;
        return mk(path + "." + String(prop), child === 1 ? null : child);
      },
      has: function (t, prop) { return !!(node && prop in node); },
      ownKeys: function () { return node ? Object.keys(node) : []; },
      getOwnPropertyDescriptor: function (t, prop) {
        if (node && prop in node) {
          return { enumerable: true, configurable: true, value: mk(path + "." + String(prop), node[prop] === 1 ? null : node[prop]) };
        }
        return undefined;
      },
    });
  }

  var forwarded = mk("SteamClient", window.__sevoShape || {});
  window.SteamClient = new Proxy({}, {
    get: function (t, prop) {
      if (typeof prop === "symbol" || prop === "then") return undefined;
      if (prop === "BrowserView") return browserViewNamespace;
      if (prop === "Browser") return browserNamespace(window);
      // This page is a window too. Forwarding its Window calls to the client
      // would drive the *bottle's* hidden context window instead of ours.
      if (prop === "Window" && nativeWindowHandler(window)) {
        return windowNamespace(window);
      }
      return forwarded[prop];
    },
    has: function (t, prop) { return prop === "BrowserView" || prop in forwarded; },
    ownKeys: function () {
      return Object.keys(window.__sevoShape || {}).concat(["BrowserView"]);
    },
    getOwnPropertyDescriptor: function () {
      return { enumerable: true, configurable: true };
    },
  });

  /* ---- transport socket tunnel -------------------------------------------
     The UI's own protobuf transport connects to ws://localhost:<port>/
     transportsocket/ on the client. That endpoint answers 403 to every
     connection from outside the bottle — the handshake is byte-identical, so
     the gate is the peer process, not a header. The only context allowed
     through is the client's own, which the bridge already drives, so the
     socket is opened there and its frames relayed here. */

  function TunnelSocket(url) {
    this.url = String(url);
    this.readyState = 0;              // CONNECTING
    this.binaryType = "arraybuffer";
    this.bufferedAmount = 0;
    this.extensions = "";
    this.protocol = "";
    this.onopen = this.onmessage = this.onclose = this.onerror = null;
    this.__id = PAGE_PREFIX + (++seq);
    this.__listeners = {};
    this.__outbox = [];               // sends issued before the far end opens
    tunnels.set(this.__id, this);
    send({ cmd: "ws_open", id: this.__id, url: this.url });
  }

  TunnelSocket.CONNECTING = 0;
  TunnelSocket.OPEN = 1;
  TunnelSocket.CLOSING = 2;
  TunnelSocket.CLOSED = 3;

  TunnelSocket.prototype.addEventListener = function (type, fn) {
    (this.__listeners[type] = this.__listeners[type] || []).push(fn);
  };
  TunnelSocket.prototype.removeEventListener = function (type, fn) {
    var l = this.__listeners[type];
    if (l) this.__listeners[type] = l.filter(function (f) { return f !== fn; });
  };

  TunnelSocket.prototype.__fire = function (type, ev) {
    ev.type = type;
    ev.target = ev.currentTarget = this;
    var h = this["on" + type];
    if (h) { try { h.call(this, ev); } catch (e) { console.error("[sevo] ws " + type, e); } }
    (this.__listeners[type] || []).forEach(function (f) {
      try { f.call(this, ev); } catch (e) { console.error("[sevo] ws " + type, e); }
    }, this);
  };

  TunnelSocket.prototype.__event = function (m) {
    if (m.ev === "open") {
      this.readyState = 1;
      var out = this.__outbox;
      this.__outbox = [];
      for (var i = 0; i < out.length; i++) this.send(out[i]);
      this.__fire("open", {});
    } else if (m.ev === "message") {
      var data;
      if (typeof m.text === "string") {
        data = m.text;
      } else {
        var s = atob(m.b64), u = new Uint8Array(s.length);
        for (var j = 0; j < s.length; j++) u[j] = s.charCodeAt(j);
        data = this.binaryType === "blob" ? new Blob([u]) : u.buffer;
      }
      this.__fire("message", { data: data });
    } else if (m.ev === "close") {
      this.readyState = 3;
      tunnels.delete(this.__id);
      this.__fire("close", { code: m.code || 1006, reason: m.reason || "",
                             wasClean: m.code === 1000 });
    } else if (m.ev === "error") {
      this.__fire("error", {});
    }
  };

  TunnelSocket.prototype.send = function (data) {
    if (this.readyState === 0) { this.__outbox.push(data); return; }
    if (this.readyState !== 1) {
      throw new DOMException("socket is not open", "InvalidStateError");
    }
    if (typeof data === "string") {
      send({ cmd: "ws_send", id: this.__id, text: data });
    } else {
      var u8 = data instanceof ArrayBuffer
        ? new Uint8Array(data)
        : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      send({ cmd: "ws_send", id: this.__id, b64: b64(u8) });
    }
  };

  TunnelSocket.prototype.close = function (code, reason) {
    if (this.readyState === 3) return;
    this.readyState = 2;
    send({ cmd: "ws_close", id: this.__id, code: code, reason: reason });
  };

  /* ---- popups -------------------------------------------------------------
     Steam renders its visible windows into popups it opens itself, and reaches
     back into each one as `popup.SteamClient.Window.*` — a binding CEF injects
     per browser window and a plain browser has no equivalent for. The popup is
     same-origin, so the opener installs one: the Window namespace acts on the
     popup itself, everything else forwards to the client like normal. */

  /* Hosted in Sevoflurane, every popup is a real NSWindow and its message
     handler is the binding CEF would have injected. The handler is looked up
     per call rather than captured: Steam rewrites each popup's document
     immediately after opening it, and a stale reference across that would
     silently stop moving the window. */
  function nativeWindowHandler(win) {
    try {
      return win.webkit && win.webkit.messageHandlers
        && win.webkit.messageHandlers.sevoWindow;
    } catch (e) { return null; }
  }

  function nativeWindowNamespace(win) {
    function send(fn, args) {
      var h = nativeWindowHandler(win);
      if (!h) return Promise.resolve(undefined);
      try {
        return h.postMessage({ fn: fn, args: Array.prototype.slice.call(args) });
      } catch (e) { return Promise.resolve(undefined); }
    }
    return new Proxy({}, {
      get: function (t, prop) {
        if (typeof prop === "symbol" || prop === "then") return undefined;
        var name = String(prop);
        if (name.indexOf("Register") === 0) {
          return function () { return { unregister: function () {} }; };
        }
        return function () { return send(name, arguments); };
      },
      has: function () { return true; },
    });
  }

  function windowNamespace(win) {
    if (nativeWindowHandler(win)) return nativeWindowNamespace(win);
    return browserWindowNamespace(win);
  }

  function browserWindowNamespace(win) {
    var local = {
      ShowWindow: function () { try { win.focus(); } catch (e) {} },
      BringToFront: function () { try { win.focus(); } catch (e) {} },
      HideWindow: function () { try { win.blur(); } catch (e) {} },
      Minimize: function () {},
      ToggleMaximize: function () {},
      ToggleFullScreen: function () {},
      Close: function () { try { win.close(); } catch (e) {} },
      MoveTo: function (x, y) { try { win.moveTo(x, y); } catch (e) {} },
      ResizeTo: function (w, h) { try { win.resizeTo(w, h); } catch (e) {} },
      SetMinSize: function () {},
      SetMaxSize: function () {},
      SetResizeGrip: function () {},
      IsWindowMinimized: function () { return false; },
      IsWindowMaximized: function () { return false; },
      GetWindowRestoreDetails: function () { return ""; },
      GetWindowDimensions: function () {
        return { x: win.screenX, y: win.screenY,
                 width: win.innerWidth, height: win.innerHeight };
      },
      FlashWindow: function () {},
      StopFlashWindow: function () {},
      SetWindowIcon: function () {},
      SetForegroundWindow: function () { try { win.focus(); } catch (e) {} },
    };
    return new Proxy({}, {
      get: function (t, prop) {
        if (typeof prop === "symbol" || prop === "then") return undefined;
        var name = String(prop);
        if (local[name]) {
          return function () {
            var r = local[name].apply(null, arguments);
            return Promise.resolve(r);
          };
        }
        if (name.indexOf("Register") === 0) {
          return function () { return { unregister: function () {} }; };
        }
        // Anything else is a window query we have no answer for; the client's
        // own answer would describe the wrong window, so it stays undefined.
        return function () { return Promise.resolve(undefined); };
      },
      has: function () { return true; },
    });
  }

  function popupSteamClient(win) {
    return new Proxy({}, {
      get: function (t, prop) {
        if (typeof prop === "symbol" || prop === "then") return undefined;
        if (prop === "Window") return windowNamespace(win);
        if (prop === "BrowserView") return browserViewNamespace;
        if (prop === "Browser") return browserNamespace(win);
        return window.SteamClient[prop];
      },
      has: function (t, prop) { return prop === "Window" || prop in window.SteamClient; },
    });
  }

  /* ---- browser views ------------------------------------------------------
     Steam embeds web content (store, community, friends) as BrowserViews:
     native child browsers the client positions over a placeholder in the
     window. The binding hands back a live object with an event emitter, which
     no amount of call forwarding can reproduce — a proxied call can only
     return a value. So a BrowserView is built here instead: inside the app it
     is a native child web view the host positions with the same bounds the UI
     already computes (an iframe cannot host the store or the community —
     both send X-Frame-Options: DENY); in a plain browser it stays an iframe. */
  var popupWindows = [];
  var nextBrowserViewId = 1;

  /* Every window gets a local, synchronous browser id. The UI builds
     BrowserView create-params from `SteamClient.Browser.GetBrowserID()` of the
     window that should host the view, and CEF answers that call with a plain
     number — a forwarded call's Promise serializes to garbage. */
  var browserIdWindows = { 1: window };
  var nextBrowserWindowId = 2;
  window.__sevoBrowserID = 1;

  function browserNamespace(win) {
    var real = forwarded.Browser;
    return new Proxy({}, {
      get: function (t, prop) {
        if (prop === "GetBrowserID") {
          return function () { return win.__sevoBrowserID || 1; };
        }
        return real[prop];
      },
      has: function (t, prop) { return prop === "GetBrowserID" || prop in real; },
    });
  }

  function makeBrowserView(params) {
    var host = null;
    var parentId = params && params.parentPopupBrowserID;
    if (typeof parentId === "number" && browserIdWindows[parentId]
        && browserIdWindows[parentId] !== window) {
      try { if (!browserIdWindows[parentId].closed) host = browserIdWindows[parentId]; }
      catch (e) {}
    }
    if (!host) {
      /* No usable parent, or the parent is the off-screen context page —
         either way the view the user is meant to see belongs on the desktop
         window. */
      host = popupWindows.filter(function (w) {
        try { return !w.closed && w.name.indexOf("SP Desktop") === 0; }
        catch (e) { return false; }
      }).pop() || popupWindows[popupWindows.length - 1] || window;
    }
    if (nativeWindowHandler(host)) return makeNativeBrowserView(params, host);
    return makeIframeBrowserView(params, host);
  }

  function makeNativeBrowserView(params, host) {
    var id = nextBrowserViewId++;
    function send(method, args) {
      /* The handler is re-resolved per call — see nativeWindowHandler. */
      var handler = nativeWindowHandler(host);
      if (!handler) return;
      handler.postMessage({ fn: "__bv", args: [id, method].concat(args || []) });
    }

    var listeners = {};
    var bounds = { x: 0, y: 0, width: 0, height: 0 };
    var history = { bCanGoBack: false, bCanGoForward: false };
    function fire(ev, args) {
      if (ev === "can-go-back-forward-changed" && args) {
        history = { bCanGoBack: !!args[0], bCanGoForward: !!args[1] };
      }
      (listeners[ev] || []).forEach(function (f) {
        try { f.apply(null, args || []); } catch (e) { console.error("[sevo] bv " + ev, e); }
      });
    }
    host.__sevoBV = host.__sevoBV || {};
    host.__sevoBV[id] = fire;
    send("create", [JSON.stringify(params || {})]);

    var view = {
      on: function (ev, fn) { (listeners[ev] = listeners[ev] || []).push(fn); },
      off: function (ev, fn) {
        listeners[ev] = (listeners[ev] || []).filter(function (f) { return f !== fn; });
      },
      LoadURL: function (url) { send("load", [String(url)]); },
      ReplaceURL: function (url) { send("load", [String(url)]); },
      Reload: function () { send("reload"); },
      GoBack: function () { send("back"); },
      GoForward: function () { send("forward"); },
      SetVisible: function (v) { send("visible", [!!v]); },
      SetBounds: function (x, y, w, h) {
        bounds = { x: x, y: y, width: w, height: h };
        send("bounds", [x, y, w, h]);
      },
      GetBounds: function () { return bounds; },
      SetFocus: function (f) { if (f) send("focus"); },
      CanGoBackward: function () { return history.bCanGoBack; },
      CanGoForward: function () { return history.bCanGoForward; },
      PostMessage: function (type, data) {
        send("postMessage", [String(type), JSON.stringify(data === undefined ? null : data)]);
        return true;
      },
      Destroy: function () {
        send("destroy");
        delete host.__sevoBV[id];
      },
      __params: params,
    };
    ["SetWindowStackingOrder", "AddGlass", "EnableSteamInput", "NotifyUserActivation",
     "SetTouchGesturesToCancel", "HandleContextMenuCommand", "SetSteamURLCallback",
     "SetShowContextMenuCallback", "SetBlockedProtocols", "Paste", "FindInPage",
     "StopFindInPage", "DialogResponse", "SetVRKeyboardVisibility", "AddHeader",
    ].forEach(function (name) { view[name] = function () {}; });
    return view;
  }

  function makeIframeBrowserView(params, host) {
    var doc = host.document;
    var frame = doc.createElement("iframe");
    frame.style.cssText = "position:absolute;border:0;display:none;z-index:1";
    frame.setAttribute("allow", "autoplay; clipboard-read; clipboard-write");
    doc.body.appendChild(frame);

    var listeners = {};
    var bounds = { x: 0, y: 0, width: 0, height: 0 };
    function fire(ev, args) {
      (listeners[ev] || []).forEach(function (f) {
        try { f.apply(null, args || []); } catch (e) { console.error("[sevo] bv " + ev, e); }
      });
    }
    frame.addEventListener("load", function () {
      fire("start-request", [frame.src]);
      fire("finished-request", [frame.src, frame.src]);
      fire("history-changed", [{ bCanGoBack: false, bCanGoForward: false }]);
    });

    var view = {
      on: function (ev, fn) { (listeners[ev] = listeners[ev] || []).push(fn); },
      off: function (ev, fn) {
        listeners[ev] = (listeners[ev] || []).filter(function (f) { return f !== fn; });
      },
      LoadURL: function (url) { frame.src = url; },
      ReplaceURL: function (url) { frame.src = url; },
      Reload: function () { frame.contentWindow && frame.contentWindow.location.reload(); },
      GoBack: function () { frame.contentWindow && frame.contentWindow.history.back(); },
      GoForward: function () { frame.contentWindow && frame.contentWindow.history.forward(); },
      SetVisible: function (v) { frame.style.display = v ? "block" : "none"; },
      SetBounds: function (x, y, w, h) {
        bounds = { x: x, y: y, width: w, height: h };
        frame.style.left = x + "px";
        frame.style.top = y + "px";
        frame.style.width = w + "px";
        frame.style.height = h + "px";
      },
      GetBounds: function () { return bounds; },
      SetFocus: function (f) { if (f) frame.focus(); },
      CanGoBackward: function () { return false; },
      CanGoForward: function () { return false; },
      PostMessage: function (type, data) {
        frame.contentWindow && frame.contentWindow.postMessage({ type: type, data: data }, "*");
      },
      Destroy: function () { frame.remove(); },
      __frame: frame,
      __params: params,
    };
    /* The rest of the surface is window-manager plumbing with no browser
       equivalent (stacking order, glass, Steam Input, VR keyboard); the UI
       calls them unconditionally, so they answer rather than throw. */
    ["SetWindowStackingOrder", "AddGlass", "EnableSteamInput", "NotifyUserActivation",
     "SetTouchGesturesToCancel", "HandleContextMenuCommand", "SetSteamURLCallback",
     "SetShowContextMenuCallback", "SetBlockedProtocols", "Paste", "FindInPage",
     "StopFindInPage", "DialogResponse", "SetVRKeyboardVisibility", "AddHeader",
    ].forEach(function (name) { view[name] = function () {}; });
    return view;
  }

  var browserViews = [];
  var browserViewNamespace = {
    Create: function (params) {
      var v = makeBrowserView(params || {});
      browserViews.push(v);
      return v;
    },
    CreatePopup: function (params) {
      var v = makeBrowserView(params || {});
      browserViews.push(v);
      return { strCreateURL: "about:blank", browserView: v };
    },
    Destroy: function (v) {
      if (v && v.Destroy) v.Destroy();
      browserViews = browserViews.filter(function (x) { return x !== v; });
    },
    PostMessageToParent: function (type, data) {
      try { window.parent.postMessage({ type: type, data: data }, "*"); } catch (e) {}
    },
    RegisterForMessageFromParent: function (fn) {
      var h = function (e) {
        if (e.data && e.data.type) fn(e.data.type, e.data.data);
      };
      window.addEventListener("message", h);
      return { unregister: function () { window.removeEventListener("message", h); } };
    },
  };

  var nativeOpen = window.open;
  window.open = function (url, name) {
    var win = nativeOpen.apply(window, arguments);
    if (win) {
      try {
        popupWindows.push(win);
        win.__sevoBrowserID = nextBrowserWindowId++;
        browserIdWindows[win.__sevoBrowserID] = win;
        /* A host that gives popups real windows cannot tell a context menu
           from the desktop window until it knows the name Steam opened it
           under, and the size limits ride along in the about:blank query
           rather than the window-features string. Both are sent through the
           popup's own handler, which identifies it without a handshake. */
        var handler = nativeWindowHandler(win);
        if (handler) {
          handler.postMessage({
            fn: "__adopt",
            args: [String(name || ""), String(url || "").split("?")[1] || ""],
          });
        }
        win.SteamClient = popupSteamClient(win);
        win.WebSocket = window.WebSocket;
        /* The client posts "popup-created" to each popup once its window
           exists, and the UI defers all rendering into the popup until it
           arrives. The listener is attached just after open() returns, so
           this waits a turn. */
        setTimeout(function () {
          try { win.postMessage("popup-created", "*"); } catch (e) {}
        }, 0);
        win.addEventListener("resize", function () {
          try { win.postMessage("window_resized", "*"); } catch (e) {}
        });
      } catch (e) {
        console.error("[sevo] popup injection failed", e);
      }
    }
    return win;
  };

  var NativeWebSocket = window.WebSocket;
  function SevoWebSocket(url, protocols) {
    if (String(url).indexOf("/transportsocket/") !== -1) return new TunnelSocket(url);
    return protocols === undefined
      ? new NativeWebSocket(url)
      : new NativeWebSocket(url, protocols);
  }
  SevoWebSocket.prototype = NativeWebSocket.prototype;
  ["CONNECTING", "OPEN", "CLOSING", "CLOSED"].forEach(function (k, i) {
    Object.defineProperty(SevoWebSocket, k, { value: i });
  });
  window.WebSocket = SevoWebSocket;
})();
