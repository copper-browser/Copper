#!/usr/bin/env python3
"""Track A (Mac performance) driver for perf/hillclimb/perf.sh. Runs on the Mac.

    run.py setup   OUT ARM...       machine info, local pages, RawLoad.app, canvas fixture pages
    run.py launch  OUT ARM...       A1: launches alternating arms, `bench pace` marks
    run.py session OUT ARM...       A2 A4 A6 A7: per launch: idle cost, memory, space + tab switches, typing
    run.py load    OUT ARM...       A3: Copper page loads vs bare WKWebView (rawload.swift), same pages
    run.py smooth  OUT ARM...       A5: scroll + canvas frame times (run on the Retina laptop)
    run.py summary DEST DIR...      perf.json + perf.md from one or more OUT dirs (any machine)

ARM = label=/path/to/Copper.app. Rows land in OUT/raw/<phase>.jsonl. Every launch re-seeds the
probe world from HC_SEED (a frozen copy of a real session: tabs, spaces, history, icons; never
cookies or passwords) so every launch of every arm starts from the same state.
"""
import ctypes, fcntl, glob, json, os, platform, re, shutil, signal, socket, statistics, subprocess, sys, time
from contextlib import contextmanager

HOME = os.path.expanduser("~")
TOOLS = os.environ.get("HC_TOOLS", f"{HOME}/hc/tools")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(TOOLS, "perf"))
import perf  # noqa: E402  (perf/perf.py: ask, seed, spaces, tabs, load, quit_world)

WORLD = os.environ.get("HC_WORLD", "hcperf")
CANVAS_WORLD = WORLD + "canvas"
PORT = int(os.environ.get("HC_PORT", "4130"))       # perf track: 4130–4139, never 4123
SITE_PORT = int(os.environ.get("HC_SITE_PORT", "4139"))
FIXTURE_PORT = int(os.environ.get("HC_FIXTURE_PORT", "4138"))
SEED = os.path.expanduser(os.environ.get("HC_SEED", f"{HOME}/hc/seed"))
LOCK = os.environ.get("HC_LOCK", "")                # ~/hc/mini.lock on the mini (flock = what lockf(1) takes)
MODE = os.environ.get("HC_MODE", "fg")              # fg (mini) | headless (laptop: never steals focus)
N = lambda k, d: int(os.environ.get(k, d))
SITE = f"http://127.0.0.1:{SITE_PORT}/index.html"
CANVAS_OUT = f"{HOME}/hc/canvas-out"
FIX = os.path.join(TOOLS, "docs/fixtures")
assert PORT != 4123, "never the installed Copper's port"  # perf track: 4130–4139; fix workers: their own range
perf.REAL = SEED  # seed from the frozen snapshot, never the installed Copper's live folder


# ---------- plumbing ----------

def arms(argv):
    out = []
    for a in argv:
        label, app = a.split("=", 1)
        out.append((label, os.path.abspath(os.path.expanduser(app))))
    return out


def order(arms_, r):
    """ABBA: alternate which arm goes first each round so drift hits both."""
    return arms_ if r % 2 == 0 else arms_[::-1]


