#!/usr/bin/env python3
"""A2 on the Mac: space and tab switches, builds paired (ABBA), Reduce Motion off and on.

    python3 perf/a2.py OUT ROUNDS label=APP [label=APP …] [--rm off,on] [--open] [--settle 40]
                       [--seed ~/hc/seed] [--world hcspace] [--port 4200] [--site 4201] [--record]

One session per arm per round per Reduce Motion setting, each under `~/hc/mini.lock`: the world is
re-seeded from SEED (with --open every folder in it open, so the big space shows all its rows),
the build launched in front, left SETTLE s (the background warming happens there), then every
space and back twice (first visit after launch, then again), then the first 12 tabs of the home
space twice (wakes, then warm). Per switch: `bench pace` busy / longest pass, the landing tab and
whether it was built. Reduce Motion is the Mac-wide setting; it is put back as found after each
session. --record also pictures one switch (`bench window` as fast as it answers) per session.
Rows: OUT/a2.jsonl; `python3 perf/a2.py summary OUT` prints p50/p90 per arm and setting, paired.
"""
import fcntl, json, os, shutil, statistics, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import perf  # noqa: E402

LOCK = os.path.expanduser("~/hc/mini.lock")


def opt(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


WORLD, PORT, SITE = opt("--world", "hcspace"), int(opt("--port", "4200")), int(opt("--site", "4201"))
assert 4130 <= PORT <= 4239 and 4130 <= SITE <= 4239 and 4123 not in (PORT, SITE)


def reduce_motion(on=None):
    if on is not None:
        subprocess.run(["defaults", "write", "com.apple.universalaccess", "reduceMotion", "-bool", "true" if on else "false"])
        time.sleep(0.5)
    r = subprocess.run(["osascript", "-l", "JavaScript", "-e",
                        'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion'],
                       capture_output=True, text=True)
    return r.stdout.strip() == "true"


def ask(req, timeout=30):
    return perf.ask(WORLD, req, timeout)


def start(app, open_folders):
    perf.quit_world(WORLD)
    folder = perf.folder(WORLD)
    for junk in ("bench.sock", "crashes"):
        p = os.path.join(folder, junk)
        shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else os.path.exists(p) and os.unlink(p)
    os.environ["PERF_ACTIVE"] = f"http://127.0.0.1:{SITE}/index.html"
    with open(os.devnull, "w") as dn:
        so, sys.stdout = sys.stdout, dn
        try:
            perf.seed(WORLD)
        finally:
            sys.stdout = so
    if open_folders:
        path = os.path.join(folder, "groups.json")
        g = json.load(open(path))
        for x in g.get("groups", []):
            x["collapsed"] = False
        json.dump(g, open(path, "w"))
    time.sleep(1)
    subprocess.run(["open", "-n", "-a", app, "--env", f"SEARCH_PROBE={WORLD}", "--env", "SEARCH_MEASURE=1",
                    "--env", f"SEARCH_MCP_PORT={PORT}"], check=True)
    end = time.time() + 60
    while time.time() < end and not perf.connectable(WORLD):
        time.sleep(0.05)
    while time.time() < end:
        a = next((t for t in ask({"do": "tabs"}).get("tabs", []) if t.get("active")), None)
        if a and not a.get("loading") and a.get("view"):
            return
        time.sleep(0.05)
    raise RuntimeError("no restored page")


def active():
    return next((t for t in ask({"do": "tabs"}).get("tabs", []) if t.get("active")), {})


def spaces(rec):
    listing = ask({"do": "spaces", "op": "list", "arg": ""}).get("spaces", [])
    home = next((s["index"] for s in listing if s.get("current")), 0)
    counts = {s["index"]: s.get("tabs") for s in listing}
    big = max(counts, key=lambda i: counts[i] or 0)
    rows = []
    for visit in (0, 1):
        for n in [i for i in counts if i != home] + [home]:
            ask({"do": "pace", "op": "reset"})
            ask({"do": "spaces", "op": "select", "arg": str(n)})
            time.sleep(0.05)
            first = active()
            time.sleep(0.85)
            pace = ask({"do": "pace"})
            rows.append({"to": n, "visit": visit, "busy": pace.get("busy"), "longest": pace.get("longest"),
                         "tabs": counts.get(n), "big": n == big, "tab": (first.get("id") or "")[:8],
                         "landing": "blank" if first.get("blank") or not first.get("url") else
                                    "sleeping" if first.get("loading") or not first.get("view") else "warm"})
    if rec:
        rows.append({"motion": record(rec, big if big != home else [i for i in counts if i != home][0], home)})
    return rows


def record(out, to, home, seconds=0.9):
    """`bench window` pictures as fast as they come over one switch to space TO (frame 0 = before)."""
    os.makedirs(out, exist_ok=True)
    frames = []
    def grab():
        p = os.path.join(out, f"{len(frames):03d}.png")
        ask({"do": "window", "path": p})
        frames.append((p, round((time.time() - t0) * 1000)))
    t0 = time.time()
    grab()
    th = threading.Thread(target=lambda: ask({"do": "spaces", "op": "select", "arg": str(to)}))
    t0 = time.time()
    th.start()
    while time.time() - t0 < seconds:
        grab()
    th.join(10)
    time.sleep(1)
    ask({"do": "spaces", "op": "select", "arg": str(home)})
    time.sleep(1.2)
    return {"dir": out, "ms": [m for _, m in frames]}


def tabs():
    listing = ask({"do": "tabs"}).get("tabs", [])
    space = next((t.get("space") for t in listing if t.get("active")), None)
    ids = [t["id"] for t in listing if t.get("space") == space and not t.get("bench")][:12]
    rows = []
    for r in (0, 1):
        for tid in ids:
            before = next((t for t in ask({"do": "tabs"}).get("tabs", []) if t["id"] == tid), {})
            ask({"do": "pace", "op": "reset"})
            ask({"do": "select", "id": tid})
            time.sleep(1.0)
            pace = ask({"do": "pace"})
            rows.append({"round": r, "tab": tid[:8], "title": (before.get("title") or "")[:30], "built": bool(before.get("view")),
                         "asleep": before.get("asleep"), "busy": pace.get("busy"), "longest": pace.get("longest")})
    return rows


def run(out, rounds, arms_, rms, open_folders, settle, rec):
    serve = subprocess.Popen([sys.executable, "-m", "http.server", str(SITE), "--bind", "127.0.0.1", "-d",
                              os.path.expanduser("~/hc/tools/perf/site")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for r in range(rounds):
            for rm in rms:
                for label, app in (arms_ if r % 2 == 0 else arms_[::-1]):
                    with open(LOCK, "a") as lk:
                        fcntl.flock(lk, fcntl.LOCK_EX)
                        was = reduce_motion()
                        try:
                            got = reduce_motion(rm == "on")
                            start(app, open_folders)
                            time.sleep(settle)
                            row = {"arm": label, "round": r, "rm": rm, "rm_seen": got, "load": os.getloadavg()[0],
                                   "spaces": spaces(os.path.join(out, "motion", f"{label}-rm{rm}-r{r}") if rec else None),
                                   "tabs": tabs()}
                        finally:
                            perf.quit_world(WORLD)
                            reduce_motion(was)
                            fcntl.flock(lk, fcntl.LOCK_UN)
                    with open(os.path.join(out, "a2.jsonl"), "a") as f:
                        f.write(json.dumps(row) + "\n")
                    sp = [s for s in row["spaces"] if "busy" in s]
                    print(label, "r", r, "rm", rm, "spaces busy", [s["busy"] for s in sp], "landing", [s["landing"][0] for s in sp], flush=True)
    finally:
        serve.terminate()


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None)
    return xs[min(len(xs) - 1, int(round(p / 100 * len(xs) + 0.5)) - 1)] if xs else None


def summary(out):
    rows = [json.loads(l) for l in open(os.path.join(out, "a2.jsonl"))]
    cells = {}
    def put(key, arm, rm, x):
        cells.setdefault((key, rm), {}).setdefault(arm, []).append(x)
    for r in rows:
        for s in r["spaces"]:
            if "busy" not in s:
                continue
            put("space.all.busy", r["arm"], r["rm"], s["busy"])
            put("space.all.longest", r["arm"], r["rm"], s["longest"])
            put(f"space.{'first' if s['visit'] == 0 else 'again'}.busy", r["arm"], r["rm"], s["busy"])
            if s["big"]:
                put("space.big.busy", r["arm"], r["rm"], s["busy"])
                put("space.big.longest", r["arm"], r["rm"], s["longest"])
            put(f"space.landing_{s['landing']}.busy", r["arm"], r["rm"], s["busy"])
        for t in r["tabs"]:
            put("tab.warm.busy" if t["round"] == 1 and t["built"] else "tab.wake.busy" if t["round"] == 0 else "tab.other.busy",
                r["arm"], r["rm"], t["busy"])
            if t["round"] == 1 and t["built"]:
                put("tab.warm.longest", r["arm"], r["rm"], t["longest"])
    arms_ = sorted({r["arm"] for r in rows}, key=lambda a: [r["arm"] for r in rows].index(a))
    print("| metric | RM | " + " | ".join(f"{a} p50 · p90 · max (n)" for a in arms_) + " |")
    print("|---|---|" + "---|" * len(arms_))
    for (key, rm), per in sorted(cells.items()):
        def cell(xs):
            return f"{pct(xs, 50)} · {pct(xs, 90)} · {max(xs)} ({len(xs)})" if xs else "—"
        print(f"| {key} | {rm} | " + " | ".join(cell(per.get(a, [])) for a in arms_) + " |")
    over = {}
    for r in rows:
        for s in r["spaces"]:
            if "busy" in s and s["longest"] is not None and s["longest"] > 50:
                over.setdefault((r["arm"], r["rm"]), []).append(s["longest"])
    print("passes > 50 ms in space switches:", {f"{a}/{rm}": len(v) for (a, rm), v in over.items()})


if __name__ == "__main__":
    if sys.argv[1] == "summary":
        summary(sys.argv[2])
        sys.exit()
    out, rounds = os.path.abspath(sys.argv[1]), int(sys.argv[2])
    os.makedirs(out, exist_ok=True)
    arms_ = [tuple(a.split("=", 1)) for a in sys.argv[3:] if "=" in a and not a.startswith("--")]
    arms_ = [(l, os.path.expanduser(a)) for l, a in arms_]
    perf.REAL = os.path.expanduser(opt("--seed", "~/hc/seed"))
    run(out, rounds, arms_, opt("--rm", "off,on").split(","), "--open" in sys.argv, int(opt("--settle", "40")),
        "--record" in sys.argv)
