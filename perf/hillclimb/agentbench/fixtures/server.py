#!/usr/bin/env python3
"""Agentbench fixtures (frozen copies, so rounds compare on the same pages):
perf/uibench's app (uibench.html, from perf/uibench/server.py) and
jev-ultrafast's hotel fixture (hotel.html, jev_ultrafast/static/fixture.html @1231850).

    python3 server.py [--port 4161]

    GET  /app?task=login&sid=RUN      the uibench app, on one task's first screen
    GET  /fixture.html?scenario=travel   the hotel fixture (same path as upstream)
    POST /api/event                   {sid, task, type, ...} from the page
    GET  /api/result?sid=RUN          every event of that run, and whether it passed
    GET  /probe/far                   a long article; its one "Annapurna" link is ~40 screens down (reach)
    GET  /probe/page?t=Title          the article a /probe/far link opens
    GET  /probe/shop                  a shop's search box; a search lands on /probe/human
    GET  /probe/human?q=…             a bot check with an "I am human" button (a click turns the title to "Thanks")

Only the standard library; state is in memory and lost on exit.
"""

import argparse
import html
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
        if url.path == "/probe/far":
            return self.send(200, far_page().encode(), "text/html; charset=utf-8")
        if url.path == "/probe/page":
            t = html.escape((query.get("t") or ["?"])[0])
            return self.send(200, f"<!doctype html><title>{t}</title><h1>{t}</h1><p>An article about {t}.</p>".encode(),
                             "text/html; charset=utf-8")
        if url.path == "/probe/shop":
            return self.send(200, SHOP.encode(), "text/html; charset=utf-8")
        if url.path == "/probe/human":
            return self.send(200, HUMAN.encode(), "text/html; charset=utf-8")
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


WORDS = ("river valley mountain trade route harbour market village temple bridge railway festival language "
         "monastery plateau glacier forest coast island province dynasty treaty").split()
PLACES = ["Lhasa", "Pokhara", "Thimphu", "Darjeeling", "Leh", "Gangtok", "Shimla", "Manali", "Lumbini", "Bhaktapur",
          "Patan", "Chitwan", "Namche Bazaar", "Lukla", "Jomsom", "Mustang", "Dolpo", "Kanchenjunga", "Makalu", "Lhotse"]


def far_page():
    """60 sections of filler with four links each; "Annapurna" only in section 52 (deterministic)."""
    out = ["<!doctype html><title>The Himalaya</title><h1>The Himalaya</h1>"]
    for i in range(60):
        links = [PLACES[(i * 4 + k) % len(PLACES)] for k in range(4)]
        if i == 52:
            links[2] = "Annapurna"
        text = " ".join(WORDS[(i + j) % len(WORDS)] for j in range(40))
        out.append(f"<h2>Section {i + 1}</h2><p>{text} " + ", ".join(
            f'<a href="/probe/page?t={t.replace(" ", "+")}">{t}</a>' for t in links) + f". {text}.</p><p>{text}. {text}.</p>")
    return "\n".join(out)


SHOP = """<!doctype html><title>Copper Shop</title><h1>Copper Shop</h1>
<form action="/probe/human" role="search"><input type="search" name="q" aria-label="Search the shop"><button>Search</button></form>
<p>Batteries, cables and chargers, delivered tomorrow.</p>
"""

HUMAN = """<!doctype html><title>Copper Shop</title><h1>Copper Shop</h1>
<p>Before you see your results, please confirm you are a person.</p>
<form onsubmit="event.preventDefault(); document.title = 'Thanks';
  document.body.insertAdjacentHTML('beforeend', '<h2>Results</h2><p><a href=/probe/page?t=Duracell+AA+Batteries>Duracell AA Batteries, 24 pack</a></p>')">
<button type="submit">I am human</button></form>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4161)
    a = ap.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print(f"agentbench fixtures on http://127.0.0.1:{a.port}/app", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
