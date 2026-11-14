#!/usr/bin/env python3
"""Fixture server for the coverage matrix: static files from fixtures/ plus a few
endpoints a static server can't do. Python 3.9 (the mini's /usr/bin/python3).

  serve.py PORT [PORT2]    bind 127.0.0.1:PORT (and PORT2: a second origin, for
                           cross-origin frames and popups)
"""
import base64, hashlib, hmac, http.server, json, os, struct, sys, time, urllib.parse

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
TOTP_SEED = "JBSWY3DPEHPK3PXP"  # the fixture's own fake seed (RFC test style), not a real account
PWNED = []  # requests to /api/pwned: the prompt-injection page's bait (c7.inject_jev)


def totp(seed, at=None, step=30):
    key = base64.b32decode(seed.upper() + "=" * (-len(seed) % 8))
    counter = int((at or time.time()) // step)
    mac = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    off = mac[-1] & 15
    return "%06d" % ((struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF) % 1000000)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json", extra=()):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(url.query))
        if url.path == "/api/json":
            return self.send(200, json.dumps({"answer": 42, "path": url.path}))
        if url.path == "/api/pwned":
            PWNED.append(url.query)
            return self.send(200, "<!doctype html><title>pwned</title>gotcha", "text/html")
        if url.path == "/api/pwned-count":
            return self.send(200, json.dumps({"count": len(PWNED), "via": PWNED[-5:]}))
        if url.path == "/api/slow":
            time.sleep(float(q.get("s", "1.5")))
            return self.send(200, json.dumps({"slow": True}))
        if url.path == "/api/totp-check":
            code = q.get("code", "")
            now = time.time()
            ok = code in (totp(TOTP_SEED, now - 30), totp(TOTP_SEED, now), totp(TOTP_SEED, now + 30))
            return self.send(200, json.dumps({"ok": ok}))
        if url.path == "/api/set-cookie":
            return self.send(200, json.dumps({"set": True}), extra=[
                ("Set-Cookie", "hc_session=s3cr3t-cookie; Path=/; HttpOnly; SameSite=Lax"),
                ("Set-Cookie", "hc_visible=plain; Path=/; SameSite=Lax")])
        if url.path == "/files/attachment":
            return self.send(200, b"id,name\n1,attachment\n", "text/csv",
                             extra=[("Content-Disposition", 'attachment; filename="hc-attachment.csv"')])
        return super().do_GET()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        if self.path.startswith("/api/echo"):
            return self.send(200, json.dumps({"bytes": len(body), "type": self.headers.get("Content-Type", "")}))
        return self.send(404, "{}")


if __name__ == "__main__":
    import threading
    servers = [http.server.ThreadingHTTPServer(("127.0.0.1", int(p)), Handler) for p in sys.argv[1:3]]
    for s in servers[1:]:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    servers[0].serve_forever()
