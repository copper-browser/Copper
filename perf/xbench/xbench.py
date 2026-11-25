#!/usr/bin/env python3
"""xbench: Copper against Safari, Chrome, Arc and Ardia on one Mac, measured from outside every browser.

Ardia's own cross-browser bench (apps/browser/scripts/perf/xbench.mjs in ardia-browser/ardia) drives its browsers
over CDP, so it can only measure Chromium. This one reads every browser the same way from the outside, so a WebKit
browser and a Chromium one get the same rulers:

  window      xbprobe polls CGWindowList about every 2 ms for the first window ≥ 300×200 on screen
  page        a local test page reports its own Navigation Timing (load event) and paint timing to this server
  memory      phys_footprint summed over every process of the instance (xbprobe procs: the app, its children,
              every process macOS holds the app responsible for (WebKit's XPC services), anything in its bundle)
  idle        CPU time, idle and interrupt wakeups and energy (proc_pid_rusage) over the same processes
  speed       Speedometer 3.1, served from this Mac, its score reported back by the page

Tabs are opened and closed through each browser's own door: the DevTools HTTP endpoint (Chrome, Arc, Ardia),
WebDriver (Safari, which can't run from a copy or a separate profile) and the bench socket (Copper's test world).

  xbench.py check   [--browsers a,b]                       one look at each browser: launch, 3 tabs, quit; nothing kept
  xbench.py template [--browsers a,b]                      make each browser's template profile (one tab, settled, quit)
  xbench.py run     --out DIR [--browsers a,b] [--rounds N] [--launches N] [--phases launch,session,speedometer]
                    [--quiet] [--settle] [--deadline MINS] resumable: finished items in DIR/samples.jsonl are skipped
  xbench.py report  --out DIR [--json FILE] [--md FILE]   medians (min–max, n) per row and browser
  xbench.py stop                                           end a running harness cleanly (browsers quit, lock released)

  --quiet   each round (browsers interleaved and rotated) queues for ~/hc/mini.lock like the Mac's other jobs, holds it
            for the whole round, and starts once the 1-minute load average is under 2; ~/hc/ardia-site-bench/PAUSE asks
            the token bench to hold its next run while the lock is held.

Runs on the Mac (python3, stdlib only). Copies of the browsers live in $XBENCH_APPS (default
~/hc/ardia-site-bench/apps-xb): copper/Copper.app, chrome/Google Chrome.app, arc/Arc.app, ardia/Ardia.app, used by
nothing else (an instance is found by its executable's path); Safari is the system's. Every browser runs as shipped, in a profile of its own (Copper: the test world "Copper (xbench)").
Method and results: perf/xbench/README.md.
"""
import argparse
import fcntl
import json
import os
import platform
import plistlib
import random
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HARNESS = 1
HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
BASE = os.environ.get("XBENCH_HOME", os.path.join(HOME, "hc/ardia-site-bench"))
APPS = os.environ.get("XBENCH_APPS", os.path.join(BASE, "apps-xb"))  # APFS clones of apps/: only this harness runs them
STATE = os.path.join(BASE, "state")
TOOLS = os.path.join(BASE, "tools")
PAUSE = os.path.join(BASE, "PAUSE")
LOCK = os.path.join(HOME, "hc/mini.lock")
SP3 = os.path.join(BASE, "speedometer")  # a checkout of WebKit/Speedometer at release/3.1
PAGE_PORT, CDP_PORT, WD_PORT = 4611, 4613, 4614
WORLD = "xbench"
SUPPORT = os.path.join(HOME, "Library/Application Support")
ORIGIN = f"http://127.0.0.1:{PAGE_PORT}"
RESTORE_URL = f"{ORIGIN}/p/restore"


def log(*a):
    print(f"[xbench {time.strftime('%H:%M:%S')}]", *a, file=sys.stderr, flush=True)


def now_ms():
    return time.time() * 1000


# ---------------------------------------------------------------- the test page and its server

