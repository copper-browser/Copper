#!/usr/bin/env python3
"""Idle memory: what stays loaded when nobody is looking (Fork: idle-memory), end to end.

November 2026 (hill-climb A4/A6): an idle Copper held 11 pages. Eight were
pins, which never unload (Fork/PinsAwake.swift); the rest were every other
space's landing page, warmed after launch and then kept for good (a Gmail
nobody went to held 980 MB all day). Now:

  1. A launch on space A warms only the space you were in last (B, from
     `spaces.last`), not C.
  2. The idle sweep weighs pages: over the footprint budget (`sleep.budget`,
     here 1 MB) B's warmed page goes too, though it is a space's own tab;
     the pin stays loaded.
  3. A space switch records the space left as the next launch's `spaces.last`.
  4. An agent's page hung backstage turns hidden once the agent has been
     quiet (`agents.quiet`, here 2 s), and visible again at its next call.

A fresh SEARCH_PROBE world of the development build, windowed (SpaceWarm
never runs headless), pages from a local server: no network, no real Copper
world touched.

    ./build.sh && docs/fixtures/idle-memory-e2e.py [--app build/Copper.app]
"""
import http.server, json, os, secrets, shutil, signal, socket, subprocess, sys, tempfile, threading, time, urllib.request

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
args = sys.argv[1:]
app = os.path.abspath(args[args.index("--app") + 1]) if "--app" in args else os.path.join(root, "build/Copper.app")
binary = os.path.join(app, "Contents/MacOS/Copper")
world = f"idlemem-{os.getpid()}"
folder = os.path.expanduser(f"~/Library/Application Support/Copper ({world})")
domain = f"com.collinrijock.copper.test.{world}"
pages = tempfile.mkdtemp(prefix="idle-memory-")
proc = None


def cleanup():
    global proc
    if proc and proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
    proc = None
    subprocess.run(["defaults", "delete", domain], capture_output=True)
    plist = os.path.expanduser(f"~/Library/Preferences/{domain}.plist")
    if os.path.exists(plist):
        os.remove(plist)
    shutil.rmtree(folder, ignore_errors=True)
    shutil.rmtree(pages, ignore_errors=True)


def fail(why):
    print(f"FAIL {why}")
    cleanup()
    sys.exit(1)


def ask(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(40)
        s.connect(os.path.join(folder, "bench.sock"))
        s.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while chunk := s.recv(1 << 16):
            data += chunk
    answer = json.loads(data.split(b"\n", 1)[0] or b"{}")
    if answer.get("error"):
        fail(f"{request}: {answer['error']}")
    return answer


def until(what, check, seconds=30):
    limit = time.time() + seconds
    while time.time() < limit:
        if value := check():
            return value
        time.sleep(0.25)
    fail(f"timed out waiting for {what}")


def loaded():
    """Title → short id of every tab with a page."""
    return {t["title"]: t["id"][:8].lower() for t in ask({"do": "heat"})["tabs"]}


def mcp(name, arguments):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}}).encode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", body, {
        "Authorization": f"Bearer {token}", "Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
    answer = json.load(urllib.request.urlopen(request, timeout=30))
    result = answer.get("result") or {}
    text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
    if result.get("isError") or "error" in answer:
        fail(f"{name}: {text or answer.get('error')}")
    return text


# --- pages and world -----------------------------------------------------------
for name in ("pin", "a", "b", "c", "agent"):
    with open(os.path.join(pages, f"{name}.html"), "w") as f:
        f.write(f"<!doctype html><title>Page {name}</title><h1>{name}</h1>")


class Quiet(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=pages, **k)

    def log_message(self, *a):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"
if not os.access(binary, os.X_OK):
    fail(f"no Copper executable at {binary} (./build.sh first)")

A, B, C = (f"{x * 8}-0000-4000-8000-00000000000{i}" for i, x in enumerate("ABC", 1))
os.makedirs(folder, exist_ok=True)
with open(os.path.join(folder, "session.json"), "w") as f:
    json.dump({"active": 0, "space": A,
               "spaces": [{"id": A, "name": "A", "hue": 0.1}, {"id": B, "name": "B", "hue": 0.4}, {"id": C, "name": "C", "hue": 0.7}],
               "pins": [{"url": f"{base}/pin.html", "title": "Page pin", "pin": "P", "space": A}],
               "tabs": [{"url": f"{base}/{x.lower()}.html", "title": f"Page {x.lower()}", "space": s, "saved": False, "active": True}
                        for x, s in (("A", A), ("B", B), ("C", C))]}, f)
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
token = secrets.token_hex(32)
with open(os.path.join(folder, "agent.json"), "w") as f:
    json.dump({"enabled": True, "port": port, "token": token, "announces": False, "jev": False}, f)
for key, kind, value in [("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("sidebar", "-bool", "true"),
                         ("spaces.last", "-string", B), ("sleep.budget", "-int", "1"), ("agents.quiet", "-float", "2")]:
    subprocess.run(["defaults", "write", domain, key, kind, value], check=True)

try:
    print("1. launch on A: only B (the last space) is warmed")
    proc = subprocess.Popen([binary], env=dict(os.environ, SEARCH_PROBE=world, SEARCH_MCP_PORT=str(port)),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    until("the bench", lambda: os.path.exists(os.path.join(folder, "bench.sock")) and ask({"do": "probe"}), 40)
    pages_now = until("B's page warmed", lambda: (lambda p: p if "Page b" in p and "Page pin" in p else None)(loaded()), 40)
    time.sleep(5)  # long enough for the old SpaceWarm to have gone on to C
    pages_now = loaded()
    print("   loaded:", sorted(pages_now))
    if "Page c" in pages_now:
        fail("C's page was warmed too — only the last space should be")

    print("2. over the footprint budget the sweep takes B's page, never the pin")
    chosen = ask({"do": "sleep", "id": "sweep", "seconds": 0.5})["chosen"]
    print("   chosen:", chosen)
    if pages_now["Page b"] not in chosen:
        fail(f"B's warmed page was not chosen over a 1 MB budget: {chosen}")
    if pages_now["Page pin"] in chosen:
        fail("the pin was chosen")

    print("3. switching A → C records A as the space left")
    ask({"do": "spaces", "op": "select", "arg": "2"})
    left = until("spaces.last", lambda: (lambda v: v if v == A else None)(
        subprocess.run(["defaults", "read", domain, "spaces.last"], capture_output=True, text=True).stdout.strip()), 10)
    print("   spaces.last:", left)

    print("4. an agent's backstage page turns hidden when the agent is quiet, visible at its next call")
    mcp("browser_tabs", {"action": "new", "url": f"{base}/agent.html"})
    agent = until("the agent's page", lambda: loaded().get("Page agent"))
    seen = mcp("browser_evaluate", {"tab": agent, "function": "() => document.visibilityState"})
    if "visible" not in seen:
        fail(f"during the call the agent's page is {seen!r}")
    hidden = until("the agent's page hidden after 2 s of quiet", lambda: (lambda v: v if v == "hidden" else None)(
        ask({"do": "eval", "id": agent, "js": "document.visibilityState"}).get("value")), 10)
    seen = mcp("browser_evaluate", {"tab": agent, "function": "() => document.visibilityState"})
    if "visible" not in seen:
        fail(f"at the next call the agent's page is {seen!r}")
    print("   quiet:", hidden, "· next call: visible")
    print("PASS idle-memory")
finally:
    cleanup()
