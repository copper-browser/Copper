#!/usr/bin/env python3
"""Track A (Mac performance) driver for perf/hillclimb/perf.sh. Runs on the Mac.

    run.py setup   OUT ARM...       machine info, local pages, RawLoad.app, canvas fixture pages
    run.py launch  OUT ARM...       A1: warm launches alternating arms, `bench pace` marks
    run.py cold    OUT ARM...       A1 cold: each launch from a fresh copy of the .app (COLD_NOTE)
    run.py session OUT ARM...       A2 A4 A6 A7: per launch: idle cost, memory, space + tab switches, typing
    run.py load    OUT ARM...       A3: Copper page loads vs bare WKWebView (rawload.swift), same pages
    run.py smooth  OUT ARM...       A5: scroll + canvas frame times (run on the Retina laptop)
    run.py hooks   OUT ARM...       A7 `bench keylat` ⌘T/⌘K, A5 `bench wheel` at 120 Hz (HOOKS-SPEC.md);
                                    a build without the hooks gives "n/a: hook missing"
    run.py summary DEST DIR...      perf.json + perf.md from one or more OUT dirs (any machine)

ARM = label=/path/to/Copper.app. Rows land in OUT/raw/<phase>.jsonl. Every launch re-seeds the
probe world from HC_SEED (a frozen copy of a real session: tabs, spaces, history, icons; never
cookies or passwords) so every launch of every arm starts from the same state.
"""
import ctypes, fcntl, glob, json, os, platform, re, shutil, signal, socket, statistics, subprocess, sys, time
from contextlib import contextmanager

HOME = os.path.expanduser("~")
TOOLS = os.path.expanduser(os.environ.get("HC_TOOLS", f"{HOME}/hc/tools"))
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(TOOLS, "perf"))
import perf  # noqa: E402  (perf/perf.py: ask, seed, spaces, tabs, load, quit_world)

WORLD = os.environ.get("HC_WORLD", "hcperf")
CANVAS_WORLD = WORLD + "canvas"
PORT = int(os.environ.get("HC_PORT", "4130"))       # 4130–4239 (each worker its own range), never 4123
SITE_PORT = int(os.environ.get("HC_SITE_PORT", "4139"))
FIXTURE_PORT = int(os.environ.get("HC_FIXTURE_PORT", "4138"))
SEED = os.path.expanduser(os.environ.get("HC_SEED", f"{HOME}/hc/seed"))
LOCK = os.environ.get("HC_LOCK", "")                # ~/hc/mini.lock on the mini (flock = what lockf(1) takes)
MODE = os.environ.get("HC_MODE", "fg")              # fg (mini) | headless (laptop: never steals focus)
N = lambda k, d: int(os.environ.get(k, d))
SITE = f"http://127.0.0.1:{SITE_PORT}/index.html"
CANVAS_OUT = os.path.expanduser(os.environ.get("HC_CANVAS_OUT", f"{HOME}/hc/canvas-out"))  # serve.sh keeps its pid here
FIX = os.path.join(TOOLS, "docs/fixtures")
LAPTOP = os.environ.get("HC_HOST") == "laptop"
LOAD_MAX = 3.0  # laptop samples count only when the 1-min load average is below this (SCOREBOARD)
for _p in (PORT, SITE_PORT, FIXTURE_PORT, int(os.environ.get("HC_CANVAS_PORT", "4137"))):
    assert _p != 4123 and 4130 <= _p <= 4239, "perf ports: 4130–4239 (each worker its own range), never 4123"
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
    if LAPTOP:  # give Collin's machine a moment to calm down, so more samples pass the load filter
        end = time.time() + N("HC_LOAD_WAIT", 60)
        while os.getloadavg()[0] >= LOAD_MAX and time.time() < end:
            time.sleep(5)
    load0 = round(os.getloadavg()[0], 2)  # the background load this sample starts on (the filter's input)
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
            "pid": perf.pid_of(world), "load0": load0}


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
    phases = os.environ.get("HC_PHASES", "").split()
    if "smooth" in phases or "hooks" in phases:  # both scroll the fixture pages
        man = os.path.join(CANVAS_OUT, "big", "manifest.json")
        if "smooth" in phases and not os.path.exists(man):
            subprocess.run([sys.executable, os.path.join(FIX, "canvas-big", "gen.py"), "--scale", "big", "--out", CANVAS_OUT,
                            "--base", f"http://127.0.0.1:{FIXTURE_PORT}", "-q"], check=True)
        subprocess.run([os.path.join(FIX, "canvas-big", "serve.sh"), "start"], check=True,  # builds www/ if missing
                       env={**os.environ, "FIXTURE_PORT": str(FIXTURE_PORT), "FIXTURE_OUT": CANVAS_OUT})
        # A long image page for A5: every fixture image three times (distinct URLs, so each decodes).
        imgs = sorted(f for f in os.listdir(os.path.join(CANVAS_OUT, "www", "img")) if f != "favicon.png")
        figs = "".join(f'<figure><img src="/img/{f}?c={c}"><figcaption>{f}</figcaption></figure>' for c in range(3) for f in imgs)
        open(os.path.join(CANVAS_OUT, "www", "hc-gallery.html"), "w").write(
            "<!doctype html><title>HC gallery</title><style>body{margin:0;font:12px Menlo}.g{display:grid;grid-template-columns:repeat(3,1fr);"
            "gap:12px;padding:20px}img{width:100%;height:220px;object-fit:cover;border-radius:8px;box-shadow:0 6px 20px rgba(0,0,0,.25)}"
            f"figure{{margin:0}}</style><div class=g>{figs}</div>")
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
    app = os.path.join(HOME, "hc", "RawLoad.app")
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


