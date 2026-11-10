#!/usr/bin/env python3
"""Pinned tabs never unload (Fork/PinsAwake.swift), end to end.

November 2026: Felipe's pins (Gmail, Calendar) kept loading again when he
went back to them. The idle sweep already passed over pins, so the page was
going other ways: ⌘W put a pin down, a launch brought every pin back asleep,
and a pin whose web process macOS took back under memory pressure stayed
dead until clicked. Now:

  1. A launch on a loose tab, with two pins in the session: both pins load in
     the background without being looked at; the loose tabs stay asleep.
  2. The idle sweep with the half hour at nought and a budget of one page: an
     ordinary idle tab sleeps, the pins stay loaded; `sleep PIN` says "pinned".
  3. ⌘W on the pin in front: you land on a loose tab, the pin still loaded.
  4. Close Other Tabs on a loose tab: the loose ones close, the pins stay loaded.
  5. A pin's web process ended, as macOS ends one: the pin loads again by
     itself, off stage, and the trail says so. The fourth inside ten minutes
     is not reloaded (the pin waits, stale, as any tab does).
  6. ⌘Q and a relaunch: the pins are loaded again without being clicked.
  7. Unpinned, the tab sleeps by the ordinary rules.
  8. Pinned again while asleep, it loads in the background.

A fresh SEARCH_PROBE world of the development build, headless (--windowed for
a window), pages from a local server: no network, no real Copper world
touched. Run from a logged-in GUI session (over ssh:
`launchctl asuser $(id -u) python3 docs/fixtures/pins-awake-e2e.py`).

    ./build.sh && docs/fixtures/pins-awake-e2e.py [--app build/Copper.app] [--windowed]
"""
import http.server
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
args = sys.argv[1:]
app = os.path.join(root, "build/Copper.app")
if "--app" in args:
    app = os.path.abspath(args[args.index("--app") + 1])
windowed = "--windowed" in args
binary = os.path.join(app, "Contents/MacOS/Copper")
world = f"pinsawake-{os.getpid()}"
folder = os.path.expanduser(f"~/Library/Application Support/Copper ({world})")
domain = f"com.officecommun.search.test.{world}"
pages = tempfile.mkdtemp(prefix="pins-awake-")
log = os.path.join(pages, "copper.log")
proc = None


def store_folder():
    # Store.probeStore(1): FNV-1a of the world's name in the store's identifier.
    h = 2166136261
    for byte in world.encode():
        h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
    return os.path.expanduser(f"~/Library/WebKit/com.collinrijock.copper.dev/WebsiteDataStore/"
                              f"5E4C{h >> 16:04X}-{h & 0xFFFF:04X}-4000-8000-000000000001")


def stop():
    global proc
    if proc and proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(5)
    proc = None


def cleanup():
    stop()
    subprocess.run(["defaults", "delete", domain], capture_output=True)
    for path in (os.path.expanduser(f"~/Library/Preferences/{domain}.plist"),):
        if os.path.exists(path):
            os.remove(path)
    shutil.rmtree(folder, ignore_errors=True)
    shutil.rmtree(store_folder(), ignore_errors=True)
    shutil.rmtree(pages, ignore_errors=True)


def fail(why):
    print(f"FAIL {why}")
    if os.path.exists(log):
        print("".join(open(log, errors="replace").readlines()[-15:]))
    print("trail:", *trail().splitlines()[-30:], sep="\n  ")
    cleanup()
    sys.exit(1)