def page_html(name):
    # Same shape as Ardia's native-bench static page: 60 boxes, 120 paragraphs, a 1 s timer, timing marks.
    boxes = "".join(f'<i style="--h:{i * 6}"></i>' for i in range(60))
    words = ("copper patina ember quiet tab space split window agent page paint frame idle wake memory "
             "launch restore link sidebar canvas folder pin history reader").split()
    paras = "".join("<p>" + " ".join(words[(i * 7 + j) % len(words)] for j in range(38)) + ".</p>" for i in range(120))
    script = """
(function(){
  var q = new URLSearchParams(location.search), id = q.get('id') || location.pathname, t0 = performance.timeOrigin;
  var frames = 0, ticks = 0, stopAt = performance.now() + 2000;
  function send(kind, o) {
    o = o || {}; o.id = id; o.kind = kind; o.vis = document.visibilityState; o.wall = t0 + performance.now();
    o.timeOrigin = t0; o.ua = navigator.userAgent; var body = JSON.stringify(o);
    try { if (navigator.sendBeacon('/beacon', body)) return; } catch (e) {}
    try { fetch('/beacon', {method: 'POST', body: body, keepalive: true}); } catch (e) {}
  }
  try {
    new PerformanceObserver(function (list) {
      list.getEntries().forEach(function (e) { if (e.name === 'first-contentful-paint') send('paint', {fcp: t0 + e.startTime}); });
    }).observe({type: 'paint', buffered: true});
  } catch (e) {}
  addEventListener('load', function () {
    setTimeout(function () {
      var n = performance.getEntriesByType('navigation')[0] || {};
      send('load', {load: t0 + (n.loadEventEnd || performance.now()), dcl: t0 + (n.domContentLoadedEventEnd || 0),
                    response: t0 + (n.responseEnd || 0), start: t0 + (n.startTime || 0)});
    }, 0);
  });
  document.addEventListener('visibilitychange', function () { send('vis', {}); });
  requestAnimationFrame(function raf() { frames++; if (performance.now() < stopAt) requestAnimationFrame(raf); });
  setInterval(function () { ticks++; document.getElementById('tick').textContent = ticks; }, 1000);
  setTimeout(function () { send('frames', {frames: frames, ticks: ticks}); }, 3000);
})();"""
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>xbench {name}</title>
<style>body{{font:15px/1.45 -apple-system,system-ui,sans-serif;margin:24px;color:#222;background:#fbfaf8}}
i{{display:inline-block;width:88px;height:56px;margin:4px;border-radius:8px;background:hsl(calc(var(--h)*1deg) 55% 72%)}}
p{{max-width:62em;margin:.6em 0}}</style></head>
<body><h1>xbench {name} <span id="tick">0</span></h1><div>{boxes}</div>{paras}<script>{script}</script></body></html>"""


SP3_HOOK = """<script>
(function () {
  function send(o) { try { navigator.sendBeacon('/beacon', JSON.stringify(o)); } catch (e) {} }
  var id = location.pathname.split('/')[2] || 'sp3';  // /sp3/<run id>/index.html
  addEventListener('load', function () {
    var c = window.benchmarkClient;
    if (!c) { send({id: id, kind: 'sp3', error: 'no benchmarkClient'}); return; }
    var done = c.didFinishLastIteration;
    c.didFinishLastIteration = function (metrics) {
      try { if (done) done.apply(c, arguments); } catch (e) {}
      var score = metrics && metrics.Score;
      send({id: id, kind: 'sp3', score: score && score.mean, delta: score && score.delta, vis: document.visibilityState,
            ua: navigator.userAgent});
    };
    send({id: id, kind: 'sp3-start', vis: document.visibilityState});
  });
})();
</script>"""


class Beacons:
    def __init__(self):
        self.items = []
        self.cv = threading.Condition()

    def add(self, item):
        with self.cv:
            self.items.append(item)
            self.cv.notify_all()

    def wait(self, pred, timeout):
        end = time.time() + timeout
        with self.cv:
            while True:
                for it in self.items:
                    if pred(it):
                        return it
                left = end - time.time()
                if left <= 0:
                    return None
                self.cv.wait(min(left, 1.0))

    def all(self, pred):
        with self.cv:
            return [it for it in self.items if pred(it)]


BEACONS = Beacons()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_body(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/p/"):
            return self.send_body(200, page_html(path[3:] or "page").encode(), "text/html; charset=utf-8")
        if path == "/blank":
            return self.send_body(200, b"<!doctype html><title>blank</title>", "text/html")
        if path.startswith("/sp3/"):
            # /sp3/<run id>/<file>: the run id rides in the path, where no driver can lose it (DevTools' /json/new
            # cuts a URL at its first &).
            rel = os.path.normpath(path[5:].partition("/")[2] or "index.html").lstrip("/")
            if rel.startswith(".."):
                return self.send_body(403, b"no", "text/plain")
            file = os.path.join(SP3, rel)
            if os.path.isdir(file):
                file = os.path.join(file, "index.html")
            if not os.path.isfile(file):
                return self.send_body(404, b"not found", "text/plain")
            body = open(file, "rb").read()
            ctype = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript",
                     ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png",
                     ".jpg": "image/jpeg", ".woff2": "font/woff2", ".wasm": "application/wasm"}.get(
                os.path.splitext(file)[1], "application/octet-stream")
            if rel in ("index.html", "."):
                body = body.replace(b"</head>", SP3_HOOK.encode() + b"</head>", 1)
            return self.send_body(200, body, ctype)
        self.send_body(404, b"not found", "text/plain")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if self.path.startswith("/beacon"):
            try:
                item = json.loads(raw or b"{}")
            except ValueError:
                item = {"bad": raw[:200].decode("utf-8", "replace")}
            item["rx"] = now_ms()
            BEACONS.add(item)
        self.send_body(204, b"", "text/plain")


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass  # a browser dropping a preconnect isn't news


def serve():
    server = Server(("127.0.0.1", PAGE_PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


# ---------------------------------------------------------------- xbprobe

def probe_bin():
    src = os.path.join(HERE, "xbprobe.swift")
    out = os.path.join(TOOLS, "xbprobe")
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
        os.makedirs(TOOLS, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", out, src], check=True)
    return out


def probe(*args, timeout=60):
    r = subprocess.run([probe_bin(), *map(str, args)], capture_output=True, text=True, timeout=timeout)
    return [json.loads(line) for line in r.stdout.splitlines() if line.strip()]


def windows_of(app):
    got = probe("windows", app)
    return got[0] if got else []


def real(path):
    return os.path.realpath(path)


# ---------------------------------------------------------------- browsers

def http(method, url, body=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    return json.loads(raw) if raw.strip() else {}


class Browser:
    key = name = engine = ""
    restores = True        # a plain launch restores the template's one tab
    links = True           # the link launch is measured
    speedometer = True     # its pages can draw on this Mac (Speedometer needs requestAnimationFrame)
    flags: list = []

    def __init__(self):
        self.pid = None
        self.handles = []

    # the bundle
    @property
    def app(self):
        return os.path.join(APPS, self.bundle)

    def info(self):
        with open(os.path.join(self.app, "Contents/Info.plist"), "rb") as f:
            return plistlib.load(f)

    def exe(self):
        return os.path.join(real(self.app), "Contents/MacOS", self.info()["CFBundleExecutable"])

    def version(self):
        i = self.info()
        return i.get("CFBundleShortVersionString", "?")

    # profile
    @property
    def dir(self):
        return os.path.join(STATE, self.key)

    @property
    def profile(self):
        return os.path.join(self.dir, "profile")

    @property
    def template(self):
        return os.path.join(self.dir, "template")

    def fresh(self):
        shutil.rmtree(self.profile, ignore_errors=True)
        if os.path.isdir(self.template):
            subprocess.run(["cp", "-cR", self.template, self.profile], check=True)
        else:
            os.makedirs(self.profile, exist_ok=True)

    def env(self):
        return {}

    def args(self):
        return list(self.flags)

    def open_cmd(self, url=None):
        cmd = ["open", "-n", "-g", "-a", self.app]
        for k, v in self.env().items():
            cmd += ["--env", f"{k}={v}"]
        if url:
            cmd.append(url)
        a = self.args()
        if a:
            cmd += ["--args", *a]
        return cmd

    def launch(self, url=None):
        t0 = now_ms()
        subprocess.run(self.open_cmd(url), check=True, timeout=60)
        return t0

    def find(self):
        exe = self.exe()
        for p in probe("find", self.app):
            if p["path"] == exe:
                return p["pid"]
        return None

    def wait_pid(self, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            pid = self.find()
            if pid:
                self.pid = pid
                return pid
            time.sleep(0.1)
        raise RuntimeError(f"{self.key}: no process after {timeout} s")

    def procs(self):
        return probe("procs", self.pid, self.app) if self.pid else []

    def running(self):
        return any(p["path"] == self.exe() for p in probe("find", self.app))

    def ask_quit(self, pid):
        # SIGTERM is a normal quit for Copper, Chrome and Ardia (each saves its session; the restore rows rely on it).
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    def quit(self, timeout=10):
        pid = self.pid or self.find()
        if pid:
            self.ask_quit(pid)
        end = time.time() + timeout
        while time.time() < end and self.find():
            time.sleep(0.25)
        left = self.find()
        if left:
            log(f"{self.key}: still running {timeout} s after a quit, SIGTERM {left}")
            try:
                os.kill(left, signal.SIGTERM)
            except ProcessLookupError:
                pass
            end = time.time() + 10
            while time.time() < end and self.find():
                time.sleep(0.25)
            left = self.find()
            if left:
                log(f"{self.key}: SIGKILL {left}")
                try:
                    os.kill(left, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                time.sleep(1)
        self.pid = None
        self.handles = []
        self.after_quit()

    def after_quit(self):
        pass

    # tabs: subclasses
    def ready(self, timeout=30):
        pass

    def new_tab(self, url):
        raise NotImplementedError

    def close_tab(self, handle):
        raise NotImplementedError

    def make_template(self):
        """One launch on the restore page, 60 s to settle, a clean quit: what every run starts from."""
        shutil.rmtree(self.template, ignore_errors=True)
        self.fresh()
        self.launch(RESTORE_URL + "?id=template")
        self.wait_pid()
        got = BEACONS.wait(lambda b: b.get("id") == "template" and b.get("kind") == "load", 60)
        log(f"{self.key}: template page {'loaded' if got else 'NOT loaded'}; settling 60 s")
        time.sleep(60)
        self.quit()
        os.makedirs(os.path.dirname(self.template), exist_ok=True)
        shutil.copytree(self.profile, self.template, symlinks=True)


class Chromium(Browser):
    engine = "Chromium"

    def make_template(self):
        """One launch, the restore page opened over DevTools in the main window (a link from another app would
        go to Little Ardia/Little Arc), every other page closed, 60 s to settle, a clean quit."""
        shutil.rmtree(self.template, ignore_errors=True)
        self.fresh()
        try:
            t0 = self.launch()
            self.wait_pid()
            self.ready()
            time.sleep(3)
            self.new_tab(RESTORE_URL + "?id=template")
            got = BEACONS.wait(lambda b: b.get("id") == "template" and b.get("kind") == "load" and b["rx"] >= t0, 60)
            for t in self.pages():
                if "id=template" not in t.get("url", ""):
                    self.close_tab(t["id"])
            log(f"{self.key}: template page {'loaded' if got else 'NOT loaded'}; pages {[t.get('url') for t in self.pages()]}; settling 60 s")
            time.sleep(60)
        finally:
            self.quit()
        self.shape_template()
        os.makedirs(os.path.dirname(self.template), exist_ok=True)
        shutil.copytree(self.profile, self.template, symlinks=True)

    def shape_template(self):
        pass

    def args(self):
        return [f"--user-data-dir={self.profile}/data", "--no-first-run", "--no-default-browser-check",
                "--password-store=basic", "--use-mock-keychain", f"--remote-debugging-port={CDP_PORT}",
                "--restore-last-session", "--window-size=1280,800", "--window-position=40,80"]

    def cdp(self, path, method="GET"):
        return http(method, f"http://127.0.0.1:{CDP_PORT}{path}")

    def ready(self, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            try:
                self.cdp("/json/version")
                return True
            except (OSError, ValueError, urllib.error.URLError):
                time.sleep(0.2)
        raise RuntimeError(f"{self.key}: no DevTools endpoint on {CDP_PORT}")

    def pages(self):
        return [t for t in self.cdp("/json/list") if t.get("type") == "page"]

    def new_tab(self, url):
        t = self.cdp("/json/new?" + urllib.parse.quote(url, safe=":/?=&"), "PUT")
        self.handles.append(t["id"])
        return t["id"]

    def close_tab(self, handle):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{CDP_PORT}/json/close/{handle}", timeout=10).read()
        except urllib.error.URLError:
            pass
        if handle in self.handles:
            self.handles.remove(handle)


class Chrome(Chromium):
    key, name, bundle = "chrome", "Google Chrome", "chrome/Google Chrome.app"


class Arc(Chromium):
    key, name, bundle = "arc", "Arc", "arc/Arc.app"

    def env(self):
        home = os.path.join(self.profile, "home")
        return {"HOME": home, "CFFIXED_USER_HOME": home}

    def args(self):
        return [f"--remote-debugging-port={CDP_PORT}", "--no-first-run", "--no-default-browser-check",
                "--use-mock-keychain", "--password-store=basic"]


class Ardia(Chromium):
    key, name, bundle = "ardia", "Ardia", "ardia/Ardia.app"

    def shape_template(self):
        """The restored window at 1280×800 like the others' (its frame lives in session.json and launch-layout.json)."""
        f = os.path.join(self.profile, "data/session.json")
        if os.path.exists(f):
            session = json.load(open(f))
            for w in session.get("windows") or []:
                if isinstance(w, dict) and isinstance(w.get("frame"), list) and len(w["frame"]) == 4:
                    w["frame"] = [w["frame"][0], w["frame"][1], 1280, 800]
            json.dump(session, open(f, "w"))
        f = os.path.join(self.profile, "data/launch-layout.json")
        if os.path.exists(f):
            layout = json.load(open(f))
            for w in (layout.get("windows") or {}).values():
                if isinstance(w, dict) and "size" in w:
                    w["size"] = [1280, 800]
            json.dump(layout, open(f, "w"))

    def env(self):
        home = os.path.join(self.profile, "home")
        return {"HOME": home, "CFFIXED_USER_HOME": home, "ARDIA_DATA_DIR": os.path.join(self.profile, "data"),
                "ARDIA_REMOTE_DEBUGGING_PORT": str(CDP_PORT)}

    def args(self):
        return []

    def fresh(self):
        super().fresh()
        os.makedirs(os.path.join(self.profile, "data"), exist_ok=True)
        os.makedirs(os.path.join(self.profile, "home"), exist_ok=True)
        onboarding = os.path.join(self.profile, "data/onboarding.json")
        if not os.path.exists(onboarding):
            json.dump({"version": 1, "completedAt": 1}, open(onboarding, "w"))


class Copper(Browser):
    key, name, bundle, engine = "copper", "Copper", "copper/Copper.app", "WebKit"
    domain = f"com.collinrijock.copper.test.{WORLD}"

    @property
    def world(self):
        return os.path.join(SUPPORT, f"Copper ({WORLD})")

    headless = False

    def env(self):
        # COPPER_MAIN_WORLD names this world as main, so a link to it is never relayed to the Mac's own Copper.
        # SEARCH_MEASURE: a test world "weighed and timed rather than driven" keeps what the shipped browser does
        # where test runs otherwise differ (hidden pages slowed as WebKit slows them, App Nap left to macOS).
        e = {"SEARCH_PROBE": WORLD, "COPPER_MAIN_WORLD": WORLD, "SEARCH_MEASURE": "1"}
        if self.headless:
            # The Mac's screen is locked, so macOS calls every window occluded and WebKit hides its pages (no
            # painting, no requestAnimationFrame) while Chrome and Ardia keep drawing theirs. Headless Copper's
            # web views ignore occlusion (docs/headless.md): its pages stay visible and draw like theirs.
            e.update({"SEARCH_HEADLESS": "1", "SEARCH_HEADLESS_SIZE": "1280x800"})
        return e

    def fresh(self):
        shutil.rmtree(self.world, ignore_errors=True)
        if os.path.isdir(self.template):
            subprocess.run(["cp", "-cR", self.template, self.world], check=True)
        for key, kind, value in [("welcomed", "-bool", "true"), ("bench", "-bool", "true")]:
            subprocess.run(["defaults", "write", self.domain, key, kind, value], check=True)

    def make_template(self):
        shutil.rmtree(self.template, ignore_errors=True)
        self.fresh()
        self.launch(RESTORE_URL + "?id=template")
        self.wait_pid()
        got = BEACONS.wait(lambda b: b.get("id") == "template" and b.get("kind") == "load", 60)
        self.ready()
        try:
            self.bench({"do": "resize", "width": 1280.0, "height": 800.0}, timeout=30)
        except OSError as e:
            log(f"copper: resize failed: {e}")
        log(f"copper: template page {'loaded' if got else 'NOT loaded'}; settling 60 s")
        time.sleep(60)
        self.quit()
        os.makedirs(self.dir, exist_ok=True)
        shutil.copytree(self.world, self.template, symlinks=True,
                        ignore=shutil.ignore_patterns("bench.sock", "instance.lock", "crashes"))

    def bench(self, request, timeout=60):
        path = os.path.join(self.world, "bench.sock")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(path)
            s.sendall((json.dumps(request) + "\n").encode())
            chunks = []
            while True:
                chunk = s.recv(1 << 16)
                if not chunk:
                    break
                chunks.append(chunk)
        line = b"".join(chunks).split(b"\n", 1)[0]
        return json.loads(line or b"{}")

    def ready(self, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            try:
                self.bench({"do": "probe"}, timeout=3)
                return True
            except OSError:
                time.sleep(0.2)
        raise RuntimeError("copper: no bench socket")

    def new_tab(self, url):
        r = self.bench({"do": "open", "url": url})
        handle = r.get("id") or r.get("tab") or r
        self.handles.append(handle)
        return handle

    def close_tab(self, handle):
        self.bench({"do": "close", "id": handle})
        if handle in self.handles:
            self.handles.remove(handle)


class Safari(Browser):
    """Safari can't run from a copy or a profile of its own, and the Mac's Safari profile is someone's (it syncs
    with iCloud). So its sessions run in a WebDriver automation session (a separate, private window set that
    leaves no history), and only the launch to a window (Start Page, no address) is timed with `open`."""
    key, name, engine = "safari", "Safari", "WebKit"
    restores = False
    links = False
    speedometer = False  # its pages are hidden on a locked screen, and a hidden page never gets a frame

    @property
    def app(self):
        return real("/Applications/Safari.app")

    def __init__(self):
        super().__init__()
        self.driver = None
        self.session = None

    def fresh(self):
        pass

    def args(self):
        return ["-ApplePersistenceIgnoreStateQuietly", "YES"]

    def wd(self, method, path, body=None, timeout=30):
        r = http(method, f"http://127.0.0.1:{WD_PORT}{path}", body, timeout=timeout)
        return r.get("value", r)

    def start_session(self):
        self.driver = subprocess.Popen(["safaridriver", "-p", str(WD_PORT)], stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
        end = time.time() + 20
        while time.time() < end:
            try:
                self.wd("GET", "/status")
                break
            except (OSError, urllib.error.URLError):
                time.sleep(0.2)
        t0 = now_ms()
        v = self.wd("POST", "/session", {"capabilities": {"alwaysMatch": {"browserName": "safari"}}}, timeout=90)
        self.session = v["sessionId"]
        self.wait_pid()
        try:
            self.wd("POST", f"/session/{self.session}/window/rect", {"x": 40, "y": 80, "width": 1280, "height": 800})
        except (OSError, urllib.error.URLError) as e:
            log(f"safari: window rect: {e}")
        return t0

    def ready(self, timeout=30):
        pass

    def new_tab(self, url):
        s = self.session
        if not self.handles:  # the session's own first window
            handle = self.wd("GET", f"/session/{s}/window")
        else:
            handle = self.wd("POST", f"/session/{s}/window/new", {"type": "tab"})["handle"]
            self.wd("POST", f"/session/{s}/window", {"handle": handle})
        self.wd("POST", f"/session/{s}/url", {"url": url}, timeout=60)
        self.handles.append(handle)
        return handle

    def close_tab(self, handle):
        s = self.session
        self.wd("POST", f"/session/{s}/window", {"handle": handle})
        self.wd("DELETE", f"/session/{s}/window")
        self.handles.remove(handle)
        if self.handles:
            self.wd("POST", f"/session/{s}/window", {"handle": self.handles[0]})

    def ask_quit(self, pid):
        subprocess.run([probe_bin(), "quit", str(pid)], capture_output=True, timeout=30)

    def quit(self, timeout=10):
        if self.session:
            try:
                self.wd("DELETE", f"/session/{self.session}", timeout=30)
            except (OSError, urllib.error.URLError):
                pass
            self.session = None
        super().quit(timeout)
        if self.driver:
            self.driver.terminate()
            self.driver = None


BROWSERS = {b.key: b for b in (Copper, Safari, Chrome, Arc, Ardia)}


# ---------------------------------------------------------------- measurements

def kind_of(p):
    """A process's kind, from its executable's name: the same buckets for WebKit and Chromium."""
    if p.get("why") == "main":
        return "browser"
    n = os.path.basename(p.get("path") or p.get("name") or "").lower()
    if "webcontent" in n or "renderer" in n:
        return "renderer"
    if "gpu" in n:
        return "gpu"
    if "network" in n:
        return "network"
    if "crashpad" in n:
        return "crashpad"
    if "helper (plugin)" in n or "extension" in n:
        return "extension"
    return "other"


def switches(pids):
    """Chromium helpers say what they are in --type= (and --utility-sub-type=)."""
    if not pids:
        return {}
    out = subprocess.run(["ps", "-o", "pid=,command=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        pid, _, cmd = line.strip().partition(" ")
        t = next((a.split("=", 1)[1] for a in cmd.split() if a.startswith("--type=")), None)
        sub = next((a.split("=", 1)[1] for a in cmd.split() if a.startswith("--utility-sub-type=")), "")
        if t and pid.isdigit():
            found[int(pid)] = {"renderer": "renderer", "gpu-process": "gpu", "crashpad-handler": "crashpad"}.get(
                t, "network" if "network" in sub.lower() else "storage" if "storage" in sub.lower() else "utility")
    return found


def usage(b):
    procs = b.procs()
    meta = {p["pid"]: p for p in procs}
    rows = probe("rusage", *meta) if meta else []
    typed = switches(list(meta)) if b.engine == "Chromium" else {}
    for r in rows:
        p = meta.get(r["pid"], {})
        r["kind"] = typed.get(r["pid"]) or kind_of(p)
        r["name"] = os.path.basename(p.get("path") or p.get("name") or "?")
    return rows


def footprint(b):
    rows = usage(b)
    kinds = {}
    for r in rows:
        kinds[r["kind"]] = kinds.get(r["kind"], 0) + r["footprint"] / 1e6
    return {"mb": round(sum(r["footprint"] for r in rows) / 1e6, 1), "processes": len(rows),
            "kinds": {k: round(v, 1) for k, v in sorted(kinds.items())}, "at": now_ms()}


def idle_window(b, secs):
    a = {u["pid"]: u for u in usage(b)}
    time.sleep(secs)
    after = usage(b)
    total = {"cpu": 0.0, "wakeups": 0.0, "mw": 0.0}
    kinds = {}
    for u in after:
        p = a.get(u["pid"])
        if not p:
            continue
        s = (u["at"] - p["at"]) / 1000
        cpu = (u["cpuNs"] - p["cpuNs"]) / 1e9 / s * 100
        wake = (u["idleWakeups"] + u["interruptWakeups"] - p["idleWakeups"] - p["interruptWakeups"]) / s
        mw = (u["energyNj"] - p["energyNj"]) / s / 1e6
        k = kinds.setdefault(u["kind"], {"cpu": 0.0, "wakeups": 0.0, "mw": 0.0, "count": 0})
        for key, v in (("cpu", cpu), ("wakeups", wake), ("mw", mw)):
            k[key] += v
            total[key] += v
        k["count"] += 1
    r = lambda d: {k: (round(v, 3) if isinstance(v, float) else v) for k, v in d.items()}
    return {"total": r(total), "kinds": {k: r(v) for k, v in kinds.items()}, "processes": len(after), "secs": secs}


def loaded(id_, since, timeout=30):
    return BEACONS.wait(lambda x: x.get("id") == id_ and x.get("kind") == "load" and x["rx"] >= since, timeout)


def restored(since, timeout=30):
    """The template's one tab (/p/restore?id=template) loading again after a launch."""
    return BEACONS.wait(lambda x: x.get("kind") == "load" and x["rx"] >= since and x.get("id") in ("template", "restore"), timeout)


def page_facts(id_, since=0):
    """What the page saw: visibility, frames in its first 2 s, first paint (if WebKit/Chromium painted it)."""
    got = BEACONS.all(lambda x: x.get("id") == id_ and x["rx"] >= since)
    paint = next((x["fcp"] for x in got if x.get("kind") == "paint"), None)
    frames = next((x for x in got if x.get("kind") == "frames"), None)
    vis = [x.get("vis") for x in got]
    return {"fcp": paint, "frames": frames and frames.get("frames"), "vis": vis[-1] if vis else None,
            "ua": got[0].get("ua") if got else None}


def latest_vis(id_, since):
    got = BEACONS.all(lambda x: x.get("id") == id_ and x["rx"] >= since and x.get("vis"))
    return got[-1]["vis"] if got else None


def clean_slate(b):
    if b.running():
        log(f"{b.key}: an instance is still running; quitting it")
        b.quit()


def launch_item(b, kind, tag):
    """kind restore: `open -a APP` → first window on screen, and → the restored tab's load event.
    kind link: `open -a APP URL` with the browser closed → first window, and → that page's load event."""
    clean_slate(b)
    b.fresh()
    poll = subprocess.Popen([probe_bin(), "waitwindow", "0", "30", b.app], stdout=subprocess.PIPE, text=True)
    time.sleep(0.3)
    url = f"{ORIGIN}/p/link?id={tag}" if kind == "link" else None
    try:
        t0 = b.launch(url)
        b.wait_pid()
        out, _ = poll.communicate(timeout=40)
        win = json.loads(out.strip().splitlines()[-1]) if out.strip() else {}
        r = {"window": round(win["at"] - t0, 1) if win.get("at") else None, "windowInfo": win.get("window")}
        if r["window"] is None:
            r["windowsSeen"] = windows_of(b.app)
        if kind == "link" or (kind == "restore" and b.restores):
            want = tag if kind == "link" else "restore"
            got = BEACONS.wait(lambda x: x.get("kind") == "load" and x["rx"] >= t0 and
                               (x.get("id") == want or (kind == "restore" and x.get("id") == "template")), 30)
            r["page"] = round(got["load"] - t0, 1) if got else None
            r["pageRx"] = round(got["rx"] - t0, 1) if got else None
            if got:
                time.sleep(3.5)
                facts = page_facts(got["id"], t0)
                r["fcp"] = round(facts["fcp"] - t0, 1) if facts["fcp"] else None
                r.update({"frames": facts["frames"], "vis": facts["vis"]})
                if got.get("wall") is not None:
                    r["skew"] = round(got["rx"] - got["wall"], 1)  # server clock minus page clock at the beacon
            # Did the launch also restore the template's tab (Copper and Ardia do by default; Chrome has the switch)?
            r["restoredToo"] = kind == "link" and bool(BEACONS.all(
                lambda x: x.get("kind") == "load" and x["rx"] >= t0 and x.get("id") in ("template", "restore")))
            if r.get("fcp") is None:
                raise RuntimeError(f"no paint reported (window {r['window']} ms)")
        if r["window"] is None:
            raise RuntimeError("no window seen")
        time.sleep(1)
        return r
    finally:
        if poll.poll() is None:
            poll.kill()
        b.quit()


def tab_url(i, tag):
    return f"{ORIGIN}/p/tab{i}?id={tag}-t{i}"


def open_tabs(b, start, count, tag):
    """Opens `count` tabs one after the other, each once the one before has loaded (≤ 15 s each)."""
    misses = 0
    for i in range(start, start + count):
        since = now_ms()
        b.new_tab(tab_url(i, tag))
        if not loaded(f"{tag}-t{i}", since, 15):
            misses += 1
    return misses


def session_item(b, tag, idle_s, settle):
    """One launch, then: 1 tab (30 s) → idle window → 10 tabs (+10 s) → 20 tabs (+15 s) → idle window
    [→ settled idle window 120 s after the last load] → back to 1 tab (+30 s). Memory at each step."""
    clean_slate(b)
    b.fresh()
    r = {"memory": {}, "idle": {}, "misses": 0}
    try:
        if isinstance(b, Safari):
            t0 = b.start_session()
            since = now_ms()
            b.new_tab(tab_url(0, tag))
            first = loaded(f"{tag}-t0", since, 30)
        else:
            t0 = b.launch()
            b.wait_pid()
            b.ready()
            first = restored(t0)
            if not first:  # nothing restored: open the first tab ourselves
                since = now_ms()
                b.new_tab(tab_url(0, tag))
                first = loaded(f"{tag}-t0", since, 30)
        if not first:
            raise RuntimeError("the first page never loaded")
        keep = set(b.handles)  # the first tab, if the harness opened it (Safari, or nothing restored)
        r["firstVis"] = first.get("vis")
        time.sleep(max(0, 30 - (now_ms() - t0) / 1000))
        r["memory"]["1"] = footprint(b)
        r["windows"] = [w for w in windows_of(b.app) if w.get("onscreen") and w.get("w", 0) >= 300]
        r["vis1"] = latest_vis(first["id"], t0)
        r["idle"]["1"] = idle_window(b, idle_s)
        if settle:
            time.sleep(max(0, 120 - (now_ms() - first["rx"]) / 1000))
            r["idle"]["1settled"] = idle_window(b, idle_s)
        r["misses"] += open_tabs(b, 1, 9, tag)
        time.sleep(10)
        r["memory"]["10"] = footprint(b)
        r["misses"] += open_tabs(b, 10, 10, tag)
        last = now_ms()
        time.sleep(15)
        r["memory"]["20"] = footprint(b)
        r["vis20"] = {"first": latest_vis(first["id"], t0), "last": latest_vis(f"{tag}-t19", t0),
                      "visible": sum(latest_vis(i, t0) == "visible" for i in [first["id"]] + [f"{tag}-t{k}" for k in range(1, 20)])}
        r["idle"]["20"] = idle_window(b, idle_s)
        if settle:
            time.sleep(max(0, 120 - (now_ms() - last) / 1000))
            r["idle"]["20settled"] = idle_window(b, idle_s)
        for h in list(b.handles):
            if h not in keep:
                b.close_tab(h)
        time.sleep(30)
        r["memory"]["closed"] = footprint(b)
        r["frames"] = page_facts(f"{tag}-t19").get("frames")
        if r["misses"]:
            raise RuntimeError(f"{r['misses']} tabs never loaded")
        return r
    finally:
        b.quit()


def visible_item(b, tag, idle_s):
    """Copper only: one tab, its page kept drawing (headless: web views ignore the locked screen's occlusion), so the
    1-tab memory and idle rows can be read against a page that draws, as Chrome's and Ardia's front tabs do."""
    clean_slate(b)
    b.headless = True
    b.fresh()
    r = {"memory": {}, "idle": {}}
    try:
        t0 = b.launch()
        b.wait_pid()
        b.ready()
        first = restored(t0)
        if not first:
            raise RuntimeError("the restored page never loaded")
        time.sleep(max(0, 30 - (now_ms() - t0) / 1000))
        r["memory"]["1"] = footprint(b)
        r["vis1"] = latest_vis(first["id"], t0)
        if r["vis1"] != "visible":
            raise RuntimeError(f"its page was {r['vis1']}, not visible")
        r["idle"]["1"] = idle_window(b, idle_s)
        return r
    finally:
        b.quit()


def speedometer_item(b, tag, timeout=900):
    """Speedometer 3.1 from this Mac's server, in a tab of a freshly launched browser; the score its page reports."""
    clean_slate(b)
    if isinstance(b, Copper):
        b.headless = True
    b.fresh()
    url = f"{ORIGIN}/sp3/{tag}/index.html?startAutomatically=true"
    try:
        if isinstance(b, Safari):
            b.start_session()
        else:
            t0 = b.launch()
            b.wait_pid()
            b.ready()
            restored(t0)
        since = now_ms()
        b.new_tab(url)
        start = BEACONS.wait(lambda x: x.get("id") == tag and x.get("kind") == "sp3-start" and x["rx"] >= since, 60)
        got = BEACONS.wait(lambda x: x.get("id") == tag and x.get("kind") == "sp3" and x["rx"] >= since, timeout)
        r = {"score": got and got.get("score"), "delta": got and got.get("delta"), "vis": (start or {}).get("vis"),
             "secs": round((now_ms() - since) / 1000, 1), "started": bool(start)}
        if not start or r["score"] is None or r["vis"] != "visible":
            raise RuntimeError(f"no score from a visible page ({r})")
        return r
    finally:
        b.quit()


# ---------------------------------------------------------------- the Mac, quiet

def load1():
    return os.getloadavg()[0]


def lock_until(fd, deadline):
    """A blocking exclusive flock on fd, given up at the deadline (SIGALRM interrupts the wait)."""
    def timeout(*a):
        raise TimeoutError

    old = signal.signal(signal.SIGALRM, timeout)
    signal.alarm(max(1, int(deadline - time.time())))
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        return True
    except TimeoutError:
        return False
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


class Quiet:
    """Holds ~/hc/mini.lock while the 1-minute load average is under 2 (the same lock every worker on the Mac
    takes for builds and measurements)."""

    def __init__(self, enabled, limit=2.0):
        self.enabled, self.limit, self.fd = enabled, limit, None

    def take(self, deadline):
        """Queues for the lock like every other job (a blocking flock: the others wait in `lockf`, which hands the lock
        to a waiter the moment it is let go, so polling for it would never win), then, holding it, asks the token
        bench to hold its next run (PAUSE) and waits up to 12 minutes for the 1-minute load average to fall under
        the limit. If it doesn't, the lock goes back for 2 minutes and the wait starts again."""
        if not self.enabled:
            return True
        while time.time() < deadline:
            fd = os.open(LOCK, os.O_RDONLY | os.O_CREAT, 0o644)
            log(f"queueing for the Mac's lock (load {load1():.2f})")
            if not lock_until(fd, deadline):
                os.close(fd)
                break
            self.fd = fd
            self.pause()
            settle_end = min(deadline, time.time() + 720)
            while time.time() < settle_end and load1() >= self.limit:
                time.sleep(10)
            if load1() < self.limit:
                return True
            log(f"lock held but load still {load1():.2f}; letting it go for 2 minutes")
            self.release()
            self.unpause()
            time.sleep(120)
        self.unpause()
        return False

    def pause(self):
        open(PAUSE, "w").write(f"xbench pid {os.getpid()} {time.strftime('%F %T')}\n")

    def unpause(self):
        if os.path.exists(PAUSE):
            os.remove(PAUSE)

    def conditions(self):
        try:
            d = (probe("display") or [{}])[0]
        except Exception:  # noqa: BLE001 - a reading, not a reason to fail the item
            d = {}
        return {"load1": round(load1(), 2), "locked": self.fd is not None,
                "displayAsleep": d.get("asleep"), "screenLocked": d.get("locked")}

    def release(self):
        # The token bench runs again while the next round queues (that can take an hour).
        if self.fd is not None:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
            os.close(self.fd)
            self.fd = None
            self.unpause()

    def done(self):
        self.release()
        if self.enabled:
            self.unpause()


# ---------------------------------------------------------------- runs

def machine():
    def sysctl(k):
        return subprocess.run(["sysctl", "-n", k], capture_output=True, text=True).stdout.strip()
    model = sysctl("hw.model")
    try:
        hw = json.loads(subprocess.run(["system_profiler", "SPHardwareDataType", "-json"], capture_output=True,
                                       text=True, timeout=60).stdout)["SPHardwareDataType"][0]
        model = f"{hw.get('machine_name', 'Mac')} ({model})"
    except (ValueError, KeyError, IndexError, subprocess.TimeoutExpired):
        pass
    chip = sysctl("machdep.cpu.brand_string")
    mac = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    build = subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip()
    return {"model": model, "chip": chip, "cores": int(sysctl("hw.ncpu") or 0),
            "ram": f"{round(int(sysctl('hw.memsize') or 0) / 2**30)} GB", "macOS": f"{mac} ({build})"}


def versions(names):
    out = {}
    for n in names:
        b = BROWSERS[n]()
        try:
            i = b.info()
        except Exception as e:  # noqa: BLE001 - the run goes on without it
            log(f"{n}: no version ({type(e).__name__}: {e})")
            i = {}
        out[n] = {"name": b.name, "engine": b.engine, "version": i.get("CFBundleShortVersionString"),
                  "build": i.get("CFBundleVersion")}
    return out


def plan(names, rounds, launches, phases):
    items = []
    for r in range(rounds):
        order = names[r % len(names):] + names[:r % len(names)]
        if "launch" in phases:
            for k in range(launches):
                for kind in ("restore", "link"):
                    for n in order:
                        if kind == "link" and not BROWSERS[n].links:
                            continue
                        items.append({"key": f"r{r}/{kind}{k}/{n}", "round": r, "phase": "launch", "kind": kind, "browser": n})
        if "session" in phases:
            for n in order:
                items.append({"key": f"r{r}/session/{n}", "round": r, "phase": "session", "kind": "session", "browser": n})
                if n == "copper":
                    items.append({"key": f"r{r}/visible/{n}", "round": r, "phase": "session", "kind": "visible", "browser": n})
        if "speedometer" in phases:
            for n in order:
                if not BROWSERS[n].speedometer:
                    continue
                items.append({"key": f"r{r}/speedometer/{n}", "round": r, "phase": "speedometer", "kind": "speedometer", "browser": n})
    return items


def read_samples(out):
    f = os.path.join(out, "samples.jsonl")
    if not os.path.exists(f):
        return []
    return [json.loads(l) for l in open(f) if l.strip()]


def run(args):
    names = args.browsers.split(",")
    os.makedirs(args.out, exist_ok=True)
    meta = os.path.join(args.out, "run.json")
    if not os.path.exists(meta):
        json.dump({"harness": HARNESS, "machine": machine(), "browsers": versions(names), "started": time.strftime("%F %T %z")},
                  open(meta, "w"), indent=1)
    done = {s["key"] for s in read_samples(args.out) if s.get("ok")}
    items = [i for i in plan(names, args.rounds, args.launches, args.phases.split(",")) if i["key"] not in done]
    log(f"{len(items)} items to run ({len(done)} done)")
    for n in list(names):
        b = BROWSERS[n]()
        if not isinstance(b, Safari) and not os.path.isdir(b.template):
            log(f"{n}: making its template")
            try:
                b.make_template()
            except Exception as e:  # noqa: BLE001 - the others still run
                log(f"{n}: template failed ({type(e).__name__}: {e}); leaving it out of this run")
                shutil.rmtree(b.template, ignore_errors=True)
                names.remove(n)
                items = [i for i in items if i["browser"] != n]
    deadline = time.time() + args.deadline * 60
    quiet = Quiet(args.quiet)
    group = None
    # Items that fail (an exception, or a value the row needs that never came) go round once more at the end.
    retry = [dict(i, retry=True) for i in items]
    items = items + retry
    try:
        for item in items:
            if item.get("retry"):
                if item["key"] in {x["key"] for x in read_samples(args.out) if x.get("ok")}:
                    continue
            if time.time() > deadline:
                log("deadline: stopping; run again to resume")
                break
            # One lock hold per interleaved round (all its launches, sessions and Speedometer runs, about 20 minutes).
            g = item["round"]
            if g != group:
                quiet.release()
                if not quiet.take(deadline):
                    log("no quiet Mac before the deadline; stopping")
                    break
                group = g
                log(f"round {item['round']}: {quiet.conditions()}")
            b = BROWSERS[item["browser"]]()
            tag = f"{item['key'].replace('/', '-')}-{int(time.time())}"
            sample = dict(item, at=time.strftime("%F %T"), version=b.version(), conditions=quiet.conditions())
            sample.pop("retry", None)
            started = time.time()
            try:
                if item["phase"] == "launch":
                    sample.update(launch_item(b, item["kind"], tag))
                elif item["kind"] == "visible":
                    sample.update(visible_item(b, tag, args.idle))
                elif item["phase"] == "session":
                    sample.update(session_item(b, tag, args.idle, args.settle))
                else:
                    sample.update(speedometer_item(b, tag))
                sample["ok"] = True
            except Exception as e:  # recorded and retried on the next run
                sample.update(ok=False, error=f"{type(e).__name__}: {e}")
                log(f"{item['key']}: {sample['error']}")
                try:
                    b.quit()
                except Exception:
                    pass
            sample["secs"] = round(time.time() - started, 1)
            sample["loadAfter"] = round(load1(), 2)
            with open(os.path.join(args.out, "samples.jsonl"), "a") as f:
                f.write(json.dumps(sample) + "\n")
            log(f"{item['key']}: {short(sample)}")
            time.sleep(3)
    finally:
        quiet.done()


def short(s):
    if not s.get("ok"):
        return "failed"
    if s["phase"] == "launch":
        return f"window {s.get('window')} ms, page {s.get('page')} ms (fcp {s.get('fcp')}, vis {s.get('vis')})"
    if s["phase"] == "session":
        m = s["memory"]
        return (f"memory {m.get('1', {}).get('mb')}/{m.get('10', {}).get('mb')}/{m.get('20', {}).get('mb')}/"
                f"{m.get('closed', {}).get('mb')} MB, idle cpu {s['idle'].get('1', {}).get('total', {}).get('cpu')}/"
                f"{s['idle'].get('20', {}).get('total', {}).get('cpu')} %, misses {s.get('misses')}")
    return f"score {s.get('score')} ({s.get('secs')} s, vis {s.get('vis')})"


def check(args):
    """A dry run: each browser launched once each way and one short session; prints everything, keeps nothing."""
    for n in args.browsers.split(","):
        b = BROWSERS[n]()
        log(f"== {n} {b.version()} ({b.app})")
        if not isinstance(b, Safari) and not os.path.isdir(b.template):
            b.make_template()
        for kind in ("restore", "link"):
            if kind == "link" and not b.links:
                continue
            try:
                log(f"{n} {kind}: {json.dumps(launch_item(b, kind, f'check-{n}-{kind}-{int(time.time())}'))}")
            except Exception as e:
                log(f"{n} {kind}: FAILED {type(e).__name__}: {e}")
                b.quit()
        try:
            clean_slate(b)
            b.fresh()
            tag = f"check-{n}-s-{int(time.time())}"
            if isinstance(b, Safari):
                b.start_session()
                b.new_tab(tab_url(0, tag))
            else:
                t0 = b.launch()
                b.wait_pid()
                b.ready()
                log(f"{n}: restored {bool(loaded('restore', t0, 20) or loaded('template', t0, 1))}")
            log(f"{n}: memory {json.dumps(footprint(b))}")
            log(f"{n}: opened 3 tabs, misses {open_tabs(b, 1, 3, tag)}; handles {b.handles}")
            time.sleep(3)
            log(f"{n}: memory {json.dumps(footprint(b))}")
            log(f"{n}: idle 10 s {json.dumps(idle_window(b, 10)['total'])}")
            log(f"{n}: page facts {json.dumps(page_facts(f'{tag}-t3'))}")
            log(f"{n}: windows {json.dumps(windows_of(b.app))}")
            for h in list(b.handles):
                if isinstance(b, Safari) and h == b.handles[0]:
                    continue
                b.close_tab(h)
            time.sleep(2)
            log(f"{n}: after closing {json.dumps(footprint(b))}")
        except Exception as e:
            log(f"{n} session: FAILED {type(e).__name__}: {e}")
        finally:
            b.quit()


# ---------------------------------------------------------------- report

ROWS = [
    # id, label, unit, lower is better, getter
    ("launch-window", "Cold launch → window on screen", "ms", True, "launch", lambda s: s.get("window") if s["kind"] == "restore" else None),
    ("launch-restore", "Cold launch → restored tab painted", "ms", True, "launch", lambda s: s.get("fcp") if s["kind"] == "restore" else None),
    ("launch-link", "Cold launch → page painted (link opened from another app)", "ms", True, "launch", lambda s: s.get("fcp") if s["kind"] == "link" else None),
    ("memory-1", "Memory, 1 tab", "MB", True, "session", lambda s: s["memory"].get("1", {}).get("mb")),
    ("memory-10", "Memory, 10 tabs", "MB", True, "session", lambda s: s["memory"].get("10", {}).get("mb")),
    ("memory-20", "Memory, 20 tabs", "MB", True, "session", lambda s: s["memory"].get("20", {}).get("mb")),
    ("memory-closed", "Memory, back to 1 tab after 20", "MB", True, "session", lambda s: s["memory"].get("closed", {}).get("mb")),
    ("idle-cpu-1", "Idle CPU, 1 tab", "%", True, "session", lambda s: s["idle"].get("1", {}).get("total", {}).get("cpu")),
    ("idle-cpu-20", "Idle CPU, 20 tabs", "%", True, "session", lambda s: s["idle"].get("20", {}).get("total", {}).get("cpu")),
    ("idle-wakeups-1", "Idle wakeups, 1 tab", "/s", True, "session", lambda s: s["idle"].get("1", {}).get("total", {}).get("wakeups")),
    ("idle-wakeups-20", "Idle wakeups, 20 tabs", "/s", True, "session", lambda s: s["idle"].get("20", {}).get("total", {}).get("wakeups")),
    ("idle-power-1", "Idle power, 1 tab", "mW", True, "session", lambda s: s["idle"].get("1", {}).get("total", {}).get("mw")),
    ("idle-power-20", "Idle power, 20 tabs", "mW", True, "session", lambda s: s["idle"].get("20", {}).get("total", {}).get("mw")),
    ("idle-cpu-1-steady", "Idle CPU, 1 tab, settled (2 min after load)", "%", True, "session", lambda s: s["idle"].get("1settled", {}).get("total", {}).get("cpu")),
    ("idle-cpu-20-steady", "Idle CPU, 20 tabs, settled (2 min after the last load)", "%", True, "session", lambda s: s["idle"].get("20settled", {}).get("total", {}).get("cpu")),
    ("idle-wakeups-1-steady", "Idle wakeups, 1 tab, settled", "/s", True, "session", lambda s: s["idle"].get("1settled", {}).get("total", {}).get("wakeups")),
    ("idle-wakeups-20-steady", "Idle wakeups, 20 tabs, settled", "/s", True, "session", lambda s: s["idle"].get("20settled", {}).get("total", {}).get("wakeups")),
    ("speedometer", "Speedometer 3.1", "points", False, "speedometer", lambda s: s.get("score")),
    ("memory-1-visible", "Memory, 1 tab, its page drawing", "MB", True, "visible", lambda s: s["memory"].get("1", {}).get("mb")),
    ("idle-cpu-1-visible", "Idle CPU, 1 tab, its page drawing", "%", True, "visible", lambda s: s["idle"].get("1", {}).get("total", {}).get("cpu")),
    ("idle-wakeups-1-visible", "Idle wakeups, 1 tab, its page drawing", "/s", True, "visible", lambda s: s["idle"].get("1", {}).get("total", {}).get("wakeups")),
    ("idle-power-1-visible", "Idle power, 1 tab, its page drawing", "mW", True, "visible", lambda s: s["idle"].get("1", {}).get("total", {}).get("mw")),
]


def stat(values):
    v = sorted(values)
    med = statistics.median(v)
    nd = lambda x: round(x, 0 if abs(x) >= 100 else 1 if abs(x) >= 1 else 2)
    return {"median": nd(med), "min": nd(v[0]), "max": nd(v[-1]), "n": len(v)}


def report(args):
    samples, meta = [], None
    for d in args.out:
        samples += [s for s in read_samples(d) if s.get("ok")]
        m = os.path.join(d, "run.json")
        if os.path.exists(m) and meta is None:
            meta = json.load(open(m))
    names = list(meta["browsers"]) if meta else sorted({s["browser"] for s in samples})
    rows = []
    for rid, label, unit, lower, phase, get in ROWS:
        cells, raw = {}, {}
        for n in names:
            vals = []
            for s in samples:
                kind = "visible" if s.get("kind") == "visible" else s["phase"]
                if s["browser"] != n or kind != phase:
                    continue
                try:
                    v = get(s)
                except (KeyError, TypeError, AttributeError):
                    v = None
                if isinstance(v, (int, float)):
                    vals.append(float(v))
            if vals:
                cells[n] = stat(vals)
                raw[n] = statistics.median(vals)
        if not cells:
            continue
        top = (min if lower else max)(raw.values())
        tied = [n for n in names if raw.get(n) == top]  # picked from unrounded medians, in no browser's favour
        row = {"id": rid, "label": label, "unit": unit, "lowerIsBetter": lower, "browsers": cells,
               "best": tied[0] if len(tied) == 1 else None}
        if len(tied) > 1:
            row["tie"] = tied
        rows.append(row)
    dates = sorted({s["at"][:10] for s in samples})
    out = {"date": dates[-1] if dates else None, "span": [dates[0], dates[-1]] if dates else None,
           "machine": meta and meta["machine"], "harness": HARNESS, "browsers": meta and meta["browsers"], "rows": rows,
           # quiet: samples whose phase began with the lock taken and the load under the limit (--quiet); with the
           # lock held the item's own browsers raise the load, so load1 is read as each item starts, after the last.
           "conditions": {"load1Median": round(statistics.median([s["conditions"]["load1"] for s in samples]), 2) if samples else None,
                          "samples": len(samples), "quiet": sum(1 for s in samples if s["conditions"].get("locked")),
                          "displayAsleep": sum(1 for s in samples if s["conditions"].get("displayAsleep")),
                          "screenUnlocked": sum(1 for s in samples if s["conditions"].get("screenLocked") is False)},
           "method": "perf/xbench/README.md"}
    if args.json:
        json.dump(out, open(args.json, "w"), indent=1)
        open(args.json, "a").write("\n")
    title = lambda n: f'{meta["browsers"][n]["name"]} {meta["browsers"][n]["version"]}' if meta else n
    md = ["| Row | " + " | ".join(title(n) for n in names) + " |",
          "|---|" + "---|" * len(names)]
    for r in rows:
        cells = []
        for n in names:
            c = r["browsers"].get(n)
            text = f"{c['median']:g} {r['unit']} ({c['min']:g}–{c['max']:g}, n={c['n']})" if c else "–"
            cells.append(f"**{text}**" if c and (n == r["best"] or n in r.get("tie", [])) else text)
        md.append(f"| {r['label']} | " + " | ".join(cells) + " |")
    text = "\n".join(md) + "\n"
    if args.md:
        open(args.md, "w").write(text)
    else:
        print(text)


def selftest():
    assert stat([3, 1, 2]) == {"median": 2.0, "min": 1.0, "max": 3.0, "n": 3}
    assert stat([150.4, 149.6]) == {"median": 150.0, "min": 150.0, "max": 150.0, "n": 2}
    with tempfile.TemporaryDirectory() as d:  # best from raw medians; an exact tie names no single best
        rows = []
        for k, (n, mb) in enumerate([("copper", 412.4), ("chrome", 411.6), ("safari", 300.0), ("ardia", 300.0)]):
            rows.append({"key": f"r0/session/{n}", "browser": n, "phase": "session", "kind": "session", "ok": True,
                         "at": "2026-11-25 10:00:00", "conditions": {"load1": 1.0, "locked": True},
                         "memory": {"1": {"mb": mb}, "10": {"mb": 500 + k}}, "idle": {}})
        open(os.path.join(d, "samples.jsonl"), "w").write("".join(json.dumps(r) + "\n" for r in rows))
        out = os.path.join(d, "bench.json")
        report(argparse.Namespace(out=[d], json=out, md=os.path.join(d, "t.md")))
        got = {r["id"]: r for r in json.load(open(out))["rows"]}
        assert got["memory-1"]["best"] is None and sorted(got["memory-1"]["tie"]) == ["ardia", "safari"], got["memory-1"]
        assert got["memory-10"]["best"] == "copper"
    assert kind_of({"why": "main"}) == "browser"
    assert kind_of({"path": "/x/com.apple.WebKit.WebContent"}) == "renderer"
    assert kind_of({"path": "/x/Google Chrome Helper (Renderer)"}) == "renderer"
    assert kind_of({"path": "/x/Google Chrome Helper (GPU)"}) == "gpu"
    assert kind_of({"path": "/x/com.apple.WebKit.Networking"}) == "network"
    p = plan(["copper", "safari", "chrome"], 2, 1, ["launch", "session"])
    assert [i["browser"] for i in p if i["kind"] == "session"] == ["copper", "safari", "chrome", "safari", "chrome", "copper"]
    assert not any(i["browser"] == "safari" and i["kind"] == "link" for i in p)
    assert [i["key"] for i in p if i["kind"] == "visible"] == ["r0/visible/copper", "r1/visible/copper"]
    assert not any(i["browser"] == "safari" for i in plan(["copper", "safari"], 1, 1, ["speedometer"]))
    with tempfile.NamedTemporaryFile() as f:  # two open files of one path: their flocks exclude each other
        a, b = os.open(f.name, os.O_RDONLY), os.open(f.name, os.O_RDONLY)
        fcntl.flock(a, fcntl.LOCK_EX)
        t = time.time()
        assert not lock_until(b, time.time() + 1.2) and time.time() - t >= 0.9
        fcntl.flock(a, fcntl.LOCK_UN)
        assert lock_until(b, time.time() + 5)
        os.close(a), os.close(b)
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["check", "template", "speedometer", "run", "report", "stop", "selftest"])
    ap.add_argument("--browsers", default="copper,safari,chrome,ardia")  # Arc wants an account at first launch
    ap.add_argument("--out", action="append", default=[])
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--launches", type=int, default=2)
    ap.add_argument("--phases", default="launch,session,speedometer")
    ap.add_argument("--idle", type=int, default=60)
    ap.add_argument("--settle", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--deadline", type=float, default=600)
    ap.add_argument("--json")
    ap.add_argument("--md")
    args = ap.parse_args()
    if args.command == "selftest":
        return selftest()
    if args.command == "report":
        return report(args)
    if args.command == "stop":
        # The harness that holds the page port: SIGTERM, which it turns into a clean exit (browsers quit, lock let go).
        pids = subprocess.run(["lsof", "-t", f"-iTCP:{PAGE_PORT}", "-sTCP:LISTEN"], capture_output=True, text=True).stdout.split()
        for p in pids:
            os.kill(int(p), signal.SIGTERM)
        return log(f"stopped {pids or 'nothing'}")
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(143))  # so every finally runs: browsers quit, lock released
    serve()
    if args.command == "check":
        return check(args)
    if args.command == "speedometer":
        for n in args.browsers.split(","):
            log(f"{n}: speedometer {json.dumps(speedometer_item(BROWSERS[n](), f'check-sp3-{n}-{int(time.time())}'))}")
        return
    if args.command == "template":
        for n in args.browsers.split(","):
            b = BROWSERS[n]()
            if not isinstance(b, Safari):
                b.make_template()
        return
    args.out = args.out[0]
    run(args)


if __name__ == "__main__":
    main()