@contextmanager
def locked():
    if not LOCK:
        yield
        return
    with open(os.path.expanduser(LOCK), "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def load_avg():
    return [round(x, 2) for x in os.getloadavg()]


def emit(out, phase, row):
    row["loadavg"] = load_avg()
    row["t"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    os.makedirs(os.path.join(out, "raw"), exist_ok=True)
    with open(os.path.join(out, "raw", phase + ".jsonl"), "a") as f:
        f.write(json.dumps(row) + "\n")
    print(phase, json.dumps(row)[:300], flush=True)


def ask(req, timeout=60, world=WORLD):
    return perf.ask(world, req, timeout)


def env_for(world, port, size=None):
    env = ["--env", f"SEARCH_PROBE={world}", "--env", "SEARCH_MEASURE=1", "--env", f"SEARCH_MCP_PORT={port}"]
    if MODE == "headless":
        env += ["--env", "SEARCH_HEADLESS=1", "--env", f"SEARCH_HEADLESS_SIZE={size or '1440x900'}"]
    return env


def start(app, world=WORLD, port=PORT, seed=True, size=None):
    """Quit the world, re-seed it, launch APP into it; wait for the restored page. → timings."""
    perf.quit_world(world)
    sock = os.path.join(perf.folder(world), "bench.sock")
    if os.path.exists(sock):
        os.unlink(sock)
    # SIGTERM is not a clean quit for Copper: drop the "unclean" records it leaves, so no launch reports them
    shutil.rmtree(os.path.join(perf.folder(world), "crashes"), ignore_errors=True)
    if seed:
        os.environ["PERF_ACTIVE"] = SITE
        with open(os.devnull, "w") as dn:
            so, sys.stdout = sys.stdout, dn
            try:
                perf.seed(world)
            finally:
                sys.stdout = so
    time.sleep(1.5)
    flags = ["-n", "-a"] if MODE == "fg" else ["-n", "-g", "-a"]
    t0 = time.time()
    subprocess.run(["open", *flags, app, *env_for(world, port, size)], check=True)
    t_sock = None
    while time.time() - t0 < 60:
        if perf.connectable(world):
            t_sock = time.time()
            break
        time.sleep(0.01)
    if not t_sock:
        raise RuntimeError(f"{app} never opened its bench socket in {world}")
    t_active = None
    while time.time() - t0 < 60:
        try:
            tabs = ask({"do": "tabs"}, 5, world).get("tabs", [])
        except Exception:
            tabs = []
        a = next((t for t in tabs if t.get("active")), None)
        if a and not a.get("loading") and a.get("view"):
            t_active = time.time()
            break
        time.sleep(0.02)
    return {"socket_ms": round((t_sock - t0) * 1000), "active_loaded_ms": round((t_active - t0) * 1000) if t_active else None,
            "pid": perf.pid_of(world)}


# ---------- every process the app is responsible for (mem.py's way, by pid) ----------

class _TB(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_tb = _TB()
if sys.platform == "darwin":  # `summary` also runs on the (Linux) devbox
    _lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    _lib.responsibility_get_pid_responsible_for_pid.restype = ctypes.c_int
    _lib.mach_timebase_info(ctypes.byref(_tb))


def _rusage(pid):
    buf = (ctypes.c_uint64 * 64)()
    if _lib.proc_pid_rusage(pid, 0, ctypes.byref(buf)) != 0:  # RUSAGE_INFO_V0
        return None
    tick = _tb.numer / _tb.denom  # mach ticks → ns
    return {"cpu_ns": (buf[2] + buf[3]) * tick, "idle_wk": buf[4], "int_wk": buf[5], "fp": buf[9]}


def procs(app_pid):
    """{pid: {name, mb, cpu_ns, idle_wk, int_wk}} for the app and everything it is responsible for
    (WebContent, GPU, Networking services)."""
    rows = {}
    for line in subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout.splitlines():
        pid, comm = line.strip().split(None, 1)
        pid = int(pid)
        if pid == app_pid or _lib.responsibility_get_pid_responsible_for_pid(pid) == app_pid:
            r = _rusage(pid)
            if r:
                r["name"] = comm.rsplit("/", 1)[-1]
                r["mb"] = round(r.pop("fp") / 1048576, 1)
                rows[pid] = r
    return rows


def mem(app_pid):
    p = procs(app_pid)
    kinds = {}
    for pid, r in p.items():
        k = "app" if pid == app_pid else ("web" if "WebContent" in r["name"] else "gpu" if "GPU" in r["name"] else
                                          "net" if "Networking" in r["name"] else "other")
        kinds[k] = round(kinds.get(k, 0) + r["mb"], 1)
    return {"total_mb": round(sum(r["mb"] for r in p.values()), 1), "by_kind": kinds, "processes": len(p)}


def cost(before, after, seconds, app_pid):
    """CPU % (of one core) and wakeups/s between two procs() snapshots; processes alive in both."""
    cpu = wk = app_cpu = 0.0
    for pid, a in after.items():
        b = before.get(pid)
        if not b:
            continue
        d = (a["cpu_ns"] - b["cpu_ns"]) / 1e9
        cpu += d
        wk += (a["idle_wk"] - b["idle_wk"]) + (a["int_wk"] - b["int_wk"])
        if pid == app_pid:
            app_cpu = d
    return {"cpu_pct": round(100 * cpu / seconds, 2), "app_cpu_pct": round(100 * app_cpu / seconds, 2),
            "wakeups_per_s": round(wk / seconds, 1)}


# ---------- phases ----------

def setup(out, arms_):
    os.makedirs(out, exist_ok=True)
    disp = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout
    res = re.findall(r"Resolution: (.+)", disp)
    info = {"host": os.environ.get("HC_HOST") or platform.node(), "model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
            "cpus": os.cpu_count(), "macos": platform.mac_ver()[0], "displays": res, "retina": "Retina" in disp,
            "mode": MODE, "world": WORLD, "port": PORT, "seed": SEED, "seed_snapshot": open(os.path.join(SEED, "SNAPSHOT")).read().strip() if os.path.exists(os.path.join(SEED, "SNAPSHOT")) else None,
            "arms": [{"label": l, "app": a, "version": subprocess.run(["defaults", "read", a + "/Contents/Info", "CFBundleVersion"], capture_output=True, text=True).stdout.strip()} for l, a in arms_],
            "load": load_avg(), "t": time.strftime("%Y-%m-%dT%H:%M:%S")}
    s = json.load(open(os.path.join(SEED, "session.json")))
    info["seed_tabs"] = len(s.get("tabs", [])) + len(s.get("pins", []))
    json.dump(info, open(os.path.join(out, "machine.json"), "w"), indent=1)
    # The restored page (perf/site.py): served on SITE_PORT, our own port.
    site = os.path.join(TOOLS, "perf", "site")
    if not os.path.exists(os.path.join(site, "index.html")):
        subprocess.run([sys.executable, os.path.join(TOOLS, "perf", "site.py")], check=True)
    serve(site, SITE_PORT)
    if os.environ.get("HC_PHASES", "").find("load") >= 0:
        rawload_app()
    if os.environ.get("HC_PHASES", "").find("smooth") >= 0:
        man = os.path.join(CANVAS_OUT, "big", "manifest.json")
        if not os.path.exists(man):
            subprocess.run([sys.executable, os.path.join(FIX, "canvas-big", "gen.py"), "--scale", "big", "--out", CANVAS_OUT,
                            "--base", f"http://127.0.0.1:{FIXTURE_PORT}", "-q"], check=True)
        # A long image page for A5: every fixture image three times (distinct URLs, so each decodes).
        imgs = sorted(f for f in os.listdir(os.path.join(CANVAS_OUT, "www", "img")) if f != "favicon.png")
        figs = "".join(f'<figure><img src="/img/{f}?c={c}"><figcaption>{f}</figcaption></figure>' for c in range(3) for f in imgs)
        open(os.path.join(CANVAS_OUT, "www", "hc-gallery.html"), "w").write(
            "<!doctype html><title>HC gallery</title><style>body{margin:0;font:12px Menlo}.g{display:grid;grid-template-columns:repeat(3,1fr);"
            "gap:12px;padding:20px}img{width:100%;height:220px;object-fit:cover;border-radius:8px;box-shadow:0 6px 20px rgba(0,0,0,.25)}"
            f"figure{{margin:0}}</style><div class=g>{figs}</div>")
        subprocess.run([os.path.join(FIX, "canvas-big", "serve.sh"), "start"], check=True,
                       env={**os.environ, "FIXTURE_PORT": str(FIXTURE_PORT), "FIXTURE_OUT": CANVAS_OUT})
    print(json.dumps(info))


def serve(directory, port):
    import urllib.request
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/index.html", timeout=1)
        return
    except Exception:
        pass
    subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "-d", directory],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    time.sleep(1)


def rawload_app():
    """perf/rawload.swift wrapped in an .app (it needs a window server). A build: locked on the mini."""
    app = os.path.expanduser(os.environ.get("HC_RAWLOAD", f"{HOME}/hc/RawLoad.app"))
    binp = os.path.join(app, "Contents", "MacOS", "RawLoad")
    src = os.path.join(TOOLS, "perf", "rawload.swift")
    if os.path.exists(binp) and os.path.getmtime(binp) > os.path.getmtime(src):
        return app
    os.makedirs(os.path.dirname(binp), exist_ok=True)
    with open(os.path.join(app, "Contents", "Info.plist"), "w") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                '<key>CFBundleExecutable</key><string>RawLoad</string><key>CFBundleIdentifier</key><string>dev.hc.rawload</string>'
                '<key>CFBundlePackageType</key><string>APPL</string><key>NSAppTransportSecurity</key><dict>'
                '<key>NSAllowsArbitraryLoads</key><true/></dict></dict></plist>')
    with locked():
        subprocess.run(["swiftc", "-O", "-o", binp, src], check=True)
    subprocess.run(["codesign", "-s", "-", "--force", app], check=True)
    return app


def launch(out, arms_):
    """A1: restored-page paint per launch, arms alternating. Round 0 is dropped in the summary."""
    for r in range(N("HC_LAUNCHES", 8)):
        for label, app in order(arms_, r):
            with locked():
                t = start(app)
                time.sleep(3)  # let `settled` land; launchBusy then covers the launch
                pace = ask({"do": "pace"})
                emit(out, "launch", {"arm": label, "round": r, **t, "marks": pace.get("marks", {}),
                                     "launchBusy": pace.get("launchBusy"),
                                     "firstPass": (pace.get("launchSlow") or [[0, None]])[0][1],
                                     "launchSlow": pace.get("launchSlow")})
                perf.quit_world(WORLD)


TYPE_WORDS = ["github", "wikipedia", "copper browser"]
BAR_QUERIES = ["g", "gi", "git", "github copper", "wiki", "slack"]


def session(out, arms_):
    """One launch per arm per round: idle cost (A6) + idle memory (A4), every space (A2),
    12 tabs twice (A2: wake, then warm), memory after (A4), typing in ⌘T and ⌘K (A7)."""
    settle, idle = N("HC_SETTLE", 30), N("HC_IDLE", 60)
    quiet = open(os.devnull, "w")
    for r in range(N("HC_ROUNDS", 5)):
        for label, app in order(arms_, r):
            for attempt in range(2):  # a probe killed under us (memory, another runner): note it, go again once
                try:
                    with locked():
                        one_session(out, label, app, r, settle, idle, quiet)
                    break
                except Exception as e:
                    perf.quit_world(WORLD)
                    emit(out, "session_error", {"arm": label, "round": r, "attempt": attempt, "error": repr(e)[:300]})


def one_session(out, label, app, r, settle, idle, quiet):
    t = start(app)
    pid = t["pid"]
    time.sleep(settle)
    row = {"arm": label, "round": r, **t}
    # A4 + A6: idle
    row["mem_idle"] = mem(pid)
    ask({"do": "pace", "op": "reset"})
    b = procs(pid)
    t0 = time.time()
    time.sleep(idle)
    a = procs(pid)
    pace = ask({"do": "pace"})
    row["idle"] = {**cost(b, a, time.time() - t0, pid), "seconds": idle, "busy": pace.get("busy"),
                   "longest": pace.get("longest"), "passes": pace.get("passes"), "slow": len(pace.get("slow", []))}
    row["heat_idle"] = [{"mb": x.get("mb"), "cpu": round(x.get("cpu") or 0, 2), "title": (x.get("title") or "")[:40]}
                        for x in ask({"do": "heat"}).get("tabs", [])]
    so, sys.stdout = sys.stdout, quiet  # perf.py prints its rows; we keep them in ours
    try:
        sp = perf.spaces(WORLD, 1)
        tb = perf.tabs(WORLD, 2, 12)
    finally:
        sys.stdout = so
    row["spaces"] = [{"to": x["to"], "ack_ms": x["ack_ms"], "busy": x["pace"].get("busy"), "longest": x["pace"].get("longest"),
                      "landed_loading": x.get("landed_loading"), "slide": x.get("slide")} for x in sp]
    row["tabs"] = tb
    time.sleep(3)
    row["mem_loaded"] = mem(pid)
    row["heat_loaded"] = [{"mb": x.get("mb"), "title": (x.get("title") or "")[:40]} for x in ask({"do": "heat"}).get("tabs", [])]
    # A7: ⌘T card typing (Launcher.typing) and ⌘K (bar: summon + type + offers)
    row["typing"] = []
    for w in TYPE_WORDS:
        x = ask({"do": "newtab", "text": w, "type": True, "every": 0.08, "settle": 1.5})
        row["typing"].append({k: x.get(k) for k in ("typed", "keyMs", "keyMaxMs", "openMs", "openBusyMs", "openLongestMs",
                                                    "busyMs", "longestMs", "over16", "over50", "historyMs", "rows")})
        time.sleep(0.5)
    row["bar"] = []
    for q in BAR_QUERIES:
        x = ask({"do": "bar", "text": q})
        row["bar"].append({"q": q, "ms": x.get("milliseconds"), "offers": len(x.get("offers", []))})
        time.sleep(0.3)
    perf.quit_world(WORLD)
    emit(out, "session", row)


LOAD_PAGES = [("local", SITE), ("wikipedia", "https://en.wikipedia.org/wiki/WebKit"),
              ("github", "https://github.com/WebKit/WebKit")]


def rawload(url, runs):
    """Bare WKWebView control, stepped: returns (step, rows). step(i) starts its load i and waits for the row,
    so Copper's and the bare view's loads alternate one for one on the same network."""
    app = rawload_app()
    path, go = f"/tmp/hc-rawload-{os.getpid()}.txt", f"/tmp/hc-rawload-{os.getpid()}.go"
    for p in (path, go):
        if os.path.exists(p):
            os.unlink(p)
    proc = subprocess.Popen(["open", "-W", "-n", "-g", app, "--stdout", path, "--args", url, str(runs), "--step", go])
    rows = []

    def step(i):
        open(go, "w").close()
        t = time.time()
        while len(rows) <= i and time.time() - t < 60:
            time.sleep(0.05)
            lines = [l for l in open(path)] if os.path.exists(path) else []
            rows[:] = [json.loads(l) for l in lines if l.startswith("{") and l.endswith("\n")]
        for m in rows:
            m.pop("list", None); m.pop("events", None)
    return step, rows, proc


def load(out, arms_):
    """A3: HC_LOADS loads of each page in a fresh Copper tab, each one followed by a load in a fresh bare
    WKWebView, so the network is the same for both. Both clocks start in-app as the view is made (Copper's
    `open` reply carries its t0). The first of each arm is dropped (cold DNS/cache)."""
    n = N("HC_LOADS", 21)
    quiet = open(os.devnull, "w")
    for r in range(N("HC_LOAD_ROUNDS", 1)):
        for label, app in order(arms_, r):
            with locked():
                start(app)
                time.sleep(10)
                for name, url in LOAD_PAGES:
                    step, raw, proc = rawload(url, n)
                    so, sys.stdout = sys.stdout, quiet
                    try:
                        rows = perf.load(WORLD, url, n, between=step)
                    finally:
                        sys.stdout = so
                    proc.wait(timeout=30)
                    for m in rows:
                        emit(out, "load", {"arm": label, "round": r, "who": "copper", "page": name,
                                           **{k: m.get(k) for k in ("run", "app_overhead_ms", "req_to_fcp_ms", "req_to_load_ms", "fcp", "load",
                                                                     "ttfb", "wait_ms", "busy", "longest", "resources", "bytes")}})
                    for m in raw:
                        emit(out, "load", {"arm": label, "round": r, "who": "raw", "page": name,
                                           **{k: m.get(k) for k in ("run", "app_overhead_ms", "req_to_fcp_ms", "req_to_load_ms", "fcp", "load",
                                                                     "ttfb", "finish_ms", "resources", "bytes")}})
                perf.quit_world(WORLD)


def scroll_pages():
    base = f"http://127.0.0.1:{FIXTURE_PORT}/pages"
    return [("local", SITE), ("table", f"{base}/table-01.html"), ("gallery", f"http://127.0.0.1:{FIXTURE_PORT}/hc-gallery.html"),
            ("article", f"{base}/article-04.html")]


def js_value(raw):
    v = raw.get("value") if isinstance(raw, dict) else None
    try:
        return json.loads(v) if isinstance(v, str) else v
    except Exception:
        return {"raw": str(v)[:200]}


def smooth(out, arms_):
    """A5 (Retina): scripted scroll of 4 pages, then canvas-big and canvas-easel pan+zoom
    (canvas-big/measure.js), 5 runs each, per arm."""
    runs = N("HC_SMOOTH_RUNS", 5)
    js = open(os.path.join(HERE, "scroll.js")).read()
    for r in range(N("HC_SMOOTH_ROUNDS", 1)):
        for label, app in order(arms_, r):
            with locked():
                start(app)
                time.sleep(10)
                for name, url in scroll_pages():
                    tid = ask({"do": "open", "url": url}).get("id")
                    ask({"do": "select", "id": tid})
                    ask({"do": "wait", "id": tid, "seconds": 30}, 40)
                    time.sleep(3)
                    for i in range(runs):
                        first = js_value(ask({"do": "eval", "id": tid, "js": js}))
                        res = None
                        time.sleep(4.3)
                        for _ in range(30):
                            res = js_value(ask({"do": "eval", "id": tid, "js": js}))
                            if isinstance(res, dict) and res.get("state") != "running":
                                break
                            time.sleep(0.3)
                        emit(out, "scroll", {"arm": label, "round": r, "page": name, "run": i,
                                             "start": first, **((res or {}).get("run") or {"error": res})})
                        time.sleep(1)
                    ask({"do": "close", "id": tid})
                perf.quit_world(WORLD)
                canvas(out, label, app, r, runs)


def copper_cli(app):
    return os.path.join(app, "Contents", "Resources", "bin", "copper")


def canvas(out, label, app, r, runs):
    port = int(os.environ.get("HC_CANVAS_PORT", "4137"))  # not 4131: the mini's easel service listens there
    env = {**os.environ, "SEARCH_PROBE": CANVAS_WORLD, "SEARCH_MCP_PORT": str(port), "COPPER_BIN": copper_cli(app),
           "FIXTURE_OUT": CANVAS_OUT, "FIXTURE_PORT": str(FIXTURE_PORT)}
    # Its own world (the boards persist there), not re-seeded; the window the bench view assumes.
    perf.quit_world(CANVAS_WORLD)
    flags = ["-n", "-a"] if MODE == "fg" else ["-n", "-g", "-a"]
    sub = os.path.join(perf.folder(CANVAS_WORLD))
    os.makedirs(sub, exist_ok=True)
    started = time.time()
    subprocess.run(["open", *flags, app, *env_for(CANVAS_WORLD, port, "1840x1240")], check=True)
    for _ in range(240):
        if subprocess.run([copper_cli(app), "health"], env=env, capture_output=True).returncode == 0:
            break
        time.sleep(0.25)
    env["FIXTURE_PROBE_STARTED"] = str(int(started))
    ids_path = os.path.join(sub, "hc-canvas-ids.json")
    ids = json.load(open(ids_path)) if os.path.exists(ids_path) else {}
    big = os.path.join(FIX, "canvas-big")
    if "big" not in ids:
        p = subprocess.run([sys.executable, os.path.join(big, "drive.py"), "apply", "HC big", "big"], env=env, capture_output=True, text=True, timeout=600)
        m = re.search(r"id=(\S+)", p.stdout)
        if m and m.group(1) != "None":
            ids["big"] = m.group(1)
    if "easel" not in ids:
        p = subprocess.run([sys.executable, os.path.join(FIX, "canvas-easel", "bench.py"), "apply", "HC easel"], env=env, capture_output=True, text=True, timeout=600)
        try:
            ids["easel"] = json.loads(p.stdout.strip().splitlines()[-1])["id"]
        except Exception:
            print("easel apply failed:", p.stdout[-400:], p.stderr[-400:])
    json.dump(ids, open(ids_path, "w"))
    if "big" in ids:
        focus = json.load(open(os.path.join(CANVAS_OUT, "big", "manifest.json")))["focusIds"]
        cli = copper_cli(app)
        subprocess.run([cli, "call", "canvas_open", json.dumps({"id": ids["big"], "foreground": True})], env=env, capture_output=True)
        time.sleep(1.5)
        subprocess.run([cli, "call", "canvas_focus", json.dumps({"id": ids["big"], "shapeIds": focus})], env=env, capture_output=True)
        time.sleep(20)
        for i in range(runs):
            p = subprocess.run([sys.executable, os.path.join(big, "drive.py"), "measure"], env=env, capture_output=True, text=True, timeout=120)
            try:
                m = json.loads(p.stdout)
                emit(out, "canvas", {"arm": label, "round": r, "board": "big", "run": i, **m["run"],
                                     "dpr_hint": m["before"].get("viewport"), "webContent": m.get("webContent", {}).get("totalMB")})
            except Exception:
                emit(out, "canvas", {"arm": label, "round": r, "board": "big", "run": i, "error": (p.stdout + p.stderr)[-300:]})
            time.sleep(3)
    if "easel" in ids:
        p = subprocess.run([sys.executable, os.path.join(FIX, "canvas-easel", "bench.py"), "measure", ids["easel"], "section", str(runs)],
                           env=env, capture_output=True, text=True, timeout=600)
        try:
            m = json.loads(p.stdout.strip().splitlines()[-1])
            for i, run in enumerate(m["runs"]):
                emit(out, "canvas", {"arm": label, "round": r, "board": "easel", "run": i, **run})
        except Exception:
            emit(out, "canvas", {"arm": label, "round": r, "board": "easel", "error": (p.stdout + p.stderr)[-300:]})
    perf.quit_world(CANVAS_WORLD)


# ---------- summary ----------

def stats(xs):
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    if not xs:
        return None
    p90 = xs[min(len(xs) - 1, max(0, -(-9 * len(xs) // 10) - 1))]  # nearest rank
    return {"median": round(statistics.median(xs), 2), "p90": round(p90, 2), "n": len(xs),
            "min": round(xs[0], 2), "max": round(xs[-1], 2), "spread": round(xs[-1] - xs[0], 2)}


def rows(d, phase):
    p = os.path.join(d, "raw", phase + ".jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


# (key, unit, what) — the order perf.md shows them in
METRICS = [
    ("A1.launch.paint_ms", "ms", "warm launch → restored page first paint (page.paint, from process start)"),
    ("A1.launch.window_ms", "ms", "warm launch → window on screen"),
    ("A1.launch.ask_ms", "ms", "warm launch → restored page request (page.ask)"),
    ("A1.launch.first_pass_ms", "ms", "first run-loop pass of the launch"),
    ("A1.launch.busy_ms", "ms", "main-thread busy, launch → settled+3 s"),
    ("A2.space_switch.busy_ms", "ms", "main-thread ms per space switch"),
    ("A2.space_switch.longest_ms", "ms", "longest main-thread pass in a space switch"),
    ("A2.tab_switch.busy_ms", "ms", "main-thread ms per tab switch, page already loaded"),
    ("A2.tab_switch.longest_ms", "ms", "longest pass in a warm tab switch"),
    ("A2.tab_wake.busy_ms", "ms", "main-thread ms per switch to a sleeping tab (wakes it)"),
    ("A3.load.local.fcp_ms", "ms", "local page: request → first contentful paint (Copper)"),
    ("A3.load.local.raw_fcp_ms", "ms", "local page: same, bare WKWebView"),
    ("A3.load.local.overhead_pct", "%", "Copper over bare WebKit, local page FCP (medians)"),
    ("A3.load.local.app_overhead_ms", "ms", "local page: request → navigation timeOrigin (Copper)"),
    ("A3.load.local.raw_app_overhead_ms", "ms", "local page: same, bare WKWebView"),
    ("A3.load.wikipedia.fcp_ms", "ms", "Wikipedia article FCP (Copper)"),
    ("A3.load.wikipedia.raw_fcp_ms", "ms", "Wikipedia article FCP (bare)"),
    ("A3.load.wikipedia.overhead_pct", "%", "Copper over bare, Wikipedia FCP"),
    ("A3.load.wikipedia.app_overhead_ms", "ms", "Wikipedia: request → timeOrigin (Copper)"),
    ("A3.load.wikipedia.raw_app_overhead_ms", "ms", "Wikipedia: request → timeOrigin (bare)"),
    ("A3.load.github.fcp_ms", "ms", "GitHub repo page FCP (Copper)"),
    ("A3.load.github.raw_fcp_ms", "ms", "GitHub repo page FCP (bare)"),
    ("A3.load.github.overhead_pct", "%", "Copper over bare, GitHub FCP"),
    ("A3.load.github.app_overhead_ms", "ms", "GitHub: request → timeOrigin (Copper)"),
    ("A3.load.github.raw_app_overhead_ms", "ms", "GitHub: request → timeOrigin (bare)"),
    ("A3.load.busy_ms", "ms", "main-thread busy during one page load (all pages)"),
    ("A4.idle.total_mb", "MB", "idle footprint, app + every WebKit process it owns, seeded session"),
    ("A4.idle.app_mb", "MB", "idle footprint of the Copper process alone"),
    ("A4.idle.pages_loaded", "", "pages loaded at idle (pins + restored)"),
    ("A4.loaded.total_mb", "MB", "footprint after 12 tabs were visited"),
    ("A4.mb_per_page", "MB", "footprint per loaded page (bench heat)"),
    ("A5.scroll.local.p95_ms", "ms", "scroll frame time p95, local 600-row page"),
    ("A5.scroll.local.janky", "", "frames > 1.5× refresh (dropped) per 4 s scroll, local page"),
    ("A5.scroll.table.p95_ms", "ms", "scroll p95, 3,000-row live table"),
    ("A5.scroll.table.janky", "", "frames > 1.5× refresh (dropped), table"),
    ("A5.scroll.gallery.p95_ms", "ms", "scroll p95, image gallery (100 KB–2.3 MB images)"),
    ("A5.scroll.gallery.janky", "", "frames > 1.5× refresh (dropped), gallery"),
    ("A5.scroll.article.p95_ms", "ms", "scroll p95, long article"),
    ("A5.scroll.article.janky", "", "frames > 1.5× refresh (dropped), article"),
    ("A5.scroll.dropped", "", "frames dropped vs the page's refresh, per 4 s scroll (all pages)"),
    ("A5.canvas.big.fps", "fps", "canvas-big bench view, 5 s pan+zoom"),
    ("A5.canvas.big.p95_ms", "ms", "canvas-big frame time p95"),
    ("A5.canvas.big.over33", "", "canvas-big frames > 33 ms"),
    ("A5.canvas.big.zoom_p95_ms", "ms", "canvas-big zoom-phase p95"),
    ("A5.canvas.easel.fps", "fps", "canvas-easel section view, pan+zoom"),
    ("A5.canvas.easel.p95_ms", "ms", "canvas-easel frame time p95"),
    ("A5.canvas.easel.zoom_p95_ms", "ms", "canvas-easel zoom-phase p95"),
    ("A5.canvas.easel.over33", "", "canvas-easel frames > 33 ms"),
    ("A6.idle.cpu_pct", "%", "idle CPU, app + its WebKit processes (% of one core)"),
    ("A6.idle.app_cpu_pct", "%", "idle CPU, Copper process alone"),
    ("A6.idle.wakeups_per_s", "/s", "idle + interrupt wakeups per second, all its processes"),
    ("A6.idle.main_busy_ms_per_min", "ms", "main-thread busy per idle minute (bench pace)"),
    ("A6.idle.main_passes_per_min", "", "main run-loop passes per idle minute"),
    ("A7.address.key_ms", "ms", "⌘T card: main-thread ms to take one typed letter"),
    ("A7.address.key_max_ms", "ms", "⌘T card: worst letter per word"),
    ("A7.address.longest_ms", "ms", "⌘T card: longest main-thread stretch while typing a word"),
    ("A7.address.over16", "", "⌘T card: stretches > 16.7 ms while typing a word"),
    ("A7.address.open_busy_ms", "ms", "⌘T: main-thread busy to open the card"),
    ("A7.address.history_ms", "ms", "⌘T: last letter → history rows on the card"),
    ("A7.cmdk.ms", "ms", "⌘K: summon + type + offers ready (bar)"),
]


def collect(d):
    """{metric: {arm: [values]}} from one OUT dir."""
    v = {}
    put = lambda k, arm, x: v.setdefault(k, {}).setdefault(arm, []).append(x) if x is not None else None
    for r in rows(d, "launch"):
        if r["round"] == 0:
            continue
        m = r.get("marks", {})
        put("A1.launch.paint_ms", r["arm"], m.get("page.paint"))
        put("A1.launch.window_ms", r["arm"], m.get("window"))
        put("A1.launch.ask_ms", r["arm"], m.get("page.ask"))
        put("A1.launch.first_pass_ms", r["arm"], r.get("firstPass"))
        put("A1.launch.busy_ms", r["arm"], r.get("launchBusy"))
    for r in rows(d, "session"):
        a = r["arm"]
        for s in r.get("spaces", []):
            put("A2.space_switch.busy_ms", a, s.get("busy"))
            put("A2.space_switch.longest_ms", a, s.get("longest"))
        for t in r.get("tabs", []):
            if t.get("was_built") and not t.get("was_asleep"):
                put("A2.tab_switch.busy_ms", a, t.get("busy"))
                put("A2.tab_switch.longest_ms", a, t.get("longest"))
            else:
                put("A2.tab_wake.busy_ms", a, t.get("busy"))
        mi, ml = r.get("mem_idle", {}), r.get("mem_loaded", {})
        put("A4.idle.total_mb", a, mi.get("total_mb"))
        put("A4.idle.app_mb", a, mi.get("by_kind", {}).get("app"))
        put("A4.idle.pages_loaded", a, len(r.get("heat_idle", [])))
        put("A4.loaded.total_mb", a, ml.get("total_mb"))
        for h in r.get("heat_loaded", []):
            put("A4.mb_per_page", a, h.get("mb"))
        i = r.get("idle", {})
        mins = (i.get("seconds") or 60) / 60
        put("A6.idle.cpu_pct", a, i.get("cpu_pct"))
        put("A6.idle.app_cpu_pct", a, i.get("app_cpu_pct"))
        put("A6.idle.wakeups_per_s", a, i.get("wakeups_per_s"))
        put("A6.idle.main_busy_ms_per_min", a, i.get("busy") / mins if i.get("busy") is not None else None)
        put("A6.idle.main_passes_per_min", a, i.get("passes") / mins if i.get("passes") is not None else None)
        for t in r.get("typing", []):
            for k in t.get("keyMs") or []:
                put("A7.address.key_ms", a, k)
            put("A7.address.key_max_ms", a, t.get("keyMaxMs"))
            put("A7.address.longest_ms", a, t.get("longestMs"))
            put("A7.address.over16", a, t.get("over16"))
            put("A7.address.open_busy_ms", a, t.get("openBusyMs"))
            h = t.get("historyMs")
            put("A7.address.history_ms", a, h if h is not None and h >= 0 else None)
        for b in r.get("bar", []):
            put("A7.cmdk.ms", a, b.get("ms"))
    for r in rows(d, "load"):
        if r.get("run") == 0:
            continue
        p, a = r["page"], r["arm"]
        if r["who"] == "copper":
            put(f"A3.load.{p}.fcp_ms", a, r.get("req_to_fcp_ms"))
            put(f"A3.load.{p}.app_overhead_ms", a, r.get("app_overhead_ms"))
            put("A3.load.busy_ms", a, r.get("busy"))
        else:
            put(f"A3.load.{p}.raw_fcp_ms", a, r.get("req_to_fcp_ms"))
            put(f"A3.load.{p}.raw_app_overhead_ms", a, r.get("app_overhead_ms"))
    for r in rows(d, "scroll"):
        if "p95" not in r:
            continue
        put(f"A5.scroll.{r['page']}.p95_ms", r["arm"], r.get("p95"))
        put(f"A5.scroll.{r['page']}.janky", r["arm"], r.get("janky"))
        put("A5.scroll.dropped", r["arm"], r.get("dropped"))
    for r in rows(d, "canvas"):
        if "p95" not in r:
            continue
        b = r["board"]
        put(f"A5.canvas.{b}.fps", r["arm"], r.get("fps"))
        put(f"A5.canvas.{b}.p95_ms", r["arm"], r.get("p95"))
        put(f"A5.canvas.{b}.over33", r["arm"], r.get("over33"))
        z = (r.get("phases") or {}).get("zoom") or {}
        put(f"A5.canvas.{b}.zoom_p95_ms", r["arm"], z.get("p95"))
    return v


def summary(dest, dirs):
    out = {"track": "perf", "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "machines": {}, "metrics": {}}
    arm_order = []
    for d in dirs:
        info = json.load(open(os.path.join(d, "machine.json")))
        host = os.path.basename(os.path.normpath(d))  # mini | laptop
        out["machines"][host] = info
        for a in info["arms"]:
            arm_order.append(a["label"]) if a["label"] not in arm_order else None
        loads = [r["loadavg"][0] for ph in ("launch", "session", "load", "scroll", "canvas") for r in rows(d, ph)]
        info["load_during"] = stats(loads)
        for k, per in collect(d).items():
            out["metrics"].setdefault(f"{k}@{host}", {})
            for arm, xs in per.items():
                out["metrics"][f"{k}@{host}"][arm] = stats(xs)
        # overhead % = Copper median / bare median − 1, per page
        for page in ("local", "wikipedia", "github"):
            c, w = out["metrics"].get(f"A3.load.{page}.fcp_ms@{host}", {}), out["metrics"].get(f"A3.load.{page}.raw_fcp_ms@{host}", {})
            for arm in c:
                if w.get(arm) and w[arm]["median"]:
                    out["metrics"].setdefault(f"A3.load.{page}.overhead_pct@{host}", {})[arm] = {
                        "median": round(100 * (c[arm]["median"] / w[arm]["median"] - 1), 1), "n": min(c[arm]["n"], w[arm]["n"])}
    out["arms"] = arm_order
    if len(arm_order) == 2:  # A/B: new vs base, with the base's spread as the noise band
        new, base = arm_order
        out["delta"] = {}
        for k, per in out["metrics"].items():
            if per.get(new) and per.get(base) and per[base].get("median"):
                band = per[base].get("spread")
                d = per[new]["median"] - per[base]["median"]
                out["delta"][k] = {"abs": round(d, 2), "pct": round(100 * d / per[base]["median"], 1),
                                   "beyond_noise": band is not None and abs(d) > band}
    os.makedirs(dest, exist_ok=True)
    json.dump(out, open(os.path.join(dest, "perf.json"), "w"), indent=1)
    open(os.path.join(dest, "perf.md"), "w").write(markdown(out))
    print(os.path.join(dest, "perf.json"))


def markdown(o):
    arms_ = o["arms"]
    fmt = lambda s: "—" if not s else (f"{s['median']:g}" + (f" (p90 {s['p90']:g}, ±{s['spread']:g}, n={s['n']})" if "p90" in s else f" (n={s['n']})"))
    lines = [f"# Copper perf (Track A) — {' vs '.join(arms_)}", "", f"Generated {o['created']} by `perf/hillclimb/perf.sh`.", ""]
    for host, m in o["machines"].items():
        ld = m.get("load_during") or {}
        lines.append(f"- **{host}**: {m['model']}, macOS {m['macos']}, {', '.join(m['displays'])}, mode `{m['mode']}`, "
                     f"seed {m.get('seed_tabs')} tabs, load avg during runs {ld.get('min')}–{ld.get('max')} (median {ld.get('median')})")
    lines += ["", "Cells: median (p90, ±spread = max−min, n). Lower is better except fps.", "",
              "| metric | " + " | ".join(arms_) + (" | Δ" if len(arms_) == 2 else "") + " | what |",
              "|---|" + "---|" * len(arms_) + ("---|" if len(arms_) == 2 else "") + "---|"]
    whats = {k: (u, w) for k, u, w in METRICS}
    keys = sorted(o["metrics"], key=lambda k: ([m[0] for m in METRICS].index(k.split("@")[0]) if k.split("@")[0] in whats else 999, k))
    for k in keys:
        base = k.split("@")[0]
        u, w = whats.get(base, ("", ""))
        cells = [fmt(o["metrics"][k].get(a)) for a in arms_]
        delta = ""
        if len(arms_) == 2:
            d = o.get("delta", {}).get(k)
            delta = f" {d['pct']:+g}%{' ⚠' if d['beyond_noise'] else ''} |" if d else " — |"
        lines.append(f"| `{k}` {u} | " + " | ".join(cells) + " |" + delta + f" {w} |")
    lines.append("")
    return "\n".join(lines)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    phase, out = argv[0], os.path.expanduser(argv[1])
    if phase == "summary":
        return summary(out, argv[2:])
    a = arms(argv[2:])
    {"setup": setup, "launch": launch, "session": session, "load": load, "smooth": smooth}[phase](out, a)


if __name__ == "__main__":
    def bye(*_):
        perf.quit_world(WORLD); perf.quit_world(CANVAS_WORLD); sys.exit(130)
    signal.signal(signal.SIGTERM, bye)
    try:
        main(sys.argv[1:])
    except KeyboardInterrupt:
        bye()
    finally:
        if sys.argv[1:2] != ["summary"]:
            perf.quit_world(WORLD)
