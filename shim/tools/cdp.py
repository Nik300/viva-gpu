#!/usr/bin/env python3 -I
"""Minimal Chrome DevTools Protocol client (stdlib only) for driving shim tests.
Usage: cdp.py [--port 9222] [--target N|url-substring] <Method> ['<json params>'] ...
  Each Method/params pair is sent in order on the same connection; results are printed as JSON.
  Shortcuts: eval '<js>'   -> Runtime.evaluate (returnByValue, awaitPromise)
             nav '<url>'   -> Page.navigate
             wait <sec>    -> sleep between commands
             shot <file>   -> Page.captureScreenshot saved as PNG
"""
import base64, json, os, socket, struct, sys, time, urllib.request

def targets(port):
    return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list"))

class WS:
    def __init__(self, url):
        host, path = url[len("ws://"):].split("/", 1)
        h, p = host.split(":")
        self.s = socket.create_connection((h, int(p)))
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /{path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf: buf += self.s.recv(4096)
        self.rest = buf.split(b"\r\n\r\n", 1)[1]
        self.id = 0
    def recvn(self, n):
        while len(self.rest) < n:
            d = self.s.recv(1 << 20)
            if not d: raise EOFError
            self.rest += d
        r, self.rest = self.rest[:n], self.rest[n:]
        return r
    def send(self, obj):
        data = json.dumps(obj).encode()
        mask = os.urandom(4)
        n = len(data)
        hdr = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536
                               else bytes([0x80 | 127]) + struct.pack(">Q", n))
        self.s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
    def recv(self):
        msg = b""
        while True:
            b0, b1 = self.recvn(2)
            n = b1 & 0x7f
            if n == 126: n = struct.unpack(">H", self.recvn(2))[0]
            elif n == 127: n = struct.unpack(">Q", self.recvn(8))[0]
            msg += self.recvn(n)
            if b0 & 0x80: return json.loads(msg)
    def call(self, method, params=None, timeout=60):
        self.id += 1
        self.send({"id": self.id, "method": method, "params": params or {}})
        self.s.settimeout(timeout)
        while True:
            m = self.recv()
            if m.get("id") == self.id: return m

def main(argv):
    port, target = 9222, "0"
    while argv and argv[0].startswith("--"):
        if argv[0] == "--port": port = int(argv[1])
        elif argv[0] == "--target": target = argv[1]
        argv = argv[2:]
    pages = [t for t in targets(port) if t["type"] == "page"]
    t = pages[int(target)] if target.isdigit() else next(p for p in pages if target in p["url"])
    ws = WS(t["webSocketDebuggerUrl"])
    i = 0
    while i < len(argv):
        m = argv[i]; i += 1
        if m == "wait": time.sleep(float(argv[i])); i += 1; continue
        if m == "eval":
            r = ws.call("Runtime.evaluate", {"expression": argv[i], "returnByValue": True, "awaitPromise": True, "userGesture": True}); i += 1
            v = r.get("result", {}).get("result", {})
            print(json.dumps(v.get("value", v), indent=1) if not isinstance(v.get("value"), str) else v["value"]); continue
        if m == "nav": r = ws.call("Page.navigate", {"url": argv[i]}); i += 1; print(json.dumps(r)); continue
        if m == "shot":
            r = ws.call("Page.captureScreenshot", {"format": "png"})
            open(argv[i], "wb").write(base64.b64decode(r["result"]["data"])); i += 1; print("saved"); continue
        params = json.loads(argv[i]) if i < len(argv) and argv[i].startswith("{") else {}
        if params: i += 1
        print(json.dumps(ws.call(m, params), indent=1)[:4000])

if __name__ == "__main__": main(sys.argv[1:])
