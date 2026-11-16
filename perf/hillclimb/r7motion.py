#!/usr/bin/env python3
"""B14 slice (r7/motion): split create, ⌘K open, tab press (no travel) and
press-and-drag, recorded by `bench window` in one windowed probe world with
Reduce Motion off (the Mac's setting put back), plus the main thread's passes
(`bench pace`) around each trigger. Run from a copy of perf/hillclimb:

    lockf -k ~/hc/mini.lock python3 r7motion.py LABEL APP OUT [ROUNDS]
    python3 r7motion.py check OUT     # the gate on a recording: exit 1 if any row fails

Gate (B14): split create slides in ≥4 moving frames and its cover comes off (pages shown) by 600 ms;
⌘K's card arrives whole (its next 3 frames change < 5% of the window); a tab press lands in one frame.

Env as keywin: UX_PORTS, UX_SITE_PORT, UX_PIX, BENCH.
"""
import http.server, json, os, sys, threading, time, functools
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "ux"))
from drive import World, calm, seed_lived_in, tab_id, free_port, SITE_PORT  # noqa: E402
from keywin import Run, ask, record, reduce_motion, set_reduce_motion  # noqa: E402


def serve_site():
    h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=os.path.join(HERE, "ux", "site"))
    h.log_message = lambda *a: None
    try:
        s = http.server.ThreadingHTTPServer(("127.0.0.1", SITE_PORT), h)
    except OSError:
        return None  # already served
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s


def paced(w, row):
    """The main thread's passes since the trigger's reset: busy, longest, the passes ≥1 ms, steps."""
    p = w.j("pace")
    row["pace"] = {k: p.get(k) for k in ("busy", "longest", "passes", "log", "steps")}
    return row


def recordings(run, w, rnd):
    rows = []
    art, docs = tab_id(w, "Field Notes"), tab_id(w, "Spaces — Copper Docs")
    hn = tab_id(w, "Hacker News")
    sfx = f"-{rnd}"
    calm(w); w.b("ui", "sidebar", "on"); w.b("select", art); time.sleep(1)

    w.b("pace", "reset")
    rows.append(paced(w, record(run, "split-create" + sfx, lambda: ask(w, {"do": "split", "arg": docs}), seconds=1.0)))
    time.sleep(0.6)
    w.b("split", "off"); time.sleep(0.8); w.b("select", art); time.sleep(0.6)

    calm(w); w.b("select", art); time.sleep(0.8)
    w.b("pace", "reset")
    rows.append(paced(w, record(run, "cmdk-open" + sfx, lambda: ask(w, {"do": "key", "id": art, "text": "⌘K", "via": "app"}), seconds=0.5)))
    calm(w); w.b("select", art); time.sleep(0.6)

    # Pressed and held, no travel: the press on its own.
    rows.append(record(run, "tab-press" + sfx, lambda: ask(w, {"do": "sections", "op": "drag", "arg": f"{hn} 0 1 hold"}), seconds=0.5))
    w.b("sections", "release"); time.sleep(0.8); w.b("select", art); time.sleep(0.4)
    rows.append(record(run, "tab-press-drag" + sfx, lambda: ask(w, {"do": "sections", "op": "drag", "arg": f"{hn} 40 8 hold"}), seconds=0.8))
    w.b("sections", "release"); time.sleep(0.8); w.b("select", art); time.sleep(0.4)
    return rows


def verdict(row):
    """(ok, why) for one recording, from its frame-to-frame steps (share of the window's pixels changed)."""
    n, st, ms = row["name"], row["steps"], row["ms"]
    if n.startswith("split-create"):
        moving = [i for i, x in enumerate(st) if 0.005 <= x < 0.3]
        runs, cur = 0, 0
        for i in range(1, len(st)):
            cur = cur + 1 if i in moving else 0
            runs = max(runs, cur)
        off = next((ms[i] for i in range(1, len(st)) if st[i] >= 0.3 and moving and i > moving[0]), None)
        return runs >= 4 and off is not None and off <= 600, f"slide frames {runs}, cover off at {off} ms"
    if n.startswith("cmdk-open"):
        at = next((i for i, x in enumerate(st) if x >= 0.5), None)
        after = round(sum(st[at + 1:at + 4]), 4) if at is not None else None
        return after is not None and after < 0.05, f"card at {ms[at] if at is not None else None} ms, then changed {after}"
    if n.startswith("tab-press") and "drag" not in n:
        steps = sum(1 for x in st if x > 0.0001)
        return steps == 1, f"press drawn over {steps} frames"
    return True, "not gated"


def check(out):
    bad = 0
    for row in json.load(open(os.path.join(out, "motion.json"))):
        ok, why = verdict(row)
        bad += not ok
        print(f"{'PASS' if ok else 'FAIL'} {row['name']}: {why}")
    sys.exit(1 if bad else 0)


def main():
    if sys.argv[1] == "check":
        return check(sys.argv[2])
    label, app, out = sys.argv[1], os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3])
    rounds = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    os.makedirs(os.path.join(out, "logs"), exist_ok=True)
    os.makedirs(os.path.join(out, "motion"), exist_ok=True)
    site = serve_site()
    rm0 = reduce_motion()
    w = World(f"r7mo-{label}"[:24], app, free_port(), os.path.join(out, "logs", "motion.log"), windowed=True)
    rows = []
    try:
        w.reset([("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("probe.keychain", "-string", "file"),
                 ("sidebar", "-bool", "true"), ("look", "-string", "light")])
        seed_lived_in(w.folder)
        if reduce_motion():
            set_reduce_motion(False)
        w.launch()
        for i, c in enumerate(("Blue", "Green", "Teal"), 1):
            w.b("spaces", "colour", i, c)
        art = tab_id(w, "Field Notes")
        w.b("wait", art, 10); w.b("resize", 1440, 900, 1); time.sleep(1)
        run = Run(w, out)
        for r in range(rounds):
            rows += recordings(run, w, r)
    finally:
        w.drop()
        if rm0 is not None:
            set_reduce_motion(rm0)
        if site:
            site.shutdown()
        json.dump(rows, open(os.path.join(out, "motion.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
