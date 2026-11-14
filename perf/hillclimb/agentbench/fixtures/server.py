#!/usr/bin/env python3
"""Agentbench fixtures (frozen copies, so rounds compare on the same pages):
perf/uibench's app (uibench.html, from perf/uibench/server.py) and
jev-ultrafast's hotel fixture (hotel.html, jev_ultrafast/static/fixture.html @1231850).

    python3 server.py [--port 4161]

    GET  /app?task=login&sid=RUN      the uibench app, on one task's first screen
    GET  /fixture.html?scenario=travel   the hotel fixture (same path as upstream)
    POST /api/event                   {sid, task, type, ...} from the page
    GET  /api/result?sid=RUN          every event of that run, and whether it passed

Only the standard library; state is in memory and lost on exit.
"""

import argparse
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = {}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, kind="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path in ("/", "/app"):
            with open(os.path.join(HERE, "uibench.html"), "rb") as f:
                return self.send(200, f.read(), "text/html; charset=utf-8")
        if url.path == "/fixture.html":
            with open(os.path.join(HERE, "hotel.html"), "rb") as f:
                return self.send(200, f.read(), "text/html; charset=utf-8")
        if url.path == "/api/result":
            sid = (query.get("sid") or [""])[0]
            with LOCK:
                events = list(RUNS.get(sid, []))
            done = [e for e in events if e.get("type") == "done"]
            return self.send(200, {
                "sid": sid,
                "events": events,
                "done": bool(done),
                "ok": bool(done and done[-1].get("ok")),
                "wrong": sum(1 for e in events if e.get("type") == "wrong"),
                "detail": done[-1] if done else None,
            })
        if url.path == "/favicon.ico":
            return self.send(204, b"", "image/x-icon")
        return self.send(404, {"error": "not found"})

    def do_POST(self):
        if urlsplit(self.path).path != "/api/event":
            return self.send(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        try:
            event = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self.send(400, {"error": "bad json"})
        event["server_at"] = time.time()
        with LOCK:
            RUNS.setdefault(str(event.get("sid", "")), []).append(event)
        return self.send(200, {"ok": True})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4161)
    a = ap.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print(f"agentbench fixtures on http://127.0.0.1:{a.port}/app", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
