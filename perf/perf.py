#!/usr/bin/env python3
"""Copper perf harness: launch, space switching, page loads, ⌘R.

Runs on the Mac, against a probe world's bench socket (see perf/README.md).

    perf.py seed WORLD                      copy the installed Copper's tabs, spaces, history, groups,
                                            bookmarks and icons (never cookies or passwords) into
                                            "Copper (WORLD)", with the restored tab on the local page
    perf.py launch APP WORLD N              N launches of APP into WORLD (FG=1: in front); `bench pace` each
    perf.py ablaunch WORLD A=APP B=APP N    launches alternating between builds, N rounds
    perf.py spaces WORLD ROUNDS             every space in turn, ROUNDS times; slide timings + pace per switch
    perf.py load WORLD URL N [--user]       N loads of URL in a new tab (--user: ⌘T, the address, Return)
    perf.py reload WORLD URL N              open URL, then ⌘R it N times
    perf.py quit WORLD                      SIGTERM the world's process
"""
import json, os, shutil, signal, socket, subprocess, sys, time

SUPPORT = os.path.expanduser("~/Library/Application Support")
REAL = os.path.join(SUPPORT, "Copper")
SEED_FILES = ["session.json", "history.json", "groups.json", "bookmarks.json", "windows.json"]
SEED_DIRS = ["icons", "themes", "canvas"]


def folder(world):
    return os.path.join(SUPPORT, f"Copper ({world})")


def ask(world, request, timeout=60):
    path = os.path.join(folder(world), "bench.sock")
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


def pid_of(world):
    lock = os.path.join(folder(world), "instance.lock")
    try:
        out = subprocess.run(["lsof", "-t", lock], capture_output=True, text=True).stdout.split()
        return int(out[0]) if out else None
    except Exception:
        return None


def seed(world):
    dest = folder(world)
    os.makedirs(dest, exist_ok=True)
    for name in SEED_FILES:
        src = os.path.join(REAL, name)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(dest, name))
    for name in SEED_DIRS:
        src = os.path.join(REAL, name)
        if os.path.isdir(src):
            shutil.rmtree(os.path.join(dest, name), ignore_errors=True)
            shutil.copytree(src, os.path.join(dest, name))
    # The restored page: a local one, so a launch measures the browser, not a
    # site's servers (perf/site, served by suite.sh on :8799).
    path = os.path.join(dest, "session.json")
    shape = json.load(open(path))
    current = shape.get("space")
    entries = [t for t in shape.get("tabs", []) if t.get("space") == current and not t.get("pin")]
    marked = [t for t in shape.get("tabs", []) + shape.get("pins", []) if t.get("active")]
    target = marked[0] if marked else (entries[0] if entries else None)
    for t in shape.get("tabs", []) + shape.get("pins", []):
        t.pop("active", None)
    if entries:
        target = entries[0]
        target["active"] = True
        # PERF_ACTIVE=URL restores a real page instead (cache tests).
        target["url"] = os.environ.get("PERF_ACTIVE", "http://127.0.0.1:8799/index.html")
        target["title"] = "Perf page"
    json.dump(shape, open(path, "w"))
    suite = f"com.officecommun.search.test.{world}"
    for key, kind, value in [("bench", "-bool", "true"), ("welcomed", "-bool", "true"),
                             ("sidebar", "-bool", "true"), ("glyph", "-string", "icons"),
                             ("look", "-string", "system"), ("sidebar.width", "-float", "326")]:
        subprocess.run(["defaults", "write", suite, key, kind, value], check=True)
    print(json.dumps({"seeded": dest}))


def quit_world(world, wait=10):
    pid = pid_of(world)
    if not pid:
        return
    os.kill(pid, signal.SIGTERM)
    end = time.time() + wait
    while time.time() < end:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    os.kill(pid, signal.SIGKILL)
    time.sleep(0.5)


def connectable(world):
    try:
        ask(world, {"do": "probe"}, timeout=2)
        return True
    except Exception:
        return False


