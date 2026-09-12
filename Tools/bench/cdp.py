#!/usr/bin/env python3
"""Minimal Chrome DevTools Protocol client, stdlib only.

    cdp.py targets                       # what CEF exposes on :8765
    cdp.py send <title-substring> <method> [json-params]
    cdp.py freeze <title-substring>      # Page.setWebLifecycleState frozen
    cdp.py thaw <title-substring>        # …active

Opens one session, sends one command, prints the reply, closes. For measuring
what a hidden page costs, not for driving the client in earnest.
"""
import base64, json, os, socket, struct, sys, urllib.error, urllib.request

PORT = int(os.environ.get("SEVO_CDP_PORT", "8765"))


def targets():
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=5) as r:
            return json.load(r)
    except (urllib.error.URLError, OSError) as e:
        raise SystemExit(f"no DevTools on :{PORT} ({e.reason if hasattr(e, 'reason') else e}) — is the client up?")


def ws_connect(url):
    # ws://127.0.0.1:8765/devtools/page/<id>
    _, rest = url.split("://", 1)
    hostport, path = rest.split("/", 1)
    host, port = hostport.split(":")
    s = socket.create_connection((host, int(port)), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise SystemExit("handshake failed")
        buf += chunk
    if b" 101 " not in buf.split(b"\r\n", 1)[0]:
        raise SystemExit("handshake refused: " + buf.split(b"\r\n", 1)[0].decode(errors="replace"))
    return s


def ws_send(s, text):
    data = text.encode()
    mask = os.urandom(4)
    head = bytearray([0x81])
    n = len(data)
    if n < 126:
        head.append(0x80 | n)
    elif n < 65536:
        head.append(0x80 | 126); head += struct.pack(">H", n)
    else:
        head.append(0x80 | 127); head += struct.pack(">Q", n)
    s.sendall(bytes(head) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def ws_recv(s):
    def read(n):
        out = b""
        while len(out) < n:
            c = s.recv(n - len(out))
            if not c:
                raise SystemExit("socket closed")
            out += c
        return out
    b0, b1 = read(2)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", read(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", read(8))[0]
    if b1 & 0x80:
        read(4)
    payload = read(n)
    if (b0 & 0x0F) == 0x8:
        raise SystemExit("closed by peer")
    return payload.decode(errors="replace")


def send(title_sub, method, params=None):
    t = [t for t in targets() if title_sub.lower() in (t.get("title") or "").lower()]
    if not t:
        raise SystemExit(f"no target titled like {title_sub!r}; have: " + ", ".join(x.get("title", "") for x in targets()))
    s = ws_connect(t[0]["webSocketDebuggerUrl"])
    ws_send(s, json.dumps({"id": 1, "method": method, "params": params or {}}))
    while True:
        msg = json.loads(ws_recv(s))
        if msg.get("id") == 1:
            s.close()
            return {"target": t[0]["title"], **msg}


def main():
    a = sys.argv[1:]
    if not a or a[0] == "targets":
        for t in targets():
            print(t.get("type"), "|", t.get("title"), "|", t.get("url", "")[:70])
        return
    if a[0] == "send":
        print(json.dumps(send(a[1], a[2], json.loads(a[3]) if len(a) > 3 else None)))
    elif a[0] == "freeze":
        print(json.dumps(send(a[1], "Page.setWebLifecycleState", {"state": "frozen"})))
    elif a[0] == "thaw":
        print(json.dumps(send(a[1], "Page.setWebLifecycleState", {"state": "active"})))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