# A1 cold without sudo (no `purge`): what it does and doesn't cover is COLD_NOTE, printed in perf.md.
COLD_NOTE = ("**A1.cold** = first launch after an update, without sudo: each launch runs a fresh APFS clone (`cp -c`) of the .app at a "
             "new path (its binary + resources not in the page cache: `binary_resident_pct` shows it, via mincore; code "
             "signature validated again; no dyld closure; LaunchServices registers it anew) with the world's WebKit store "
             "deleted. It does NOT cover a boot-cold Mac: macOS's own frameworks (WebKit, AppKit, SwiftUI in the shared "
             "cache), WebKit's XPC services and fonts stay warm (`purge` needs sudo). A1.launch.* is warm (round 0 dropped).")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def resident_pct(path):
    """% of PATH's pages in the page cache (mincore on a read-only mapping; vmtouch's way, no sudo)."""
    libc = ctypes.CDLL(None)
    libc.mmap.restype = ctypes.c_void_p
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int64]
    libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p]
    libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    size, fd = os.path.getsize(path), os.open(path, os.O_RDONLY)
    try:
        addr = libc.mmap(None, size, 1, 1, fd, 0)  # PROT_READ, MAP_SHARED
        pages = -(-size // os.sysconf("SC_PAGE_SIZE"))
        vec = ctypes.create_string_buffer(pages)
        libc.mincore(addr, size, vec)
        libc.munmap(addr, size)
        return round(100 * sum(b & 1 for b in vec.raw) / pages, 1)
    finally:
        os.close(fd)


def world_store(app, world=WORLD):
    """The world's own WebKit store (Store.probeStore(1): FNV-1a of the world name), never another world's."""
    h = 2166136261
    for b in world.encode():
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    bundle = subprocess.run(["defaults", "read", app + "/Contents/Info", "CFBundleIdentifier"], capture_output=True, text=True).stdout.strip()
    assert bundle and bundle != "com.collinrijock.copper", "never the installed Copper's container"
    return os.path.join(HOME, "Library/WebKit", bundle, "WebsiteDataStore", f"5e4c{h >> 16:04x}-{h & 0xFFFF:04x}-4000-8000-000000000001")


def cold(out, arms_):
    """A1 cold (COLD_NOTE): HC_COLD launches per arm, arms alternating; none dropped."""
    base = os.path.join(HOME, "hc", f"cold-{WORLD}")
    for r in range(N("HC_COLD", 6)):
        for label, app in order(arms_, r):
            copy = os.path.join(base, f"{label}-{r}-{int(time.time())}", "Copper.app")
            with locked():
                perf.quit_world(WORLD)
                os.makedirs(os.path.dirname(copy))
                subprocess.run(["cp", "-cR", app, copy], check=True)  # an APFS clone: fresh vnodes, nothing cached (plain ditto caches on macOS 26)
                res = resident_pct(os.path.join(copy, "Contents", "MacOS", "Copper"))
                shutil.rmtree(world_store(app), ignore_errors=True)
                try:
                    t = start(copy)
                    time.sleep(3)
                    pace = ask({"do": "pace"})
                    emit(out, "cold", {"arm": label, "round": r, **t, "binary_resident_pct": res, "marks": pace.get("marks", {}),
                                       "launchBusy": pace.get("launchBusy")})
                finally:
                    perf.quit_world(WORLD)
                    subprocess.run([LSREGISTER, "-u", copy], capture_output=True)  # no stale copies in LaunchServices
                    shutil.rmtree(os.path.dirname(copy), ignore_errors=True)


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
    row["spaces"] = space_switches()
    so, sys.stdout = sys.stdout, quiet  # perf.py prints its rows; we keep them in ours
    try:
        tb = perf.tabs(WORLD, 2, 12)
    finally:
        sys.stdout = so
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
    # ⌘K typed a letter at a time (`bench bar TEXT --type`, PR #144); a build without it types into ⌘T instead.
    row["bar_typing"] = []
    for w in TYPE_WORDS:
        x = ask({"do": "newtab", "summon": True, "text": w, "type": True, "every": 0.08, "settle": 1.5})
        row["bar_typing"].append({k: x.get(k) for k in ("typed", "keyMs", "keyMaxMs", "openBusyMs", "longestMs", "over16", "historyMs")})
        time.sleep(0.5)
    row["bar"] = []
    for q in BAR_QUERIES:
        x = ask({"do": "bar", "text": q})
        row["bar"].append({"q": q, "ms": x.get("milliseconds"), "offers": len(x.get("offers", []))})
        time.sleep(0.3)
    perf.quit_world(WORLD)
    emit(out, "session", row)


def space_switches():
    """A2: from the space on screen to every other space and back, never to the one already current
    (that only measured leftover work). Per switch: tabs in the space, rows the column shows (folders
    shut = one row), and whether the tab it lands on was built before (warm) or asleep (wakes its page)."""
    spaces_ = ask({"do": "spaces", "op": "list", "arg": ""}).get("spaces", [])
    home = next((s["index"] for s in spaces_ if s.get("current")), 0)
    counts = {s["index"]: s.get("tabs") for s in spaces_}
    big = max(counts, key=lambda i: counts[i] or 0) if counts else None  # the seed's ~185-tab space
    rows = []
    for n in [i for i in counts if i != home] + [home]:
        ask({"do": "pace", "op": "reset"})
        t0 = time.time()
        ask({"do": "spaces", "op": "select", "arg": str(n)})
        ack = round((time.time() - t0) * 1000)
        time.sleep(0.05)
        first = next((t for t in ask({"do": "tabs"}).get("tabs", []) if t.get("active")), {})
        time.sleep(0.85)
        pace = ask({"do": "pace"})
        slide = ask({"do": "spaces", "op": "slide", "arg": ""}).get("slide", {})
        visible = sum(len(ask({"do": "groups", "op": "plan", "arg": a}).get("plan", [])) for a in ("", "today"))
        rows.append({"to": n, "ack_ms": ack, "busy": pace.get("busy"), "longest": pace.get("longest"), "tabs": counts.get(n),
                     "rows": visible, "big": n == big, "back": n == home,
                     # loading right after the switch = the landing tab's page was asleep and is waking
                     "landing": "sleeping" if first.get("loading") or not first.get("view") else "warm",
                     "slide": {k: slide.get(k) for k in ("frames", "longest", "missed")}})
    return rows


LOAD_PAGES = [("local", SITE), ("wikipedia", "https://en.wikipedia.org/wiki/WebKit"),
              ("github", "https://github.com/WebKit/WebKit")]


def rawload(url, runs):
    app = rawload_app()
    path = f"/tmp/hc-rawload-{os.getpid()}.txt"
    if os.path.exists(path):
        os.unlink(path)
    subprocess.run(["open", "-W", "-n", "-g", app, "--stdout", path, "--args", url, str(runs)], check=True, timeout=300)
    rows = []
    for line in open(path):
        if line.startswith("{"):
            m = json.loads(line)
            m.pop("list", None); m.pop("events", None)
            rows.append(m)
    os.unlink(path)
    return rows


def load(out, arms_):
    """A3: N loads of each page in a fresh Copper tab, then N in a fresh bare WKWebView, interleaved
    per page so the network is the same for both. The first of each N is dropped (cold DNS/cache)."""
    n = N("HC_LOADS", 6)
    quiet = open(os.devnull, "w")
    for r in range(N("HC_LOAD_ROUNDS", 1)):
        for label, app in order(arms_, r):
            with locked():
                l0 = start(app)["load0"]
                time.sleep(10)
                for name, url in LOAD_PAGES:
                    so, sys.stdout = sys.stdout, quiet
                    try:
                        rows = perf.load(WORLD, url, n)
                    finally:
                        sys.stdout = so
                    for m in rows:
                        emit(out, "load", {"arm": label, "round": r, "who": "copper", "page": name, "load0": l0,
                                           **{k: m.get(k) for k in ("run", "app_overhead_ms", "req_to_fcp_ms", "req_to_load_ms", "fcp", "load",
                                                                     "ttfb", "wait_ms", "busy", "longest", "resources", "bytes")}})
                    for m in rawload(url, n):
                        emit(out, "load", {"arm": label, "round": r, "who": "raw", "page": name, "load0": l0,
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
                l0 = start(app)["load0"]
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
                        emit(out, "scroll", {"arm": label, "round": r, "page": name, "run": i, "load0": l0,
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
    started, l0 = time.time(), round(os.getloadavg()[0], 2)
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
                emit(out, "canvas", {"arm": label, "round": r, "board": "big", "run": i, "load0": l0, **m["run"],
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
                emit(out, "canvas", {"arm": label, "round": r, "board": "easel", "run": i, "load0": l0, **run})
        except Exception:
            emit(out, "canvas", {"arm": label, "round": r, "board": "easel", "error": (p.stdout + p.stderr)[-300:]})
    perf.quit_world(CANVAS_WORLD)


# ---------- hooks (HOOKS-SPEC.md): key → pixel, real 120 Hz wheel ----------

HOOK_MISSING = "n/a: hook missing (needs hc/hooks)"
KEYLAT_KEYS = [("⌘t", "cmd_t", "launching"), ("⌘k", "cmd_k", "summoning")]  # (key, metric name, the flag it should raise)


def hook(req, timeout=60):
    """A bench hook, sent as the bench CLI sends it → (answer, None) or (None, why it can't be measured)."""
    x = ask(req, timeout)
    if "unknown command" in str(x.get("error", "")):
        return None, HOOK_MISSING
    return (None, f"n/a: hook error: {x['error']}") if x.get("error") else (x, None)


def hooks(out, arms_):
    """One launch per arm per round: `bench keylat` for ⌘T and ⌘K, then `bench wheel` on every scroll page."""
    for r in range(N("HC_HOOK_ROUNDS", 1)):
        for label, app in order(arms_, r):
            with locked():
                base = {"arm": label, "round": r, "load0": start(app)["load0"]}
                time.sleep(10)
                keylat(out, base)
                # the wheel on the laptop only (HC_WHEEL=1 forces it): ProMotion, and the mini's fg window
                # can be covered by other probes' windows, which stops the page's rAF
                for page, url in scroll_pages() if LAPTOP or os.environ.get("HC_WHEEL") == "1" else []:
                    if not wheel(out, {**base, "page": page}, url):
                        break
                perf.quit_world(WORLD)


def keylat(out, base):
    """HC_PRESSES presses each of ⌘T and ⌘K; ⎋ closes the card/bar between presses."""
    for key, name, flag in KEYLAT_KEYS:
        for i in range(N("HC_PRESSES", 20)):
            x, why = hook({"do": "keylat", "key": key})
            if why:  # no hook, or it can't answer here: one row says so, no more presses
                return emit(out, "keylat", {**base, "missing": why})
            time.sleep(0.4)
            esc = hook({"do": "keylat", "key": "⎋"})[0] or {}
            emit(out, "keylat", {**base, **x, "key": name, "i": i, "opened": x.get(flag), "esc": esc})
            time.sleep(0.4)


def wheel(out, base, url):
    """HC_WHEEL_RUNS gestures of HC_WHEEL_DY points over HC_WHEEL_STEPS ticks at 120 Hz on URL, under
    wheel.js's rAF recorder. False when the build has no wheel hook."""
    runs, dy, steps = N("HC_WHEEL_RUNS", 5), N("HC_WHEEL_DY", 2400), N("HC_WHEEL_STEPS", 120)
    js = open(os.path.join(HERE, "wheel.js")).read()
    tid = ask({"do": "open", "url": url}).get("id")
    ask({"do": "select", "id": tid})
    ask({"do": "wait", "id": tid, "seconds": 30}, 40)
    time.sleep(3)
    sign = 1  # + is down (bench wheel); flipped once if the first gesture didn't move the page
    try:
        for i in range(runs):
            ask({"do": "eval", "id": tid, "js": "(document.scrollingElement||document.documentElement).scrollTop=0"})
            time.sleep(0.5)
            ask({"do": "eval", "id": tid, "js": js.replace("__MODE__", "start")})
            x, why = hook({"do": "wheel", "dy": float(sign * dy), "steps": steps, "hz": 120.0}, 30)  # the bench CLI's request
            if why:
                emit(out, "wheel", {**base, "missing": why})
                return False
            time.sleep(0.5)  # the last frames land
            res = js_value(ask({"do": "eval", "id": tid, "js": js.replace("__MODE__", "stop")})) or {}
            emit(out, "wheel", {**base, "run": i, "dy": sign * dy, "hook": x, **res})
            if i == 0 and not res.get("moved"):
                sign = -sign
        return True
    finally:
        ask({"do": "close", "id": tid})


# ---------- summary ----------

def stats(xs, thr=None):
    """p50 (also under "median", what the Δ column reads), p90 (nearest rank), max; `over` = samples above
    the metric's target threshold when it has one ("no pass > 50 ms")."""
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    if not xs:
        return None
    p90 = xs[min(len(xs) - 1, max(0, -(-9 * len(xs) // 10) - 1))]
    s = {"median": round(statistics.median(xs), 2), "p50": round(statistics.median(xs), 2), "p90": round(p90, 2), "n": len(xs),
         "min": round(xs[0], 2), "max": round(xs[-1], 2), "spread": round(xs[-1] - xs[0], 2)}
    if thr is not None:
        s["over"], s["thr"] = sum(x > thr for x in xs), thr
    return s


def rows(d, phase):
    p = os.path.join(d, "raw", phase + ".jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


SCROLL = ["local", "table", "gallery", "article"]
# (key, unit, what[, threshold]) — the order perf.md shows them in; a threshold adds "> T: k/n" to the cell
METRICS = [
    ("A1.launch.paint_ms", "ms", "warm launch → restored page first paint (page.paint, from process start)"),
    ("A1.launch.window_ms", "ms", "warm launch → window on screen"),
    ("A1.launch.ask_ms", "ms", "warm launch → restored page request (page.ask)"),
    ("A1.launch.first_pass_ms", "ms", "first run-loop pass of the launch"),
    ("A1.launch.busy_ms", "ms", "main-thread busy, launch → settled+3 s"),
    ("A1.cold.paint_ms", "ms", "cold launch (fresh copy of the .app, see header) → restored page first paint"),
    ("A1.cold.window_ms", "ms", "cold launch → window on screen"),
    ("A1.cold.ask_ms", "ms", "cold launch → restored page request (page.ask)"),
    ("A1.cold.busy_ms", "ms", "cold launch: main-thread busy, launch → settled+3 s"),
    ("A1.cold.socket_ms", "ms", "cold launch: `open` → bench socket answers (harness clock, incl. LaunchServices)"),
    ("A1.cold.binary_resident_pct", "%", "Copper binary pages in the page cache just before the cold launch (want 0)"),
    ("A2.space_switch.busy_ms", "ms", "main-thread ms per space switch, landing tab warm (all but the biggest space)"),
    ("A2.space_switch.longest_ms", "ms", "longest main-thread pass in a space switch, landing tab warm (all but the biggest)", 50),
    ("A2.space_switch.big.busy_ms", "ms", "main-thread ms per switch to the seed's biggest space (~185 tabs), landing tab warm"),
    ("A2.space_switch.big.longest_ms", "ms", "longest pass in a switch to the biggest space, landing tab warm", 50),
    ("A2.space_switch.wake.busy_ms", "ms", "space switch whose landing tab was asleep (its page wakes: page cost, not rows)"),
    ("A2.space_switch.wake.longest_ms", "ms", "longest pass in a switch whose landing tab was asleep", 50),
    ("A2.tab_switch.busy_ms", "ms", "main-thread ms per tab switch, page already loaded"),
    ("A2.tab_switch.longest_ms", "ms", "longest pass in a warm tab switch"),
    ("A2.tab_wake.busy_ms", "ms", "main-thread ms per switch to a sleeping tab (wakes it)"),
    *[x for p, n in (("local", "local page"), ("wikipedia", "Wikipedia article"), ("github", "GitHub repo page")) for x in (
        (f"A3.load.{p}.fcp_ms", "ms", f"{n}: request → first contentful paint (Copper)"),
        (f"A3.load.{p}.raw_fcp_ms", "ms", f"{n}: same, bare WKWebView"),
        (f"A3.load.{p}.overhead_pct", "%", f"{n}: Copper over bare WebKit FCP (p50 vs p50, p90 vs p90)"),
        (f"A3.load.{p}.app_overhead_ms", "ms", f"{n}: request → navigation timeOrigin (Copper)"),
        (f"A3.load.{p}.raw_app_overhead_ms", "ms", f"{n}: same, bare WKWebView"))],
    ("A3.load.busy_ms", "ms", "main-thread busy during one page load (all pages)"),
    ("A4.idle.total_mb", "MB", "idle footprint, app + every WebKit process it owns, seeded session"),
    ("A4.idle.app_mb", "MB", "idle footprint of the Copper process alone"),
    ("A4.idle.pages_loaded", "", "pages loaded at idle (pins + restored)"),
    ("A4.loaded.total_mb", "MB", "footprint after 12 tabs were visited"),
    ("A4.mb_per_page", "MB", "footprint per loaded page (bench heat)"),
    *[x for p in SCROLL for x in (
        (f"A5.scroll.{p}.p95_ms", "ms", f"scripted scrollTop scroll, frame time p95 per run, {p} page"),
        (f"A5.scroll.{p}.janky", "", f"frames > 1.5× refresh per 4 s scroll, {p} page"))],
    ("A5.scroll.dropped", "", "frames dropped vs the page's refresh, per 4 s scripted scroll (all pages)"),
    ("A5.wheel.dropped_pct", "%", "real wheel (`bench wheel`, 120 Hz): % frames dropped vs 120 Hz per gesture, all pages", 1),
    *[x for p in SCROLL for x in (
        (f"A5.wheel.{p}.dropped_pct", "%", f"wheel, {p} page: % frames dropped vs 120 Hz per gesture", 1),
        (f"A5.wheel.{p}.frame_ms", "ms", f"wheel, {p} page: rAF frame interval, every frame of every gesture", 8.33))],
    ("A5.wheel.refresh_ms", "ms", "wheel: the page's own frame interval (median per gesture; 8.33 = 120 Hz)"),
    ("A5.wheel.hook.hz", "Hz", "wheel hook: the display link's rate (asked 120; a 60 Hz display gives 60)"),
    ("A5.wheel.hook.tick_p90_ms", "ms", "wheel hook: display-link tick interval p90 per gesture"),
    ("A5.wheel.hook.tick_max_ms", "ms", "wheel hook: worst tick interval per gesture"),
    ("A5.wheel.hook.missed_ticks", "", "wheel hook: ticks > 1.5× nominal per gesture"),
    ("A5.wheel.hook.send_p90_ms", "ms", "wheel hook: window.sendEvent time p90 per gesture"),
    ("A5.canvas.big.fps", "fps", "canvas-big bench view, 5 s pan+zoom"),
    ("A5.canvas.big.p95_ms", "ms", "canvas-big frame time p95 per run"),
    ("A5.canvas.big.over33", "", "canvas-big frames > 33 ms per run"),
    ("A5.canvas.big.zoom_p95_ms", "ms", "canvas-big zoom-phase p95 per run", 33),
    ("A5.canvas.easel.fps", "fps", "canvas-easel section view, pan+zoom"),
    ("A5.canvas.easel.p95_ms", "ms", "canvas-easel frame time p95 per run"),
    ("A5.canvas.easel.zoom_p95_ms", "ms", "canvas-easel zoom-phase p95 per run", 33),
    ("A5.canvas.easel.over33", "", "canvas-easel frames > 33 ms per run"),
    ("A6.idle.cpu_pct", "%", "idle CPU, app + its WebKit processes (% of one core)"),
    ("A6.idle.app_cpu_pct", "%", "idle CPU, Copper process alone"),
    ("A6.idle.wakeups_per_s", "/s", "idle + interrupt wakeups per second, all its processes"),
    ("A6.idle.main_busy_ms_per_min", "ms", "main-thread busy per idle minute (bench pace)"),
    ("A6.idle.main_passes_per_min", "", "main run-loop passes per idle minute"),
    ("A7.address.key_ms", "ms", "⌘T card: main-thread ms to take one typed letter"),
    ("A7.address.key_max_ms", "ms", "⌘T card: worst letter per word"),
    ("A7.address.longest_ms", "ms", "⌘T card: longest main-thread stretch while typing a word", 16.7),
    ("A7.address.over16", "", "⌘T card: stretches > 16.7 ms while typing a word"),
    ("A7.address.open_busy_ms", "ms", "⌘T: main-thread busy to open the card"),
    ("A7.address.history_ms", "ms", "⌘T: last letter → history rows on the card"),
    ("A7.cmdk.ms", "ms", "⌘K: summon + type + offers ready (bar), per query; synchronous on the main thread", 16.7),
    ("A7.cmdk.key_ms", "ms", "⌘K typed a letter at a time (`bench bar --type`, #144): main-thread ms per letter; a build without #144 types into ⌘T", 10),
    ("A7.cmdk.key_max_ms", "ms", "⌘K typing: worst letter per word", 16.7),
    ("A7.cmdk.longest_ms", "ms", "⌘K typing: longest main-thread stretch per word", 16.7),
    *[x for k, n in (("cmd_t", "⌘T"), ("cmd_k", "⌘K"), ("esc", "⎋ closing it")) for x in (
        (f"A7.keylat.{k}.handled_ms", "ms", f"`bench keylat` {n}: key → sendEvent returned (main thread)", 16.7),
        (f"A7.keylat.{k}.commit_ms", "ms", f"`bench keylat` {n}: key → next CA commit"),
        (f"A7.keylat.{k}.frame_ms", "ms", f"`bench keylat` {n}: key → pixel (display tick after that commit)"))],
]
THRESHOLDS = {m[0]: m[3] for m in METRICS if len(m) > 3}
HOOKED = ("A5.wheel.", "A7.keylat.")  # metrics that need hc/hooks


def collect(d, laptop):
    """({metric: {arm: [(value, kept)]}}, {(prefix, arm): why it is n/a}) from one OUT dir.
    kept = the sample counts: always on the mini; on the laptop only when it started at load < LOAD_MAX."""
    v, missing = {}, {}

    def put(k, r, x):
        if x is None:
            return
        load = r.get("load0", (r.get("loadavg") or [0])[0])
        v.setdefault(k, {}).setdefault(r["arm"], []).append((x, not laptop or load < LOAD_MAX))

    for ph, prefix in (("launch", "A1.launch"), ("cold", "A1.cold")):
        for r in rows(d, ph):
            if ph == "launch" and r["round"] == 0:
                continue  # warm only: round 0 is the first launch of the run
            if ph == "cold" and (r.get("binary_resident_pct") or 0) > 10:
                continue  # the copy was in the page cache: not a cold launch
            m = r.get("marks", {})
            put(f"{prefix}.paint_ms", r, m.get("page.paint"))
            put(f"{prefix}.window_ms", r, m.get("window"))
            put(f"{prefix}.ask_ms", r, m.get("page.ask"))
            put(f"{prefix}.busy_ms", r, r.get("launchBusy"))
            if ph == "launch":
                put(f"{prefix}.first_pass_ms", r, r.get("firstPass"))
            else:
                put(f"{prefix}.socket_ms", r, r.get("socket_ms"))
                put(f"{prefix}.binary_resident_pct", r, r.get("binary_resident_pct"))
    for r in rows(d, "session"):
        for s in r.get("spaces", []):
            sw = "A2.space_switch.wake" if s.get("landing") == "sleeping" else "A2.space_switch.big" if s.get("big") else "A2.space_switch"
            put(f"{sw}.busy_ms", r, s.get("busy"))
            put(f"{sw}.longest_ms", r, s.get("longest"))
            if s.get("rows") is not None:  # per space: rows the column shows, landing state (perf.md's per-space table)
                put("A2.space.%s.%s_%drows.busy_ms" % (s["to"], s.get("landing", "?"), s["rows"]), r, s.get("busy"))
        for t in r.get("tabs", []):
            if t.get("was_built") and not t.get("was_asleep"):
                put("A2.tab_switch.busy_ms", r, t.get("busy"))
                put("A2.tab_switch.longest_ms", r, t.get("longest"))
            else:
                put("A2.tab_wake.busy_ms", r, t.get("busy"))
        mi, ml = r.get("mem_idle", {}), r.get("mem_loaded", {})
        put("A4.idle.total_mb", r, mi.get("total_mb"))
        put("A4.idle.app_mb", r, mi.get("by_kind", {}).get("app"))
        put("A4.idle.pages_loaded", r, len(r.get("heat_idle", [])))
        put("A4.loaded.total_mb", r, ml.get("total_mb"))
        for h in r.get("heat_loaded", []):
            put("A4.mb_per_page", r, h.get("mb"))
        i = r.get("idle", {})
        mins = (i.get("seconds") or 60) / 60
        put("A6.idle.cpu_pct", r, i.get("cpu_pct"))
        put("A6.idle.app_cpu_pct", r, i.get("app_cpu_pct"))
        put("A6.idle.wakeups_per_s", r, i.get("wakeups_per_s"))
        put("A6.idle.main_busy_ms_per_min", r, i.get("busy") / mins if i.get("busy") is not None else None)
        put("A6.idle.main_passes_per_min", r, i.get("passes") / mins if i.get("passes") is not None else None)
        for t in r.get("typing", []):
            for k in t.get("keyMs") or []:
                put("A7.address.key_ms", r, k)
            put("A7.address.key_max_ms", r, t.get("keyMaxMs"))
            put("A7.address.longest_ms", r, t.get("longestMs"))
            put("A7.address.over16", r, t.get("over16"))
            put("A7.address.open_busy_ms", r, t.get("openBusyMs"))
            h = t.get("historyMs")
            put("A7.address.history_ms", r, h if h is not None and h >= 0 else None)
        for b in r.get("bar", []):
            put("A7.cmdk.ms", r, b.get("ms"))
        for t in r.get("bar_typing", []):
            for k in t.get("keyMs") or []:
                put("A7.cmdk.key_ms", r, k)
            put("A7.cmdk.key_max_ms", r, t.get("keyMaxMs"))
            put("A7.cmdk.longest_ms", r, t.get("longestMs"))
    for r in rows(d, "load"):
        if r.get("run") == 0:
            continue
        p = r["page"]
        if r["who"] == "copper":
            put(f"A3.load.{p}.fcp_ms", r, r.get("req_to_fcp_ms"))
            put(f"A3.load.{p}.app_overhead_ms", r, r.get("app_overhead_ms"))
            put("A3.load.busy_ms", r, r.get("busy"))
        else:
            put(f"A3.load.{p}.raw_fcp_ms", r, r.get("req_to_fcp_ms"))
            put(f"A3.load.{p}.raw_app_overhead_ms", r, r.get("app_overhead_ms"))
    for r in rows(d, "scroll"):
        if "p95" not in r:
            continue
        put(f"A5.scroll.{r['page']}.p95_ms", r, r.get("p95"))
        put(f"A5.scroll.{r['page']}.janky", r, r.get("janky"))
        put("A5.scroll.dropped", r, r.get("dropped"))
    for r in rows(d, "canvas"):
        if "p95" not in r:
            continue
        b = r["board"]
        put(f"A5.canvas.{b}.fps", r, r.get("fps"))
        put(f"A5.canvas.{b}.p95_ms", r, r.get("p95"))
        put(f"A5.canvas.{b}.over33", r, r.get("over33"))
        put(f"A5.canvas.{b}.zoom_p95_ms", r, ((r.get("phases") or {}).get("zoom") or {}).get("p95"))
    for r in rows(d, "wheel"):
        if r.get("missing"):
            missing[("A5.wheel.", r["arm"])] = r["missing"]
            continue
        if not r.get("frames"):
            continue  # the page never moved: logged in raw/wheel.jsonl, not a frame sample
        put("A5.wheel.dropped_pct", r, r.get("dropped120_pct"))
        put(f"A5.wheel.{r['page']}.dropped_pct", r, r.get("dropped120_pct"))
        for x in r.get("d") or []:
            put(f"A5.wheel.{r['page']}.frame_ms", r, x)
        put("A5.wheel.refresh_ms", r, r.get("refreshMs"))
        h = r.get("hook") or {}
        put("A5.wheel.hook.hz", r, h.get("hz"))
        put("A5.wheel.hook.tick_p90_ms", r, (h.get("tick_ms") or {}).get("p90"))
        put("A5.wheel.hook.tick_max_ms", r, (h.get("tick_ms") or {}).get("max"))
        put("A5.wheel.hook.missed_ticks", r, h.get("missed_ticks"))
        put("A5.wheel.hook.send_p90_ms", r, (h.get("send_ms") or {}).get("p90"))
    for r in rows(d, "keylat"):
        if r.get("missing"):
            missing[("A7.keylat.", r["arm"])] = r["missing"]
            continue
        for k, x in (("", r), ("esc", r.get("esc") or {})):
            name = k or r["key"]
            for f in ("handled_ms", "commit_ms", "frame_ms"):
                put(f"A7.keylat.{name}.{f}", r, x.get(f))
    return v, missing


def summary(dest, dirs):
    out = {"track": "perf", "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "machines": {}, "metrics": {}}
    arm_order = []
    for d in dirs:
        info = json.load(open(os.path.join(d, "machine.json")))
        host = os.path.basename(os.path.normpath(d))  # mini | laptop
        out["machines"][host] = info
        for a in info["arms"]:
            arm_order.append(a["label"]) if a["label"] not in arm_order else None
        phases = ("launch", "cold", "session", "load", "scroll", "canvas", "wheel", "keylat")
        info["load_during"] = stats([r.get("load0", r["loadavg"][0]) for ph in phases for r in rows(d, ph)])
        laptop = host == "laptop"
        v, missing = collect(d, laptop)
        for k, per in v.items():
            out["metrics"].setdefault(f"{k}@{host}", {})
            for arm, xs in per.items():
                kept = [x for x, ok in xs if ok]
                s = stats(kept or [x for x, _ in xs], THRESHOLDS.get(k))
                if laptop:
                    s["n_total"] = len(xs)
                    if not kept:
                        s["load"] = f"no sample at load < {LOAD_MAX:g}: all {len(xs)} shown, none count"
                out["metrics"][f"{k}@{host}"][arm] = s
        for (prefix, arm), why in missing.items():
            for k in (m[0] for m in METRICS if m[0].startswith(prefix)):
                out["metrics"].setdefault(f"{k}@{host}", {}).setdefault(arm, {"na": why})  # real samples win
        # overhead % = Copper / bare − 1, per page (p50 vs p50, p90 vs p90)
        for page in ("local", "wikipedia", "github"):
            c, w = out["metrics"].get(f"A3.load.{page}.fcp_ms@{host}", {}), out["metrics"].get(f"A3.load.{page}.raw_fcp_ms@{host}", {})
            for arm in c:
                if w.get(arm) and w[arm]["median"]:
                    pct = lambda q: round(100 * (c[arm][q] / w[arm][q] - 1), 1)
                    out["metrics"].setdefault(f"A3.load.{page}.overhead_pct@{host}", {})[arm] = {
                        "median": pct("median"), "p50": pct("median"), "p90": pct("p90"), "n": min(c[arm]["n"], w[arm]["n"])}
    out["arms"] = arm_order
    if len(arm_order) == 2:  # A/B: new vs base, with the base's spread as the noise band
        new, base = arm_order
        out["delta"] = {}
        for k, per in out["metrics"].items():
            if (per.get(new) or {}).get("median") is not None and (per.get(base) or {}).get("median"):
                band = per[base].get("spread")
                d = per[new]["median"] - per[base]["median"]
                out["delta"][k] = {"abs": round(d, 2), "pct": round(100 * d / per[base]["median"], 1),
                                   "beyond_noise": band is not None and abs(d) > band}
    os.makedirs(dest, exist_ok=True)
    json.dump(out, open(os.path.join(dest, "perf.json"), "w"), indent=1)
    open(os.path.join(dest, "perf.md"), "w").write(markdown(out))
    print(os.path.join(dest, "perf.json"))


def cell(s):
    if not s:
        return "—"
    if "na" in s:
        return s["na"]
    t = f"p50 {s['median']:g} · p90 {s['p90']:g}" + (f" · max {s['max']:g}" if "max" in s else "")
    if "over" in s:
        t += f" · >{s['thr']:g}: {s['over']}/{s['n']}"
    t += f" (n={s['n']}" + (f"/{s['n_total']}" if "n_total" in s else "") + ")"
    return t + (" ⚠ load" if s.get("load") else "")


def markdown(o):
    arms_ = o["arms"]
    lines = [f"# Copper perf (Track A) — {' vs '.join(arms_)}", "", f"Generated {o['created']} by `perf/hillclimb/perf.sh`.", ""]
    for host, m in o["machines"].items():
        ld = m.get("load_during") or {}
        lines.append(f"- **{host}**: {m['model']}, macOS {m['macos']}, {', '.join(m['displays'])}, mode `{m['mode']}`, "
                     f"seed {m.get('seed_tabs')} tabs, 1-min load at sample start {ld.get('min')}–{ld.get('max')} (median {ld.get('median')})")
    lines += ["", "Cells: p50 · p90 (nearest rank) · max, `>T: k/n` = samples over the target's threshold, n = samples. "
              f"**Laptop**: a sample counts only if the 1-min load was < {LOAD_MAX:g} when it started; n = kept/total; "
              "`⚠ load` = no sample kept, the cell shows all of them and does not count. Lower is better except fps.", "",
              COLD_NOTE, "",
              f"`{HOOK_MISSING}`: the build has no `bench wheel` / `bench keylat` (HOOKS-SPEC.md); `n/a: hook error: …`: "
              "the hook answered with that error on this Mac. The wheel runs on the laptop only (ProMotion, headless).", "",
              "| metric | " + " | ".join(arms_) + (" | Δ p50" if len(arms_) == 2 else "") + " | what |",
              "|---|" + "---|" * len(arms_) + ("---|" if len(arms_) == 2 else "") + "---|"]
    whats = {m[0]: (m[1], m[2]) for m in METRICS}
    keys = sorted(o["metrics"], key=lambda k: ([m[0] for m in METRICS].index(k.split("@")[0]) if k.split("@")[0] in whats else 999, k))
    for k in keys:
        u, w = whats.get(k.split("@")[0], ("", ""))
        delta = ""
        if len(arms_) == 2:
            d = o.get("delta", {}).get(k)
            delta = f" {d['pct']:+g}%{' ⚠' if d['beyond_noise'] else ''} |" if d else " — |"
        lines.append(f"| `{k}` {u} | " + " | ".join(cell(o["metrics"][k].get(a)) for a in arms_) + " |" + delta + f" {w} |")
    lines.append("")
    return "\n".join(lines)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    phase, out = argv[0], os.path.expanduser(argv[1])
    if phase == "summary":
        return summary(out, argv[2:])
    a = arms(argv[2:])
    {"setup": setup, "launch": launch, "cold": cold, "session": session, "load": load, "smooth": smooth, "hooks": hooks}[phase](out, a)


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
