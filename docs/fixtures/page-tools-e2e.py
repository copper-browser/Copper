#!/usr/bin/env python3
"""The agent's page tools tell the truth, end to end (Fork/MCP/Page.swift, Tools.swift).

November 2026 hill-climb (C4 page + JS, C8 ergonomics, C6 covered clicks):

  1. browser_evaluate awaits a Promise (async function, fetch), takes a bare
     expression, and a thrown error comes back as an error with its message
     (it was "Search.Tools.Page.Failure error 1"). `copper eval document.title` works.
  2. A click on a button under a cookie wall is an error naming the wall, and
     the wall gets no click; a hidden button is "not visible". A styled
     checkbox (the label on top of the input) and a button in a shadow root
     still click.
  3. browser_wait_for that runs out is an error, not "Waited".
  4. Console logs from page load are there for a tab the agent opened.
  5. browser_scroll with a row's ref scrolls the list around it.
  6. A full-page screenshot walks the page, so scroll-lazy content is drawn.
  7. Failures are errors: browser_groups without a name, fill_form with a
     field it can't fill, select_option with no match, back with no history.

Then per-call latency on a fixture page (snapshot, click, type, navigate;
p50 and p90 over --rounds calls each), for comparing builds.

A fresh SEARCH_PROBE world of the given build, headless, pages from a local
server: no network, no real Copper world touched. `--keep-going` reports
every check instead of stopping at the first failure (for an old build).

    ./build.sh && docs/fixtures/page-tools-e2e.py [--app build/Copper.app] [--port 4175] [--rounds 20] [--keep-going]
"""
import http.server
import json
import os
import re
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zlib

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
args = sys.argv[1:]


def opt(name, default):
    return args[args.index(name) + 1] if name in args else default


app = os.path.abspath(opt("--app", os.path.join(root, "build/Copper.app")))
port = int(opt("--port", "4175"))
rounds = int(opt("--rounds", "20"))
keep_going = "--keep-going" in args
assert port != 4123, "4123 is the installed Copper's"
binary = os.path.join(app, "Contents/MacOS/Copper")
world = f"pagetools-{os.getpid()}"
folder = os.path.expanduser(f"~/Library/Application Support/Copper ({world})")
domain = f"com.collinrijock.copper.test.{world}"
pages = tempfile.mkdtemp(prefix="page-tools-")
log = os.path.join(pages, "copper.log")
label = f"dev.copper.e2e.{world}"
plist = f"/tmp/{label}.plist"
proc = None
failures = []


def store_folders():
    # Store.probeStore: FNV-1a of the world's name in the store's identifier.
    h = 2166136261
    for byte in world.encode():
        h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
    kit = os.path.expanduser("~/Library/WebKit/com.collinrijock.copper.dev")
    stem = f"5E4C{h >> 16:04X}-{h & 0xFFFF:04X}"
    out = []
    for sub, name in (("WebsiteDataStore", stem), ("WebsiteDataStore", stem.lower()), ("WebExtensions", stem)):
        d = os.path.join(kit, sub)
        if os.path.isdir(d):
            out += [os.path.join(d, n) for n in os.listdir(d) if n.startswith(name)]
    return out


def cleanup():
    global proc
    if proc:
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{label}"], capture_output=True)
        for _ in range(40):
            if not health():
                break
            time.sleep(0.25)
    proc = None
    if os.path.exists(plist):
        os.remove(plist)
    subprocess.run(["defaults", "delete", domain], capture_output=True)
    shutil.rmtree(folder, ignore_errors=True)
    for d in store_folders():
        shutil.rmtree(d, ignore_errors=True)
    shutil.rmtree(pages, ignore_errors=True)


def check(ok, what, detail=""):
    print(("PASS " if ok else "FAIL ") + what + ("" if ok or not detail else f" — {detail}"))
    if not ok:
        failures.append(what)
        if not keep_going:
            if os.path.exists(log):
                print("".join(open(log, errors="replace").readlines()[-15:]))
            cleanup()
            sys.exit(1)


