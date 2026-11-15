#!/usr/bin/env python3
"""Pages' last pictures kept on disk, and big pins that may sleep (Fork/Covers.swift,
Fork/PinsAwake.swift `mayDoze`), end to end. Council R5 (B3/B14/A4): the first trip
to a space after a launch landed on a white card, because a sleeping tab's picture
lived in memory only.

  1. A tab put to sleep by the idle sweep leaves its picture in covers/ (≤150 KB).
  2. Pins never sleep by default (`sleep PIN` → "pinned", `copper pins` says off).
  3. `copper pins sleep on` (+ the bench's 1 s / 1 MB thresholds): the sweep puts
     both pins to sleep, they stay asleep (the background loader leaves a dozed pin
     alone), and their pages' memory is given back. Going to one wakes it under its
     picture.
  4. ⌘Q and a relaunch: a tab brought back asleep wakes under the picture it left
     on disk (`stage` → covered) — the white landing, fixed.
  5. Closing that tab takes its picture with it; `covers clear` empties the folder.

A fresh SEARCH_PROBE world of the development build, headless, pages from a local
server. Over ssh: `launchctl asuser $(id -u) python3 docs/fixtures/covers-e2e.py`.

    ./build.sh && docs/fixtures/covers-e2e.py [--app build/Copper.app] [--windowed]
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
world = f"covers-{os.getpid()}"
folder = os.path.expanduser(f"~/Library/Application Support/Copper ({world})")
domain = f"com.collinrijock.copper.test.{world}"
pages = tempfile.mkdtemp(prefix="covers-")
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
for name, title in [("mail", "Pinned Mail"), ("cal", "Pinned Calendar"), ("a", "Loose A"), ("b", "Loose B")]:
    with open(os.path.join(pages, f"{name}.html"), "w") as f:
        f.write(f"<!doctype html><title>{title}</title><body style='background:#2a4d7a;color:#fff'><h1>{title}</h1>"
                + "<p>" + "A paragraph of words to picture. " * 40 + "</p></body>")


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


def cli(*words):
    env = dict(os.environ, SEARCH_PROBE=world)
    out = subprocess.run([binary, "--cli", *words], env=env, capture_output=True, text=True, timeout=30)
    if out.returncode:
        fail(f"copper {' '.join(words)}: rc {out.returncode} {out.stderr.strip()}")
    return json.loads(out.stdout)


def covers():
    return ask({"do": "covers", "op": "status"})


def tab(i):
    return next(t for t in tabs() if t["id"] == i)


def stage_active():
    return ask({"do": "stage"})["windows"][0]["active"]


def mb():
    return {t["id"][:8].lower(): t["mb"] for t in ask({"do": "heat"})["tabs"] if t["mb"] is not None}


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
                 {"url": f"{base}/b.html", "title": "Loose B", "space": space, "saved": False}],
    }, f)
for key, kind, value in [("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("sidebar", "-bool", "true"),
                         ("sleep.keep", "-int", "1")]:
    subprocess.run(["defaults", "write", domain, key, kind, value], check=True)

try:
    # 1 ---------------------------------------------------------------------------
    print("1. a tab the sweep puts to sleep leaves its picture on disk")
    launch()
    found = until("both pins loaded", lambda: (lambda p: p if len(p) == 2 and all(loaded(x) for x in p.values()) else None)(pins(settled=True)))
    M, C = found["M"]["id"], found["C"]["id"]
    loose = {t["title"]: t for t in tabs() if not t["pin"]}
    A, B = loose["Loose A"]["id"], loose["Loose B"]["id"]
    ask({"do": "select", "id": B})
    until("Loose B loaded", lambda: not tab(B)["asleep"] and not tab(B)["loading"])
    time.sleep(1)
    ask({"do": "select", "id": A})
    time.sleep(0.5)
    swept = ask({"do": "sleep", "id": "sweep", "seconds": 0})
    if B not in swept["chosen"]:
        fail(f"the idle tab did not sleep: {swept}")
    until("Loose B asleep", lambda: tab(B)["asleep"], 10)
    kept = until("Loose B's picture on disk", lambda: (lambda c: c if c["files"] >= 1 else None)(covers()), 10)
    each = kept["bytes"] / kept["files"]
    print(f"  covers: {kept['files']} file(s), {kept['bytes']} bytes")
    if each > 150 * 1024:
        fail(f"a picture over 150 KB: {kept}")
    print("ok the sleeping tab's picture is on disk")

    # 2 ---------------------------------------------------------------------------
    print("2. pins never sleep by default")
    said = ask({"do": "sleep", "id": M})
    state = cli("pins")
    print(f"  sleep {M} → {said.get('said')}; copper pins → {state}")
    if said.get("said") != "pinned" or said.get("asleep") or state["bigPinsSleep"]:
        fail(f"a pin may sleep with the setting off: {said} {state}")
    print("ok off: a pin stays loaded")

    # 3 ---------------------------------------------------------------------------
    print("3. copper pins sleep on: big pins left long enough sleep, and stay asleep")
    weights = mb()
    before = sum(weights.get(i, 0) for i in (M, C))
    state = cli("pins", "sleep", "on")
    # The bench's thresholds: a second unlooked-at, a megabyte (the defaults are two hours, 300 MB).
    for key, kind, value in [("pins.sleep.after", "-float", "1"), ("pins.sleep.mb", "-int", "1")]:
        subprocess.run(["defaults", "write", domain, key, kind, value], check=True)
    time.sleep(1.5)
    swept = ask({"do": "sleep", "id": "sweep", "seconds": 0})
    print(f"  copper pins sleep on → {state}; sweep chose {swept['chosen']}")
    if not state["bigPinsSleep"] or M not in swept["chosen"] or C not in swept["chosen"]:
        fail(f"the pins were not chosen: {swept}")
    until("both pins asleep", lambda: (lambda p: p if p["M"]["asleep"] and p["C"]["asleep"] and p["M"]["dozed"] else None)(pins()), 10)
    time.sleep(3)
    p = pins()
    if not (p["M"]["asleep"] and p["C"]["asleep"]):
        fail(f"a dozed pin was loaded again in the background: {p}")
    print(f"  pins' pages before: {before} MB; after: {sum(mb().get(i, 0) for i in (M, C))} MB")
    ask({"do": "select", "id": M})
    covered = stage_active()
    print(f"  select [M] → covered {covered.get('covered')}, asleep {covered.get('asleep')}")
    if not covered.get("covered"):
        fail(f"the pin woke without its picture: {covered}")
    until("[M] loaded again", lambda: loaded(pins()["M"]))
    ask({"do": "select", "id": A})
    cli("pins", "sleep", "off")
    show("after dozing and waking [M]")
    print("ok the pins slept under the setting, stayed asleep, and woke under their picture")

    # 4 ---------------------------------------------------------------------------
    print("4. ⌘Q and relaunch: a restored tab wakes under the picture it left")
    ask({"do": "windows", "op": "quit", "arg": ""})
    try:
        proc.wait(20)
    except subprocess.TimeoutExpired:
        fail("the probe did not quit")
    proc = None
    kept = len([f for f in os.listdir(os.path.join(folder, "covers")) if f.endswith(".jpg")])
    print(f"  {kept} picture(s) on disk after the quit")
    # Loose B and the two pins left theirs when they slept; Loose A, awake, leaves its own at the quit.
    if kept < 4:
        fail(f"the quit did not keep the awake page's picture ({kept} on disk)")
    launch()
    until("pins loaded", lambda: (lambda p: p if len(p) == 2 and all(loaded(x) for x in p.values()) else None)(pins(settled=True)))
    loose = {t["title"]: t for t in tabs() if not t["pin"]}
    A, B = loose["Loose A"]["id"], loose["Loose B"]["id"]
    if not tab(B)["asleep"]:
        fail("Loose B was meant to come back asleep")
    ask({"do": "select", "id": B})
    covered = stage_active()
    print(f"  select Loose B → covered {covered.get('covered')}")
    if not covered.get("covered"):
        fail(f"the restored tab woke white (no picture from disk): {covered}")
    print("ok the restored tab woke under its kept picture")

    # 5 ---------------------------------------------------------------------------
    print("5. closing a tab takes its picture; covers clear empties the folder")
    ask({"do": "select", "id": A})
    n = covers()["files"]
    ask({"do": "pins", "op": "close", "arg": B})  # ⌘W on it in its window (test worlds)
    after = until("one picture fewer", lambda: (lambda c: c if c["files"] == n - 1 else None)(covers()), 5)
    ask({"do": "covers", "op": "clear"})
    if covers()["files"] != 0:
        fail("covers clear left pictures")
    print(f"  {n} → {after['files']} → 0")
    print("ok")
    print("PASS covers-e2e")
finally:
    cleanup()
    server.shutdown()