def launch(app, world, runs):
    results = []
    for i in range(runs):
        quit_world(world)
        sock = os.path.join(folder(world), "bench.sock")
        if os.path.exists(sock):
            os.unlink(sock)
        time.sleep(1.5)
        t0 = time.time()
        flags = ["-n", "-a"] if os.environ.get("FG") else ["-n", "-g", "-a"]
        subprocess.run(["open", *flags, app, "--env", f"SEARCH_PROBE={world}",
                        "--env", "SEARCH_MEASURE=1"], check=True)
        t_sock = None
        while time.time() - t0 < 60:
            if connectable(world):
                t_sock = time.time()
                break
            time.sleep(0.01)
        # The active tab: wait for it to stop loading.
        active = None
        t_active = None
        while time.time() - t0 < 60:
            try:
                tabs = ask(world, {"do": "tabs"}, timeout=5).get("tabs", [])
            except Exception:
                tabs = []
            active = next((t for t in tabs if t.get("active")), None)
            if active and not active.get("loading") and active.get("view"):
                t_active = time.time()
                break
            time.sleep(0.02)
        pace = {}
        try:
            pace = ask(world, {"do": "pace"}, timeout=5)
        except Exception:
            pass
        row = {"run": i, "socket_ms": round((t_sock - t0) * 1000) if t_sock else None,
               "active_loaded_ms": round((t_active - t0) * 1000) if t_active else None,
               "active": (active or {}).get("url", "")[:80], "pace": pace}
        results.append(row)
        print(json.dumps(row), flush=True)
    quit_world(world)
    return results


TIMING_JS = """
(() => {
  const n = performance.getEntriesByType('navigation')[0] || {};
  const p = Object.fromEntries(performance.getEntriesByType('paint').map(e => [e.name, Math.round(e.startTime)]));
  const lcp = performance.getEntriesByType('largest-contentful-paint').slice(-1)[0];
  const res = performance.getEntriesByType('resource');
  const bytes = res.reduce((a, r) => a + (r.transferSize || 0), 0);
  const cached = res.filter(r => r.transferSize === 0 && r.decodedBodySize > 0).length;
  return JSON.stringify({origin: performance.timeOrigin, type: n.type, fetch: Math.round(n.fetchStart||0),
    dns: Math.round((n.domainLookupEnd||0)-(n.domainLookupStart||0)), connect: Math.round((n.connectEnd||0)-(n.connectStart||0)),
    ttfb: Math.round(n.responseStart||0), dcl: Math.round(n.domContentLoadedEventEnd||0), load: Math.round(n.loadEventEnd||0),
    fp: p['first-paint'], fcp: p['first-contentful-paint'], lcp: lcp ? Math.round(lcp.startTime) : null,
    resources: res.length, cached, bytes: bytes + (n.transferSize||0), docBytes: n.transferSize, nodes: document.getElementsByTagName('*').length});
})()
"""


def load(world, url, runs, fresh=False, settle=1.5, user=False):
    out = []
    for i in range(runs):
        try:
            ask(world, {"do": "pace", "op": "reset"})
        except Exception:
            pass
        if user:
            # The person's path: ⌘T, the address, Return — a foreground tab.
            reply = ask(world, {"do": "newtab", "text": url, "go": True, "settle": 0.4, "how": "open"})
            t0 = time.time()
            tabs = ask(world, {"do": "tabs"}).get("tabs", [])
            tid = next((t["id"] for t in tabs if t.get("active")), None)
        else:
            t0 = time.time()
            tab = ask(world, {"do": "open", "url": url})
            tid = tab.get("id")
            try:
                ask(world, {"do": "select", "id": tid})
            except Exception:
                pass
        waited = ask(world, {"do": "wait", "id": tid, "seconds": 30}, timeout=40)
        t_done = time.time()
        time.sleep(settle)
        raw = ask(world, {"do": "eval", "id": tid, "js": TIMING_JS}, timeout=20)
        val = raw.get("result") or raw.get("value") or raw
        try:
            m = json.loads(val) if isinstance(val, str) else val
        except Exception:
            m = {"raw": str(val)[:300]}
        if isinstance(m, dict) and m.get("origin"):
            m["app_overhead_ms"] = round(m["origin"] - t0 * 1000)
            if m.get("fcp") is not None:
                m["req_to_fcp_ms"] = round(m["origin"] + m["fcp"] - t0 * 1000)
            if m.get("load"):
                m["req_to_load_ms"] = round(m["origin"] + m["load"] - t0 * 1000)
        m["wait_ms"] = round((t_done - t0) * 1000)
        try:
            pace = ask(world, {"do": "pace"})
            m["busy"] = pace.get("busy"); m["longest"] = pace.get("longest"); m["counts"] = pace.get("counts"); m["window"] = pace.get("window")
        except Exception:
            pass
        m["run"] = i
        print(json.dumps(m), flush=True)
        out.append(m)
        if user:
            ask(world, {"do": "key", "id": tid, "text": "⌘w", "via": "app"})
        else:
            ask(world, {"do": "close", "id": tid})
        time.sleep(0.5)
    return out