def ask(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(40)
        s.connect(os.path.join(folder, "bench.sock"))
        s.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while True:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            data += chunk
    answer = json.loads(data.split(b"\n", 1)[0] or b"{}")
    if answer.get("error"):
        fail(f"{request}: {answer['error']}")
    return answer


def pins(settled=False):
    answer = ask({"do": "pins", "op": "list"})
    if settled and answer["waiting"]:
        return {}
    return {p["pin"]: p for p in answer["pins"]}


def loaded(p):
    return p["built"] and not p["asleep"] and not p["loading"] and p["pid"] > 0


def until(what, check, seconds=30):
    limit = time.time() + seconds
    while time.time() < limit:
        value = check()
        if value:
            return value
        time.sleep(0.25)
    try:
        print(json.dumps(ask({"do": "pins", "op": "list"}), indent=1))
    except Exception:
        pass
    fail(f"timed out waiting for {what}")


def tabs():
    return ask({"do": "tabs"})["tabs"]


def show(label):
    answer = ask({"do": "pins", "op": "list"})
    print(f"  · {label}")
    for p in answer["pins"]:
        state = "asleep" if p["asleep"] else ("loaded" if p["built"] else "no page")
        if p["loading"]:
            state += ", loading"
        if p["stale"]:
            state += ", stale"
        print(f"      pin [{p['pin']}] {p['id']} {state:16} pid {p['pid'] or '-':>6} reloads {p['reloads']} "
              f"{'(front)' if p['front'] else ''} {p['title']}")
    for t in tabs():
        if not t["pin"]:
            print(f"      tab     {t['id']} {'asleep' if t['asleep'] else 'loaded':16} "
                  f"{'(front)' if t['active'] else ''} {t['title']}")


def launch():
    global proc
    env = dict(os.environ, SEARCH_PROBE=world)
    if not windowed:
        env["SEARCH_HEADLESS"] = "1"
    env["SEARCH_MCP_PORT"] = str(free_port())
    proc = subprocess.Popen([binary], env=env, stdout=open(log, "a"), stderr=subprocess.STDOUT)
    until("the bench", lambda: os.path.exists(os.path.join(folder, "bench.sock")) and tabs_ok(), 40)
    print(f"  launched pid {proc.pid} ({'windowed' if windowed else 'headless'})")


def tabs_ok():
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            s.connect(os.path.join(folder, "bench.sock"))
        return True
    except OSError:
        return False


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def trail():
    path = os.path.join(folder, "logs/trail.log")
    return open(path).read() if os.path.exists(path) else ""


# --- the pages, served locally -------------------------------------------------
for name, title in [("mail", "Pinned Mail"), ("cal", "Pinned Calendar"), ("a", "Loose A"), ("b", "Loose B"), ("c", "Loose C")]:
    with open(os.path.join(pages, f"{name}.html"), "w") as f:
        f.write(f"<!doctype html><title>{title}</title><h1>{title}</h1>"
                f"<script>document.body.dataset.booted = Date.now()</script>")


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

# --- the world: two pins, three loose tabs, on A -------------------------------
space = "AAAAAAAA-0000-4000-8000-000000000001"
os.makedirs(folder, exist_ok=True)
with open(os.path.join(folder, "session.json"), "w") as f:
    json.dump({
        "active": 0,
        "space": space,
        "spaces": [{"id": space, "name": "Home", "hue": 0.1}],
        "pins": [{"url": f"{base}/mail.html", "title": "Pinned Mail", "pin": "M", "space": space},
                 {"url": f"{base}/cal.html", "title": "Pinned Calendar", "pin": "C", "space": space}],
        "tabs": [{"url": f"{base}/a.html", "title": "Loose A", "space": space, "saved": False, "active": True},
                 {"url": f"{base}/b.html", "title": "Loose B", "space": space, "saved": False},
                 {"url": f"{base}/c.html", "title": "Loose C", "space": space, "saved": False}],
    }, f)
for key, kind, value in [("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("sidebar", "-bool", "true"),
                         # A budget of one loaded page: the sweep then sleeps every idle tab it may.
                         ("sleep.keep", "-int", "1")]:
    subprocess.run(["defaults", "write", domain, key, kind, value], check=True)

try:
    # 1 ---------------------------------------------------------------------------
    print("1. launch: pins load in the background, unlooked-at loose tabs stay asleep")
    launch()
    found = until("both pins loaded in the background", lambda: (lambda p: p if len(p) == 2 and all(loaded(x) for x in p.values()) else None)(pins(settled=True)))
    if any(p["front"] for p in found.values()):
        fail("a pin is in front; the launch was meant to be on Loose A")
    loose = {t["title"]: t for t in tabs() if not t["pin"]}
    if not (loose["Loose B"]["asleep"] and loose["Loose C"]["asleep"]):
        fail(f"loose tabs were woken too: {loose}")
    show("after launch, nothing clicked")
    print("ok pins loaded in the background; Loose B and C still asleep")
    M, C = found["M"]["id"], found["C"]["id"]
    A, B = loose["Loose A"]["id"], loose["Loose B"]["id"]

    # 2 ---------------------------------------------------------------------------
    print("2. idle sweep at nought seconds")
    ask({"do": "select", "id": B})
    until("Loose B loaded", lambda: next(t for t in tabs() if t["id"] == B)["asleep"] is False and not next(t for t in tabs() if t["id"] == B)["loading"])
    ask({"do": "select", "id": A})
    time.sleep(0.5)
    swept = ask({"do": "sleep", "id": "sweep", "seconds": 0})
    print(f"  sleep sweep 0 → budget {swept['budget']}, loaded {swept['loaded']}, chose {swept['chosen']}")
    if B not in swept["chosen"]:
        fail(f"the ordinary idle tab did not sleep: {swept}")
    if M in swept["chosen"] or C in swept["chosen"]:
        fail(f"the sweep chose a pin: {swept}")
    said = ask({"do": "sleep", "id": M})
    print(f"  sleep {M} → {said}")
    if said.get("said") != "pinned" or said.get("asleep"):
        fail(f"a pin was put to sleep by hand: {said}")
    p = pins()
    if not (loaded(p["M"]) and loaded(p["C"])):
        fail(f"a pin unloaded in the sweep: {p}")
    # The sweep takes a picture of the page first, then lets it go.
    until("Loose B asleep after the sweep", lambda: next(t for t in tabs() if t["id"] == B)["asleep"], 10)
    p = pins()
    if not (loaded(p["M"]) and loaded(p["C"])):
        fail(f"a pin unloaded after the sweep: {p}")
    show("after the sweep")
    print("ok the idle tab slept, both pins stayed loaded")

    # 3 ---------------------------------------------------------------------------
    print("3. ⌘W on the pin in front")
    ask({"do": "select", "id": M})
    pid_before = pins()["M"]["pid"]
    answer = ask({"do": "pins", "op": "close", "arg": M})
    print(f"  pins close {M} → active {answer['active']}")
    if answer["active"] == M or answer["active"] not in (A, B):
        fail(f"⌘W did not land on a loose tab: {answer['active']}")
    p = pins()
    if not loaded(p["M"]) or p["M"]["pid"] != pid_before:
        fail(f"⌘W unloaded the pin: {p['M']} (pid before {pid_before})")
    show("after ⌘W on [M]")
    print("ok ⌘W stepped off the pin; same page, same process")

    # 4 ---------------------------------------------------------------------------
    print("4. Close Other Tabs on Loose A")
    before = {k: v["pid"] for k, v in pins().items()}
    answer = ask({"do": "pins", "op": "others", "arg": A})
    if answer["loose"] != 1:
        fail(f"Close Others left {answer['loose']} loose tabs")
    p = pins()
    if not all(loaded(x) for x in p.values()) or {k: v["pid"] for k, v in p.items()} != before:
        fail(f"Close Others unloaded a pin: {p}")
    show("after Close Other Tabs")
    print("ok the loose tabs closed; both pins loaded, same processes")

    # 5 ---------------------------------------------------------------------------
    print("5. a pin's web process ended, off stage")
    for n in range(1, 5):
        old = pins()["M"]["pid"]
        killed = ask({"do": "pins", "op": "kill", "arg": M})
        if n < 4:
            p = until(f"reload {n}", lambda: (lambda m: m if loaded(m) and m["pid"] != old and m["reloads"] == n and not m["stale"] else None)(pins()["M"]), 20)
            print(f"  kill {n}: pid {killed['killed']} ({killed['how']}) → reloaded by itself, new pid {p['pid']}, reloads {p['reloads']}")
            # Tab.recoverFromCrash gives up on a third death inside 30 s; the
            # pins' own guard is the one being tried here.
            time.sleep(16)
        else:
            p = until("the fourth left stale", lambda: (lambda m: m if m["stale"] else None)(pins()["M"]), 10)
            time.sleep(2)
            p = pins()["M"]
            print(f"  kill {n}: pid {killed['killed']} ({killed['how']}) → not reloaded (stale {p['stale']}, pid {p['pid'] or '-'}, reloads {p['reloads']})")
            if p["reloads"] != 3 or p["pid"] != 0:
                fail(f"the fourth death was reloaded: {p}")
    crumbs = [line.split(" ", 2)[2] for line in trail().splitlines() if " pin-reload" in line or " webcontent-gone" in line]
    print("  trail:", *crumbs, sep="\n    ")
    if sum("pin-reload host=" in c for c in crumbs) != 3 or sum("pin-reload-stop" in c for c in crumbs) != 1:
        fail("the trail does not have three pin-reload lines and one pin-reload-stop")
    if not loaded(pins()["C"]):
        fail("the other pin lost its page")
    show("after four deaths")
    print("ok three automatic reloads in the background, then stale as any tab")

    # 6 ---------------------------------------------------------------------------
    print("6. ⌘Q and relaunch")
    ask({"do": "windows", "op": "quit", "arg": ""})
    try:
        proc.wait(20)
    except subprocess.TimeoutExpired:
        fail("the probe did not quit")
    proc = None
    launch()
    found = until("both pins loaded after the relaunch", lambda: (lambda p: p if len(p) == 2 and all(loaded(x) for x in p.values()) else None)(pins(settled=True)))
    if any(p["front"] for p in found.values()):
        fail("the relaunch landed on a pin")
    show("after the relaunch, nothing clicked")
    print("ok the pins loaded in the background again")

    # 7 ---------------------------------------------------------------------------
    print("7. unpinned, a tab sleeps as any tab does")
    C = found["C"]["id"]
    ask({"do": "unpin", "id": C})
    swept = ask({"do": "sleep", "id": "sweep", "seconds": 0})
    print(f"  unpin {C}; sleep sweep 0 → chose {swept['chosen']}")
    if C not in swept["chosen"]:
        fail("the sweep did not choose the unpinned tab")
    until("the unpinned tab asleep", lambda: next(t for t in tabs() if t["id"] == C)["asleep"], 10)
    if not loaded(pins()["M"]):
        fail("the remaining pin unloaded")
    show("after unpinning [C] and sweeping")
    print("ok unpinned, it slept; the remaining pin stayed loaded")

    # 8 ---------------------------------------------------------------------------
    print("8. pinned while asleep, a tab loads in the background")
    ask({"do": "pin", "id": C, "letter": "C"})
    p = until("the new pin loaded", lambda: (lambda x: x if "C" in x and loaded(x["C"]) else None)(pins()), 20)
    if p["C"]["front"]:
        fail("the new pin was put in front to load it")
    show("after pinning the sleeping tab again")
    print("ok pinned while asleep, it loaded without being looked at")
    print("PASS pins-awake-e2e")
finally:
    cleanup()
    server.shutdown()