# --- the pages ----------------------------------------------------------------
PAGES = {
    "js.html": """<!doctype html><title>Page tools</title>
<script>console.log('pt-early-log at parse time')</script>
<h1>Page tools</h1><p id=late></p>
<button id=plain onclick="window.clicks=(window.clicks||0)+1">Plain</button>
<button id=gone style="display:none" onclick="window.gone=1">Hidden</button>
<input id=name placeholder="Your name">
<label class=styled style="position:relative;display:inline-block;padding:4px 4px 4px 24px">
  <input type=checkbox id=agree style="position:absolute;left:4px;top:6px;margin:0">
  <span style="position:absolute;left:0;top:0;width:22px;height:100%;background:#36c;z-index:1"></span>Agree</label>
<select id=size><option>Small</option><option>Large</option></select>
<div id=host></div>
<script>
document.getElementById('host').attachShadow({mode:'open'}).innerHTML='<button id=deep onclick="window.deep=1">Deep</button>';
setTimeout(function(){ document.getElementById('late').textContent='Report ready'; }, 800);
</script>""",
    "wall.html": """<!doctype html><title>Wall</title>
<style>#wall{position:fixed;inset:0;background:rgba(0,0,0,.5)}</style>
<h1>Store</h1><button id=buy onclick="window.bought=1" style="margin-top:200px">Add to cart</button>
<div id=wall onclick="window.walled=1"><p style="background:#fff">We use cookies.</p></div>""",
    "virtual.html": """<!doctype html><title>Virtual</title>
<div id=vp style="height:300px;overflow-y:auto;width:300px;position:relative"><div style="height:300000px"></div></div>
<script>
var vp=document.getElementById('vp');
function draw(){ vp.querySelectorAll('.row').forEach(function(r){ r.remove(); });
  var first=Math.floor(vp.scrollTop/30); for (var i=first;i<first+12;i++){ var d=document.createElement('div');
  d.className='row'; d.setAttribute('role','button'); d.style.cssText='position:absolute;height:30px;top:'+(i*30)+'px';
  d.textContent='Order #'+i; vp.appendChild(d); } }
vp.addEventListener('scroll', draw); draw();
</script>""",
    "long.html": """<!doctype html><title>Long</title><style>body{margin:0}.band{height:600px}
#lazy{height:500px;background:rgb(200,0,0)}#lazy.seen{background:rgb(0,170,0)}</style>
<div class=band style="background:#00c"></div><div class=band style="background:#555"></div>
<div class=band style="background:#777"></div><div class=band style="background:#999"></div>
<div id=lazy></div><div class=band style="background:#222"></div>
<script>new IntersectionObserver(function(es){ es.forEach(function(e){ if (e.isIntersecting) e.target.classList.add('seen'); }); }).observe(document.getElementById('lazy'));</script>""",
    "a.html": "<!doctype html><title>Page A</title><h1>A</h1><a href=b.html>to B</a>",
    "b.html": "<!doctype html><title>Page B</title><h1>B</h1><a href=a.html>to A</a>",
}
for name, body in PAGES.items():
    with open(os.path.join(pages, name), "w") as f:
        f.write(body)


class Pages(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=pages, **k)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/api/json"):
            data = b'{"answer": 42}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        super().do_GET()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"