def reload(world, url, runs, settle=1.5):
    """Open URL as a person would, then ⌘R it RUNS times: what a cached reload costs."""
    ask(world, {"do": "newtab", "text": url, "go": True, "settle": 0.4, "how": "open"})
    tabs = ask(world, {"do": "tabs"}).get("tabs", [])
    tid = next((t["id"] for t in tabs if t.get("active")), None)
    ask(world, {"do": "wait", "id": tid, "seconds": 30}, timeout=40)
    time.sleep(settle)
    out = []
    for i in range(runs):
        t0 = time.time()
        ask(world, {"do": "key", "id": tid, "text": "⌘r", "via": "app"})
        time.sleep(0.3)
        ask(world, {"do": "wait", "id": tid, "seconds": 30}, timeout=40)
        time.sleep(settle)
        raw = ask(world, {"do": "eval", "id": tid, "js": TIMING_JS}, timeout=20)
        val = raw.get("value") or raw.get("result") or raw
        m = json.loads(val) if isinstance(val, str) else {"raw": str(val)[:200]}
        if m.get("origin"):
            m["app_overhead_ms"] = round(m["origin"] - t0 * 1000)
            if m.get("fcp") is not None:
                m["req_to_fcp_ms"] = round(m["origin"] + m["fcp"] - t0 * 1000)
            if m.get("load"):
                m["req_to_load_ms"] = round(m["origin"] + m["load"] - t0 * 1000)
        m["run"] = i
        print(json.dumps(m), flush=True)
        out.append(m)
    ask(world, {"do": "key", "id": tid, "text": "⌘w", "via": "app"})
    return out


def spaces(world, rounds):
    listing = ask(world, {"do": "spaces", "op": "list", "arg": ""})
    count = len(listing.get("spaces", []))
    rows = []
    for r in range(rounds):
        for n in list(range(1, count)) + [0]:
            try:
                ask(world, {"do": "pace", "op": "reset"})
            except Exception:
                pass
            t0 = time.time()
            ask(world, {"do": "spaces", "op": "select", "arg": str(n)})
            t_ack = time.time()
            time.sleep(0.05)
            first = next((t for t in ask(world, {"do": "tabs"}).get("tabs", []) if t.get("active")), {})
            time.sleep(0.85)
            slide = ask(world, {"do": "spaces", "op": "slide", "arg": ""}).get("slide", {})
            pace = {}
            try:
                pace = ask(world, {"do": "pace"})
            except Exception:
                pass
            tabs = ask(world, {"do": "tabs"}).get("tabs", [])
            active = next((t for t in tabs if t.get("active")), {})
            row = {"round": r, "to": n, "ack_ms": round((t_ack - t0) * 1000),
                   "slide": {k: slide.get(k) for k in ("planned", "committed", "moved", "landed", "switched", "ended", "frames", "longest", "missed")},
                   "active": active.get("url", "")[:60], "active_loading": active.get("loading"),
                   "landed_loading": first.get("loading"), "landed_built": bool(first.get("view")), "pace": pace}
            rows.append(row)
            print(json.dumps(row), flush=True)
    return rows


def ablaunch(apps, world, rounds):
    """Launches alternating between builds, so both see the same machine."""
    for r in range(rounds):
        for label, app in apps:
            row = launch(app, world, 1)[0]
            row["label"] = label
            row["round"] = r
            print("AB " + json.dumps(row), flush=True)


def main(argv):
    if not argv:
        print(__doc__)
        return
    verb = argv[0]
    if verb == "seed":
        seed(argv[1])
    elif verb == "launch":
        launch(argv[1], argv[2], int(argv[3]))
    elif verb == "spaces":
        spaces(argv[1], int(argv[2]))
    elif verb == "load":
        load(argv[1], argv[2], int(argv[3]), fresh="--fresh" in argv, user="--user" in argv)
    elif verb == "ablaunch":
        pairs = [tuple(a.split("=", 1)) for a in argv[2:-1]]
        ablaunch(pairs, argv[1], int(argv[-1]))
    elif verb == "reload":
        reload(argv[1], argv[2], int(argv[3]))
    elif verb == "quit":
        quit_world(argv[1])
    elif verb == "ask":
        print(json.dumps(ask(argv[1], json.loads(argv[2])), indent=1))


if __name__ == "__main__":
    main(sys.argv[1:])
