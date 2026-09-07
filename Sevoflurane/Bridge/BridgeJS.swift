import Foundation

/// The JavaScript the bridge injects or evaluates. Fidelity rules: shape
/// mirroring, base64 envelopes carrying the view type, rejection objects
/// never stringified, callbacks routed per page.
nonisolated enum BridgeJS {
    /// SharedConnection — the protobuf transport the UI gets its real data
    /// from — passes ArrayBuffers, which JSON drops silently. Both sides
    /// translate binary to base64 envelopes instead.
    static let binaryCodec = #"""
    (() => {
      const b64 = (u8) => { let s = ''; for (let i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]); return btoa(s); };
      /* The view type travels with the bytes: Steam hands some callbacks a
         Uint8Array and rejects an ArrayBuffer in its place. */
      window.__sevoEnc = function (v) {
        if (v instanceof ArrayBuffer) return { __sevoBin: b64(new Uint8Array(v)), __sevoView: '' };
        if (ArrayBuffer.isView(v)) {
          return { __sevoBin: b64(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)),
                   __sevoView: v.constructor.name };
        }
        if (Array.isArray(v)) return v.map(window.__sevoEnc);
        /* Binary hides inside plain objects too (parental settings, and anything
           else that hands back a protobuf field alongside scalars). */
        if (v && typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype) {
          const out = {};
          for (const k of Object.keys(v)) out[k] = window.__sevoEnc(v[k]);
          return out;
        }
        return v;
      };
      window.__sevoDec = function (v) {
        if (v && typeof v === 'object' && typeof v.__sevoBin === 'string') {
          const s = atob(v.__sevoBin), u = new Uint8Array(s.length);
          for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
          if (!v.__sevoView) return u.buffer;
          const Ctor = window[v.__sevoView] || Uint8Array;
          return Ctor === Uint8Array ? u : new Ctor(u.buffer);
        }
        if (Array.isArray(v)) return v.map(window.__sevoDec);
        if (v && typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype) {
          const out = {};
          for (const k of Object.keys(v)) out[k] = window.__sevoDec(v[k]);
          return out;
        }
        return v;
      };
      return 'codec ready';
    })()
    """#

    /// Opens the relay socket from inside SharedJSContext. `%RELAY_PORT%` is
    /// substituted before evaluation.
    static let tunnel = #"""
    (() => {
      if (window.__sevoRelay && window.__sevoRelay.readyState <= 1) return 'relay live';
      /* The client's own context is the only one allowed to open a transport
         socket, but it can reach the bridge freely. Relaying frames over one
         socket it owns keeps the hot protobuf path off CDP entirely — driving it
         with an evaluate per frame wedges steamwebhelper. */
      const relay = new WebSocket('ws://127.0.0.1:%RELAY_PORT%');
      relay.binaryType = 'arraybuffer';
      window.__sevoRelay = relay;
      const socks = window.__sevoTunnels = {};
      const ctl = (o) => { if (relay.readyState === 1) relay.send(JSON.stringify(o)); };
      /* Frames are length-prefixed with their tunnel id so one relay socket can
         carry every tunnel without a JSON hop around the payload. */
      const frame = (id, buf) => {
        const idb = new TextEncoder().encode(id);
        const out = new Uint8Array(1 + idb.length + buf.byteLength);
        out[0] = idb.length;
        out.set(idb, 1);
        out.set(new Uint8Array(buf), 1 + idb.length);
        if (relay.readyState === 1) relay.send(out.buffer);
      };
      relay.onmessage = (e) => {
        if (typeof e.data === 'string') {
          const m = JSON.parse(e.data);
          if (m.cmd === 'ws_open') {
            let s;
            try { s = new WebSocket(m.url); }
            catch (err) { ctl({ type: 'ws_event', id: m.id, ev: 'close', code: 1006 }); return; }
            s.binaryType = 'arraybuffer';
            socks[m.id] = s;
            s.onopen = () => ctl({ type: 'ws_event', id: m.id, ev: 'open' });
            s.onerror = () => ctl({ type: 'ws_event', id: m.id, ev: 'error' });
            s.onclose = (ev) => {
              delete socks[m.id];
              ctl({ type: 'ws_event', id: m.id, ev: 'close', code: ev.code, reason: ev.reason });
            };
            s.onmessage = (ev) => {
              if (typeof ev.data === 'string') ctl({ type: 'ws_event', id: m.id, ev: 'message', text: ev.data });
              else frame(m.id, ev.data);
            };
          } else if (m.cmd === 'ws_close') {
            const s = socks[m.id];
            if (s) { try { s.close(m.code || 1000, m.reason || ''); } catch (err) {} }
          } else if (m.cmd === 'ws_send_text') {
            const s = socks[m.id];
            if (s && s.readyState === 1) s.send(m.text);
          }
          return;
        }
        const u = new Uint8Array(e.data);
        const id = new TextDecoder().decode(u.subarray(1, 1 + u[0]));
        const s = socks[id];
        if (s && s.readyState === 1) s.send(u.subarray(1 + u[0]).slice().buffer);
      };
      return 'relay opening';
    })()
    """#

    /// Shape snapshot of the real `SteamClient` (namespace tree, 1 = method).
    static let shape = #"""
    JSON.stringify((function walk(o, d) {
      const out = {};
      for (const k of Object.keys(o)) {
        let v; try { v = o[k]; } catch (e) { continue; }
        if (typeof v === 'function') out[k] = 1;
        else if (v && typeof v === 'object' && d > 0) out[k] = walk(v, d - 1);
      }
      return out;
    })(SteamClient, 3))
    """#

    /// Page commands answered by a one-line SteamClient call. `%ID%` is the
    /// integer appid.
    static let commands: [String: String] = [
        "launch": "SteamClient.Apps.RunGame(String(%ID%), '', -1, 100)",
        "terminate": "SteamClient.Apps.TerminateApp(String(%ID%), false)",
        "install": "SteamClient.Installs.OpenInstallWizard([%ID%])",
        "continue_install": "SteamClient.Installs.ContinueInstall()",
        "uninstall": "SteamClient.Installs.OpenUninstallWizard([%ID%], true)",
        "pause": "SteamClient.Downloads.PauseAppUpdate(%ID%)",
        "resume": "SteamClient.Downloads.ResumeAppUpdate(%ID%)",
        "queue_update": "SteamClient.Downloads.QueueAppUpdate(%ID%)",
    ]
}