# --- the world and MCP ----------------------------------------------------------
class Agent:
    def __init__(self):
        self.token = json.load(open(os.path.join(folder, "agent.json")))["token"]
        self.sid = None
        _, headers = self.post({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "page-tools-e2e", "version": "1"}}})
        self.sid = headers.get("Mcp-Session-Id")
        self.post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def post(self, body, timeout=40):
        h = {"Authorization": "Bearer " + self.token, "Content-Type": "application/json",
             "Accept": "application/json, text/event-stream"}
        if self.sid:
            h["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps(body).encode(), h)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data, headers = r.read().decode(), dict(r.headers)
        if data.startswith("event:") or data.startswith("data:"):
            data = "\n".join(l[5:] for l in data.splitlines() if l.startswith("data:"))
        return (json.loads(data) if data.strip() else {}), headers

    def call(self, tool, arguments):
        """(isError, text, images, ms)"""
        t0 = time.time()
        r, _ = self.post({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": arguments}})
        ms = (time.time() - t0) * 1000
        res = r.get("result") or {}
        content = res.get("content") or []
        text = "\n".join(c.get("text", "") for c in content if c.get("type") == "text")
        images = [c["data"] for c in content if c.get("type") == "image"]
        return bool(res.get("isError")), text, images, ms

    def open(self, page):
        _, text, _, _ = self.call("browser_tabs", {"action": "new", "url": f"{base}/{page}"})
        m = re.search(r"\{tab ([0-9a-zA-Z]+)\}", text)
        if not m:
            check(False, "browser_tabs new gives a tab id", text[:200])
        return m.group(1)

    def ev(self, tab, fn):
        return self.call("browser_evaluate", {"tab": tab, "function": fn})[1]


def health():
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1):
            return True
    except Exception:
        return False


def png_pixel(b64, x, y):
    """(r, g, b) of an 8-bit RGB/RGBA non-interlaced PNG."""
    import base64
    data = base64.b64decode(b64)
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", chunk[:10])
            assert depth == 8 and color in (2, 6), (depth, color)
            bpp = 4 if color == 6 else 3
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + n
    raw, stride, prev = zlib.decompress(idat), w * bpp, None
    for row in range(y + 1):
        f, line = raw[row * (stride + 1)], bytearray(raw[row * (stride + 1) + 1:(row + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i] if prev else 0
            c = prev[i - bpp] if prev and i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
    return tuple(prev[x * bpp:x * bpp + 3]), w, h


env = dict(os.environ, SEARCH_PROBE=world, SEARCH_HEADLESS="1", SEARCH_HEADLESS_SIZE="1280x860", SEARCH_MCP_PORT=str(port))
subprocess.run(["defaults", "write", domain, "welcomed", "-bool", "true"], check=False)
# A launchd job in the GUI session, so it works over ssh too; stopped by its label.
with open(plist, "w") as f:
    keys = "".join(f"<key>{k}</key><string>{env[k]}</string>" for k in ("SEARCH_PROBE", "SEARCH_HEADLESS", "SEARCH_HEADLESS_SIZE", "SEARCH_MCP_PORT"))
    f.write('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
            f'<key>Label</key><string>{label}</string><key>EnvironmentVariables</key><dict>{keys}</dict>'
            '<key>RunAtLoad</key><true/><key>KeepAlive</key><false/><key>LimitLoadToSessionType</key><string>Aqua</string>'
            f'<key>ProgramArguments</key><array><string>{binary}</string></array>'
            f'<key>StandardOutPath</key><string>{log}</string><key>StandardErrorPath</key><string>{log}</string></dict></plist>')
subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", plist], check=True)
proc = True
limit = time.time() + 60
while not (health() and os.path.exists(os.path.join(folder, "agent.json"))):
    if time.time() > limit:
        check(False, "probe world answers on its port", log)
    time.sleep(0.25)
print(f"  {app} · world {world} · port {port}")
agent = Agent()

try:
    # 1. evaluate
    tab = agent.open("js.html")
    err, text, _, _ = agent.call("browser_evaluate", {"tab": tab, "function": "async () => { await new Promise(r => setTimeout(r, 50)); return 6 * 7 }"})
    check(not err and text.strip() == "42", "evaluate awaits an async function", text[:120])
    err, text, _, _ = agent.call("browser_evaluate", {"tab": tab, "function": "() => fetch('/api/json').then(r => r.json()).then(j => j.answer)"})
    check(not err and text.strip() == "42", "evaluate awaits a fetch Promise", text[:120])
    err, text, _, _ = agent.call("browser_evaluate", {"tab": tab, "function": "() => { throw new Error('pt-boom-17') }"})
    check(err and "pt-boom-17" in text, "a thrown error is an error with its message", text[:160])
    err, text, _, _ = agent.call("browser_evaluate", {"tab": tab, "function": "document.title"})
    check(not err and text == "Page tools", "evaluate takes a bare expression", text[:120])
    err, text, _, _ = agent.call("browser_evaluate", {"tab": tab, "function": "() => ({ a: 1, b: [true, null] })"})
    check(not err and json.loads(text) == {"a": 1, "b": [True, None]}, "an object comes back as JSON", text[:120])
    cli = subprocess.run([binary, "--cli", "--tab", tab, "eval", "document.title"], env=env, capture_output=True, text=True, timeout=30)
    check(cli.returncode == 0 and "Page tools" in cli.stdout, "copper eval document.title", (cli.stderr or cli.stdout)[:160])
    snap = agent.call("browser_snapshot", {"tab": tab, "interactive": True})[1]
    ref = re.search(r'button "Plain" \[ref=(e\d+)\]', snap).group(1)
    err, text, _, _ = agent.call("browser_evaluate", {"tab": tab, "ref": ref, "function": "(el) => el.id"})
    check(not err and text == "plain", "evaluate with a ref gets the element", text[:120])

    # 2. clicks that check what they hit
    err, text, _, _ = agent.call("browser_click", {"tab": tab, "selector": "#plain"})
    check(not err and agent.ev(tab, "() => window.clicks || 0") == "1", "a plain click lands", text[:120])
    err, text, _, _ = agent.call("browser_click", {"tab": tab, "selector": "#gone"})
    check(err and "not visible" in text, "a hidden button is 'not visible'", text[:160])
    err, text, _, _ = agent.call("browser_click", {"tab": tab, "selector": "#agree"})
    check(not err and agent.ev(tab, "() => document.getElementById('agree').checked ? 'yes' : 'no'") == "yes", "a styled checkbox (label on top) still clicks", text[:160])
    snap = agent.call("browser_snapshot", {"tab": tab, "interactive": True})[1]
    deep = re.search(r'button "Deep" \[ref=(e\d+)\]', snap)
    err, text, _, _ = agent.call("browser_click", {"tab": tab, "ref": deep.group(1) if deep else "e999"})
    check(not err and agent.ev(tab, "() => window.deep || 0") == "1", "a button in a shadow root clicks", text[:160])
    wall = agent.open("wall.html")
    err, text, _, _ = agent.call("browser_click", {"tab": wall, "selector": "#buy"})
    state = agent.ev(wall, "() => JSON.stringify([window.bought || 0, window.walled || 0])")
    check(err and "covered by div#wall" in text and state == "[0,0]", "a click under a cookie wall says what covers it", f"{text[:160]} {state}")

    # 3. wait_for
    err, text, _, _ = agent.call("browser_wait_for", {"tab": tab, "text": "Report ready"})
    check(not err, "wait_for finds text that comes later", text[:120])
    t0 = time.time()
    err, text, _, _ = agent.call("browser_wait_for", {"tab": tab, "text": "never-on-this-page"})
    check(err and "Timed out" in text, "wait_for that runs out is an error", text[:160])

    # 4. load-time console
    err, text, _, _ = agent.call("browser_console_messages", {"tab": tab})
    check("pt-early-log" in text, "console logs from page load are kept", text[:160])

    # 5. scroll a list by a row's ref
    vt = agent.open("virtual.html")
    row = re.search(r'"Order #0" \[ref=(e\d+)\]', agent.call("browser_snapshot", {"tab": vt, "interactive": True})[1]).group(1)
    err, text, _, _ = agent.call("browser_scroll", {"tab": vt, "ref": row, "deltaY": 3000})
    check(not err and agent.ev(vt, "() => document.getElementById('vp').scrollTop") == "3000", "scroll by a row's ref scrolls its list", text[:120])

    # 6. full-page screenshot draws lazy content
    lt = agent.open("long.html")
    err, text, images, _ = agent.call("browser_take_screenshot", {"tab": lt, "fullPage": True})
    top = int(agent.ev(lt, "() => document.getElementById('lazy').offsetTop"))
    (r, g, b), w, h = png_pixel(images[0], 20, top + 250) if images else ((0, 0, 0), 0, 0)
    check(images and g > r, "a full-page screenshot draws scroll-lazy content", f"pixel {(r, g, b)} of {w}x{h}")

    # 7. failures are errors
    err, text, _, _ = agent.call("browser_groups", {"tab": tab, "action": "assign"})
    check(err, "browser_groups assign without a name is an error", text[:120])
    err, text, _, _ = agent.call("browser_fill_form", {"tab": tab, "fields": [{"name": "Name", "type": "textbox", "value": "x"}]})
    check(err, "fill_form with a field it can't fill is an error", text[:120])
    err, text, _, _ = agent.call("browser_select_option", {"tab": tab, "selector": "#size", "values": ["Huge"]})
    check(err, "select_option with no match is an error", text[:120])
    fresh = agent.open("a.html")
    err, text, _, _ = agent.call("browser_navigate_back", {"tab": fresh})
    check(err, "back with no history is an error", text[:120])

    # latency
    lat = agent.open("js.html")
    snap = agent.call("browser_snapshot", {"tab": lat, "interactive": True})[1]
    plain = re.search(r'button "Plain" \[ref=(e\d+)\]', snap).group(1)
    name = re.search(r'textbox "Your name" \[ref=(e\d+)\]', snap).group(1)
    times = {"snapshot": [], "click": [], "type": [], "navigate": []}
    for i in range(rounds):
        times["snapshot"].append(agent.call("browser_snapshot", {"tab": lat, "interactive": True})[3])
        times["click"].append(agent.call("browser_click", {"tab": lat, "ref": plain, "element": "Plain"})[3])
        times["type"].append(agent.call("browser_type", {"tab": lat, "ref": name, "text": f"run {i}", "element": "Your name"})[3])
    nav = agent.open("a.html")
    for i in range(rounds):
        times["navigate"].append(agent.call("browser_navigate", {"tab": nav, "url": f"{base}/{'b' if i % 2 == 0 else 'a'}.html"})[3])
    print("latency (ms, client round trip):")
    for k, v in times.items():
        v = sorted(v)
        print(f"  {k:9} p50 {statistics.median(v):6.0f}  p90 {v[int(len(v) * 0.9) - 1]:6.0f}  n={len(v)}")
finally:
    cleanup()
    server.shutdown()

print(f"{len(failures)} failed: {', '.join(failures)}" if failures else "all passed")
sys.exit(1 if failures else 0)
