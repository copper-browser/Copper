#!/usr/bin/env python3
"""Track D agentbench: one task suite, every arm alternating within each task.

Driven by ../agentbench.sh (which brings up the probe world and the fixtures);
standard library only, Python 3.9 (the mini's /usr/bin/python3).

    agentbench.py --port 4160 --world agentbench --fixtures http://127.0.0.1:4161 \
        --out ~/hc/out/base/agentbench --group ultrafast --round 1
    agentbench.py --out DIR --summary          # re-read DIR/runs.jsonl → summary.md

Groups:
  ultrafast  jev-ultrafast's three published tasks, same goals, own checkers
             (hotel fixture served locally; Gödel; Google Flights ZRH→LON,
             date moved into the future — see FLIGHT_DATE)
  wikigame   perf/wikigame.py's ten games (links only)
  uibench    perf/uibench's eight forms/dialogs tasks, the app's own verdict
  realweb    five read-only public-web tasks, no login, no purchase

A pass = the run said DONE *and* the independent checker agrees (page read
after the run, or the fixture server's record). Arms: see ARMS.
"""

import argparse
import json
import math
import os
import random
import re
import shutil
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- arms

ARMS = {
    # what the build ships with nothing said (2026-11 fork: turbo + watched, vision auto)
    "shipped": {},
    # the same speed-ups with no glide at all; headless never glides, so vs shipped it is an A/A check
    "turbo": {"strategy": "turbo", "vision": "auto"},
    # the original loop, text only (control)
    "classic": {"strategy": "classic", "vision": "off"},
    # a small LLM decides instead of Jev (perf/uibench's preset)
    "llm-haiku": {"strategy": "fast,llm=haiku", "vision": "off"},
    # the shipped loop under upstream's published conditions, for a like-for-like with the ultrafast arm:
    # Jev pinned to jev-1.13.0 (jev-latest answers as 1.14.0 since 2026-11) and a private tab per run
    # (empty cookies and storage, nothing kept). Run it with AGENTBENCH_VIEWPORT=1120x780 and
    # AGENTBENCH_TEXT_MODEL=default (the build's fast text model; the router has no mercury) — see README.
    "same": {"model": "jev-1.13.0", "private": True},
    # the shipped loop on jev-1.13.0 and nothing else changed: what the Jev version alone does
    "jev113": {"model": "jev-1.13.0"},
    # experiment arms (hc/jev): the shipped loop plus Return after a lone search box
    "submit": {"strategy": "turbo,verify,submit"},
    "submit113": {"strategy": "turbo,verify,submit", "model": "jev-1.13.0"},
    # browser-use jev-ultrafast in Chrome — prepared, NOT run until Collin OKs Chrome (ultrafast_arm.py)
    "ultrafast": None,
    # phi driving via browser_snapshot/browser_click — stub (see play_phi)
    "phi-mcp": None,
}

# ---------------------------------------------------------------- tasks

FLIGHT_DATE = ("2027-01-20", "January 20, 2027", "Wednesday, January 20")  # upstream used 2026-09-20, now past
HOTEL_TEXT = "Your filters: Design · Free cancellation enabled · Destination Lisbon"

WIKI_GAMES = [  # perf/wikigame.py GAMES
    ("Cheese", "Milk"), ("Moon", "Earth"), ("Coffee", "Ethiopia"), ("Chess", "India"), ("Pizza", "Naples"),
    ("William Shakespeare", "Hamlet"), ("Python (programming language)", "Guido van Rossum"),
    ("Lionel Messi", "Buenos Aires"), ("Mount Everest", "Kathmandu"), ("Ludwig van Beethoven", "Austria"),
]
WIKI_GOAL = (  # perf/wikigame.py GOAL
    "Wikipedia game. Starting from the article that is open, reach the Wikipedia article titled "
    "\"{target}\" by clicking links inside the article text only — one link at a time, scrolling "
    "when the useful link is below the fold. Never use the search box and never type anything. "
    "You are DONE only when the page's title is exactly \"{target}\"."
)
UIBENCH = {  # perf/uibench.py TASKS: goal, optimal actions
    "login": ('Sign in with the work email "maya@northwind.test" and the access code "482915". Stop when the dashboard shows.', 3),
    "settings": ('Open Settings, turn on Two-factor authentication, change the language to "Deutsch", and save the changes. Leave the other settings as they are.', 4),
    "project": ('Create a new project named "Apollo" in the region "EU Central (Frankfurt)" with Team visibility.', 6),
    "checkout": ("Check out with Express shipping, accept the terms of sale, and place the order. Do not sign up for product news.", 5),
    "invoices": ('Approve invoice "INV-1042" and nothing else.', 2),
    "files": ('Delete the file "budget-2026.xlsx" and nothing else.', 2),
    "whack": ("Click the button the prompt names, again and again, until the page says All done.", 12),
    "swatches": ("Click the square of the colour the prompt names, again and again, until the page says All done.", 8),
}


def wiki_url(title):
    return "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"))


def wiki_title(url):
    parts = urllib.parse.urlsplit(url or "")
    if not parts.netloc.endswith("wikipedia.org"):
        return None
    path = urllib.parse.unquote(parts.path)
    if path.startswith("/wiki/"):
        return path[6:].split("#")[0].replace("_", " ")
    q = urllib.parse.parse_qs(parts.query)
    return q["title"][0].replace("_", " ") if "title" in q else None


def same_title(a, b):
    norm = lambda t: (t[:1].upper() + t[1:]).strip()
    return a is not None and b is not None and norm(a) == norm(b)


def host_path(url):
    p = urllib.parse.urlsplit(url or "")
    return p.netloc.lower(), urllib.parse.unquote(p.path)


# Checkers take (page, run) — page: what READ_PAGE returned after the run; run: the normalized run.
# They return a dict of named booleans; verified = all true.

def check_hotel(page, run):
    return {"casa_flora": (page.get("url") or "").endswith("#casa-flora"), "filters": HOTEL_TEXT in (page.get("text") or "")}


def check_godel(page, run):
    return {"article": same_title(wiki_title(page.get("url")), "Gödel's incompleteness theorems")}


def check_flights(page, run):
    host, path = host_path(page.get("url"))
    q = urllib.parse.parse_qs(urllib.parse.urlsplit(page.get("url") or "").query).get("tfs", [""])[0]
    try:
        import base64
        tfs = base64.urlsafe_b64decode(q + "=" * (-len(q) % 4))
    except ValueError:
        tfs = b""
    inputs = {k: v for k, v in page.get("inputs") or []}
    text = page.get("text") or ""
    flights = page.get("flights") or []
    return {
        "search_page": host == "www.google.com" and path == "/travel/flights/search",
        "one_way": "One way" in text and "Round trip" not in text,
        "origin": inputs.get("Where from?") in ("Zürich", "Zurich"),
        "destination": inputs.get("Where to?") == "London",
        "date": FLIGHT_DATE[0].encode() in tfs,
        "results": bool(flights) and all(FLIGHT_DATE[2] in f for f in flights if f != "Select flight"),
    }


def check_wiki(target):
    def check(page, run):
        steps = run.get("steps") or []
        return {"reached": same_title(wiki_title(page.get("url")), target),
                "no_typing": not any(s.get("kind") == "fill" for s in steps),
                "no_search": not any("Special:Search" in (s.get("url") or "") or "search=" in (s.get("url") or "") for s in steps)}
    return check


def check_url(host_suffix, path_re, text_re=None):
    def check(page, run):
        host, path = host_path(page.get("url"))
        out = {"host": host.endswith(host_suffix), "path": bool(re.search(path_re, path))}
        if text_re:
            out["text"] = bool(re.search(text_re, (page.get("title") or "") + "\n" + (page.get("text") or ""), re.I))
        return out
    return check


def check_github(page, run):
    host, path = host_path(page.get("url"))
    q = urllib.parse.parse_qs(urllib.parse.urlsplit(page.get("url") or "").query).get("q", [""])[0]
    return {"host": host == "github.com", "repo_issues": path.rstrip("/") == "/microsoft/vscode/issues",
            "query": "minimap" in q.lower()}


def check_amazon(page, run):
    host, path = host_path(page.get("url"))
    steps = run.get("steps") or []
    return {"host": host.endswith("amazon.com"), "product_page": bool(re.search(r"/(dp|gp/product)/[A-Z0-9]{10}", path)),
            "batteries": bool(re.search(r"batter", page.get("title") or "", re.I)),
            "no_cart": not any(re.search(r"add to (cart|basket)|buy now", s.get("label") or "", re.I) for s in steps)}


def tasks(fixtures):
    """Every task: id → dict(group, url, goal, check, max_steps, core). url() may embed a run id."""
    T = {}
    # ultrafast's own three (docs/performance.md); goals verbatim except the flight date
    T["hotel"] = dict(group="ultrafast", url=lambda sid: f"{fixtures}/fixture.html?scenario=travel",
                      goal="Use the destination search and filters to find Design stays in Lisbon with Free cancellation, "
                           "then open Casa Flora.", check=check_hotel, max_steps=15, published_ms=1896)
    T["godel"] = dict(group="ultrafast", url=lambda sid: "https://en.wikipedia.org/wiki/Main_Page",
                      goal="Find and open the Wikipedia article about Gödel’s incompleteness theorems.",
                      check=check_godel, max_steps=20, published_ms=2798)
    T["flights"] = dict(group="ultrafast", url=lambda sid: "https://www.google.com/travel/flights?hl=en",
                        goal=f"Find one-way flights from Zurich to London on {FLIGHT_DATE[1]}, for one adult in economy. "
                             "Stop when matching flight options are visible. Do not select or book a flight.",
                        check=check_flights, max_steps=40, published_ms=7073)
    for i, (start, target) in enumerate(WIKI_GAMES, 1):
        T[f"wiki{i:02d}"] = dict(group="wikigame", url=(lambda s: lambda sid: wiki_url(s))(start),
                                 goal=WIKI_GOAL.format(target=target), check=check_wiki(target), max_steps=20,
                                 name=f"{start} → {target}")
    for name, (goal, optimal) in UIBENCH.items():
        T[f"ui-{name}"] = dict(group="uibench", url=(lambda n: lambda sid: f"{fixtures}/app?task={n}&sid={sid}")(name),
                               goal=goal, check="app", max_steps=30, optimal=optimal)
    # five read-only real-web tasks: no login, no purchase, no posting
    T["gh-issues"] = dict(group="realweb", url=lambda sid: "https://github.com/microsoft/vscode/issues",
                          goal='Search this repository\'s issues for "minimap" and show the results.',
                          check=check_github, max_steps=20)
    T["wiki-lang"] = dict(group="realweb", url=lambda sid: "https://en.wikipedia.org/wiki/Alan_Turing",
                          goal="Switch to the German-language version of this Wikipedia article.",
                          check=check_url("de.wikipedia.org", r"^/wiki/Alan_Turing$"), max_steps=15)
    T["amazon-pdp"] = dict(group="realweb", url=lambda sid: "https://www.amazon.com/",
                           goal='Search Amazon for "AA batteries" and open the product page of one of the results. '
                                "Do not add anything to the cart and do not buy anything.",
                           check=check_amazon, max_steps=20)
    T["pydocs"] = dict(group="realweb", url=lambda sid: "https://docs.python.org/3/",
                       goal='Open the Python documentation page for the "pathlib" module.',
                       check=check_url("docs.python.org", r"/library/pathlib\.html$"), max_steps=15)
    T["mdn"] = dict(group="realweb", url=lambda sid: "https://developer.mozilla.org/en-US/",
                    goal="Open the MDN reference page for the JavaScript Array.prototype.flatMap() method.",
                    check=check_url("developer.mozilla.org", r"/Web/JavaScript/Reference/Global_Objects/Array/flatMap$"),
                    max_steps=15)
    return T


# What a checker reads after the run, in the run's tab. A sync function (async evaluate is a known Copper gap).
READ_PAGE = """() => ({
  url: location.href, title: document.title,
  text: (document.body ? document.body.innerText : '').slice(0, 30000),
  inputs: [...document.querySelectorAll('input')].filter(e => e.offsetParent)
    .map(e => [e.getAttribute('aria-label') || e.placeholder || e.name || '', e.value]).slice(0, 80),
  flights: [...document.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label'))
    .filter(s => /Select flight/.test(s)).slice(0, 40),
  viewport: [innerWidth, innerHeight, devicePixelRatio]
})"""

# ---------------------------------------------------------------- Copper


class ProbeDown(Exception):
    """Copper isn't listening: not a run result; the batch stops (exit 3) and the shell restarts the probe."""


class Copper:
    def __init__(self, world, port):
        path = os.path.expanduser(f"~/Library/Application Support/Copper ({world})/agent.json")
        with open(path) as f:
            self.token = json.load(f)["token"]
        self.url = f"http://127.0.0.1:{port}/mcp"
        self.n = 0

    def call(self, tool, arguments, timeout=240):
        self.n += 1
        body = {"jsonrpc": "2.0", "id": self.n, "method": "tools/call", "params": {"name": tool, "arguments": arguments}}
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            reply = json.load(r)
        if "error" in reply:
            raise RuntimeError(reply["error"].get("message", str(reply["error"])))
        result = reply.get("result", {})
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        if result.get("isError"):
            raise RuntimeError(text.strip() or "tool error")
        return text


def play_copper(copper, task, arm, sid):
    args = {"goal": task["goal"], "url": task["url"](sid), "newTab": True, "json": True,
            "maxSteps": task["max_steps"], "elements": False}
    args.update(ARMS[arm])
    if os.environ.get("AGENTBENCH_PRIVATE") == "1":
        args["private"] = True  # every arm in a private tab (a build without the argument ignores it)
    begun = time.time()
    error, page = None, {}
    try:
        run = json.loads(copper.call("jev_run", args))
    except (RuntimeError, urllib.error.URLError, json.JSONDecodeError, OSError) as e:
        if isinstance(getattr(e, "reason", e), (ConnectionRefusedError, ConnectionResetError)) or "RemoteDisconnected" in repr(e):
            raise ProbeDown() from e
        error = f"{type(e).__name__}: {e}"[:300]
        run = {"status": "error", "note": error, "elapsed_ms": int((time.time() - begun) * 1000), "steps": [], "totals": {}}
    try:
        page = json.loads(copper.call("browser_evaluate", {"function": READ_PAGE}, timeout=30))
    except Exception as e:  # the checker then fails on an empty page
        page = {"read_error": f"{type(e).__name__}: {e}"[:200]}
    finally:
        try:
            copper.call("browser_close", {}, timeout=20)
        except Exception:
            pass
    run["harness_ms"] = int((time.time() - begun) * 1000)
    run["private"] = bool(args.get("private"))
    if error:
        run["error"] = error
    return run, page


def play_ultrafast(task_id, task, sid, fixtures):
    """One run of browser-use jev-ultrafast (Chrome via CDP) in its own uv env. NOT run in Phase 0."""
    root = os.environ.get("ULTRAFAST_DIR", os.path.expanduser("~/src/jev-ultrafast"))
    if os.environ.get("AGENTBENCH_ALLOW_CHROME") != "1":
        raise SystemExit("ultrafast arm needs Chrome; set AGENTBENCH_ALLOW_CHROME=1 once Collin has OK'd it")
    cmd = [shutil.which("uv") or "/opt/homebrew/bin/uv", "run", "--project", root, "--env-file", os.path.join(root, ".env"), "python",
           os.path.join(HERE, "ultrafast_arm.py"), "--url", task["url"](sid), "--goal", task["goal"],
           "--max-actions", str(task["max_steps"]), "--read", READ_PAGE]
    begun = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    try:
        out = json.loads(p.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        out = {"run": {"status": "error", "note": (p.stderr or p.stdout)[-300:], "steps": [], "totals": {}}, "page": {}}
    out["run"]["harness_ms"] = int((time.time() - begun) * 1000)
    return out["run"], out["page"]


def play_phi(task_id, task, sid):
    # shortcut: stub. A real arm = `phi -p --model <haiku|sonnet> "<goal>"` with only Copper's
    # browser_* tools (MCP at the probe port), timing the whole session and reading the page after.
    # It costs a full LLM agent per run (~10–60 s, $), so it is left for when Collin wants the number.
    raise NotImplementedError("phi-mcp arm is a stub (see play_phi)")


def app_result(fixtures, sid):
    try:
        with urllib.request.urlopen(f"{fixtures}/api/result?sid={sid}", timeout=10) as r:
            return json.load(r)
    except (urllib.error.URLError, OSError, json.JSONDecodeError):
        return {"ok": False, "done": False, "wrong": 0}


def record(task_id, task, arm, rnd, run, page, fixtures, sid):
    t = run.get("totals") or {}
    steps = run.get("steps") or []
    if task["check"] == "app":
        time.sleep(0.3)  # a beacon in flight
        app = app_result(fixtures, sid)
        checks = {"app_ok": bool(app.get("ok"))}
        wrong = app.get("wrong", 0)
    else:
        checks = task["check"](page, run)
        wrong = None
    verified = all(checks.values())
    status = run.get("status")
    # uibench's verdict is the app's own (it doesn't need DONE, as in perf/uibench.py); elsewhere DONE + checker
    passed = verified if task["check"] == "app" else (status == "done" and verified)
    return {
        "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "load1": round(os.getloadavg()[0], 2),
        "group": task["group"], "task": task_id, "arm": arm, "round": rnd, "sid": sid,
        "pass": passed, "verified": verified, "checks": checks, "wrong": wrong,
        "status": status, "note": (run.get("note") or "")[:300], "error": run.get("error"),
        "wall_ms": run.get("elapsed_ms"), "harness_ms": run.get("harness_ms"),
        "decisions": run.get("decisions"), "actions": run.get("actions"),
        "done_check": run.get("done_check"), "done_refused": run.get("done_refused"), "private": bool(run.get("private")),
        **{k: t.get(k) for k in ("observe_ms", "decide_ms", "text_ms", "act_ms", "settle_ms", "jev_ms", "shot_ms",
                                 "input_tokens", "requests", "stale", "pictured", "burst_actions", "model", "strategy", "vision")},
        "final_url": page.get("url") or (run.get("page") or {}).get("url"), "final_title": page.get("title"),
        "read_error": page.get("read_error"), "viewport": page.get("viewport"),
        "steps": [{"op": s.get("operation"), "kind": s.get("kind"), "label": (s.get("label") or "")[:60], "text": s.get("text"),
                   "p": s.get("probability"), "obs": round(s.get("observe_ms") or 0), "dec": round(s.get("decide_ms") or 0),
                   "jev": round(s.get("jev_ms") or 0), "txt": round(s.get("text_ms") or 0), "act": round(s.get("act_ms") or 0),
                   "set": round(s.get("settle_ms") or 0), "tok": s.get("input_tokens"), "burst": s.get("burst")} for s in steps],
    }


# ---------------------------------------------------------------- summary

def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.median(xs) if xs else None


def pct(xs, q):
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    if not xs:
        return None
    return xs[min(len(xs) - 1, max(0, math.ceil(q * len(xs)) - 1))]  # nearest rank


def f(v, unit=""):
    if v is None:
        return "—"
    return f"{v:,.0f}{unit}" if abs(v) >= 10 else f"{v:.1f}{unit}"


def summarize(results, meta):
    arms = [a for a in ARMS if any(r["arm"] == a for r in results)]
    groups = [g for g in ("ultrafast", "wikigame", "uibench", "realweb") if any(r["group"] == g for r in results)]
    L = [f"# Agentbench — {meta.get('label', '?')}", "",
         f"Build: `{meta.get('app', '?')}` ({meta.get('build', '?')}) on {meta.get('machine', '?')}; "
         f"Jev {meta.get('jevModel', '?')}, text model {meta.get('textModel', '?')}; viewport {meta.get('viewport', '?')}. "
         f"Load avg during runs: median {f(med([r['load1'] for r in results]))}, max {f(max([r['load1'] for r in results] or [0]))}.",
         "", "Pass = DONE + independent checker (uibench: the app's own verdict). Wall = jev_run's clock "
         "(first decision → end, initial navigation excluded, as upstream). Wall stats over passes; "
         "IQR = p25–p75 (the noise band). Phase ms = medians of per-run sums over all runs.", ""]
    L += ["## By group × arm", "",
          "| Group | Arm | Pass | False DONE | Wall p50 | Wall p90 | IQR | Decisions p50 | Actions p50 | Stale/run | observe | decide | text | act | settle | Jev ms/dec | Tokens/run |",
          "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for g in groups:
        for a in arms:
            rs = [r for r in results if r["group"] == g and r["arm"] == a]
            if not rs:
                continue
            ok = [r for r in rs if r["pass"]]
            w = [r["wall_ms"] for r in ok]
            false_done = sum(1 for r in rs if r["status"] == "done" and not r["verified"])  # said DONE, the checker says no
            L.append("| {} | {} | {}/{} ({:.0f}%) | {}/{} | {} | {} | {}–{} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
                g, a, len(ok), len(rs), 100 * len(ok) / len(rs), false_done, len(rs), f(med(w)), f(pct(w, .9)), f(pct(w, .25)), f(pct(w, .75)),
                f(med([r["decisions"] for r in ok])), f(med([r["actions"] for r in ok])),
                f(statistics.mean([r.get("stale") or 0 for r in rs])),
                *[f(med([r.get(k) for r in rs])) for k in ("observe_ms", "decide_ms", "text_ms", "act_ms", "settle_ms")],
                f(med([r["jev_ms"] / r["decisions"] for r in rs if r.get("jev_ms") and r.get("decisions")])),
                f(med([r.get("input_tokens") for r in rs]))))
    L += ["", "## By task × arm (pass · wall p50 / p90 · decisions p50 · text-model calls p50, all over passes)", "",
          "| Task | Published (ultrafast) | " + " | ".join(arms) + " |", "|---|---:|" + "---:|" * len(arms)]
    T = tasks("")
    for tid in [t for t in T if any(r["task"] == t for r in results)]:
        cells = []
        for a in arms:
            rs = [r for r in results if r["task"] == tid and r["arm"] == a]
            ok = [r["wall_ms"] for r in rs if r["pass"]]
            good = [r for r in rs if r["pass"]]
            calls = [sum(1 for st in r["steps"] if st.get("txt")) for r in good]
            cells.append(f"{len(ok)}/{len(rs)} · {f(med(ok))} / {f(pct(ok, .9))} · {f(med([r['decisions'] for r in good]))} dec · {f(med(calls))} txt" if rs else "—")
        pub = T[tid].get("published_ms")
        L.append(f"| {T[tid].get('name', tid)} | {f(pub) + ' (1 run)' if pub else ''} | " + " | ".join(cells) + " |")
    L += ["", "## Failures (status · failed checks · note)", ""]
    for r in results:
        if not r["pass"]:
            bad = ",".join(k for k, v in (r.get("checks") or {}).items() if not v)
            L.append(f"- {r['task']} · {r['arm']} · r{r['round']}: {r['status']} · {bad or '-'} · {(r.get('error') or r.get('note') or '')[:120]}")
    return "\n".join(L) + "\n"


def selftest():
    T = tasks("http://x")
    ok = lambda tid, page, run=None: all(T[tid]["check"](page, run or {}).values())
    assert ok("hotel", {"url": "http://x/fixture.html?scenario=travel#casa-flora", "text": "a\n" + HOTEL_TEXT})
    assert not ok("hotel", {"url": "http://x/#casa-flora", "text": "Your filters: Design · Free cancellation enabled · Destination anywhere"})
    assert ok("godel", {"url": "https://en.wikipedia.org/wiki/G%C3%B6del%27s_incompleteness_theorems"})
    tfs = "CBwQAhooEgoyMDI3LTAxLTIwagwIAxIIL20vMDg5NjZyDAgDEggvbS8wNGpwbEABSAFwAYIBCwj___________8BmAEC"
    fl = {"url": f"https://www.google.com/travel/flights/search?tfs={tfs}&hl=en", "text": "Flight search\nOne way\n",
          "inputs": [["Where from?", "Zürich"], ["Where to?", "London"]],
          "flights": ["From 86 US dollars. Leaves Zurich Airport at 10:10 AM on Wednesday, January 20 …", "Select flight"]}
    assert ok("flights", fl)
    assert not ok("flights", dict(fl, flights=[]))
    assert ok("wiki01", {"url": "https://en.wikipedia.org/wiki/Milk"}, {"steps": [{"kind": "click"}]})
    assert not ok("wiki01", {"url": "https://en.wikipedia.org/wiki/Milk"}, {"steps": [{"kind": "fill"}]})
    assert ok("gh-issues", {"url": "https://github.com/microsoft/vscode/issues?q=minimap"})
    assert ok("amazon-pdp", {"url": "https://www.amazon.com/Duracell-Batteries/dp/B00000JHQ6/ref=x", "title": "Duracell AA Batteries"})
    assert not ok("amazon-pdp", {"url": "https://www.amazon.com/stores/page/38DF", "title": "Amazon.com: Duracell"})
    assert ok("mdn", {"url": "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array/flatMap"})
    assert pct([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], .9) == 9 and pct([5], .9) == 5
    print("selftest ok")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=4160)
    ap.add_argument("--world", default="agentbench")
    ap.add_argument("--fixtures", default="http://127.0.0.1:4161")
    ap.add_argument("--out", required=True)
    ap.add_argument("--arms", default="shipped,turbo,classic,llm-haiku")
    ap.add_argument("--app", default="")
    ap.add_argument("--group")
    ap.add_argument("--tasks", help="only these task ids (comma list)")
    ap.add_argument("--round", type=int, default=1)
    ap.add_argument("--viewport", help="WxH the runs must measure (the probe was started with SEARCH_BACKSTAGE_SIZE); --meta fails otherwise")
    ap.add_argument("--meta", action="store_true", help="write meta.json and exit")
    ap.add_argument("--summary", action="store_true", help="summarize runs.jsonl → summary.md")
    if "--selftest" in sys.argv:
        return selftest()
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    runs_path, meta_path = os.path.join(a.out, "runs.jsonl"), os.path.join(a.out, "meta.json")

    if a.summary:
        with open(runs_path) as fh:
            results = [json.loads(x) for x in fh if x.strip()]
        meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
        text = summarize(results, meta)
        with open(os.path.join(a.out, "summary.md"), "w") as fh:
            fh.write(text)
        print(text)
        return

    copper = Copper(a.world, a.port)
    if a.meta:
        intel = json.load(open(os.path.expanduser(f"~/Library/Application Support/Copper ({a.world})/intelligence.json")))
        info = subprocess.run(["defaults", "read", os.path.join(a.app, "Contents/Info"), "CFBundleVersion"],
                              capture_output=True, text=True).stdout.strip() if a.app else ""
        copper.call("browser_tabs", {"action": "new", "url": "about:blank"})
        vp = json.loads(copper.call("browser_evaluate", {"function": "() => [innerWidth, innerHeight, devicePixelRatio]"}))
        copper.call("browser_close", {})
        if a.viewport and [int(x) for x in a.viewport.lower().split("x")] != vp[:2]:
            sys.exit(f"viewport is {vp[0]}x{vp[1]}, not {a.viewport}: this build has no SEARCH_BACKSTAGE_SIZE")
        meta = {"label": os.path.basename(os.path.dirname(a.out.rstrip("/"))), "app": a.app, "build": info,
                "machine": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
                "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "load": os.getloadavg(), "arms": a.arms,
                "viewport": vp, **{k: intel.get(k) for k in ("jevModel", "textModel", "routerModel")}}
        with open(meta_path, "w") as fh:
            json.dump(meta, fh, indent=1)
        print(json.dumps(meta))
        return

    arms = [x for x in a.arms.split(",") if x]
    for x in arms:
        if x not in ARMS:
            sys.exit(f"unknown arm {x}: {', '.join(ARMS)}")
    T = tasks(a.fixtures)
    pick = [t for t, v in T.items() if (not a.group or v["group"] == a.group) and (not a.tasks or t in a.tasks.split(","))]
    rng = random.Random(f"{a.group}-{a.round}")
    done = set()
    if os.path.exists(runs_path):
        with open(runs_path) as fh:
            done = {(r["task"], r["arm"], r["round"]) for r in map(json.loads, filter(str.strip, fh))}
    print(f"[{a.group} r{a.round}] {len(pick)} tasks × {len(arms)} arms, load {os.getloadavg()[0]:.2f}", flush=True)
    with open(runs_path, "a") as fh:
        for tid in pick:
            task = T[tid]
            order = arms[:]
            rng.shuffle(order)  # alternate arms within each task
            for arm in order:
                if (tid, arm, a.round) in done:
                    continue
                sid = f"{tid}-{arm}-{uuid.uuid4().hex[:8]}"
                if arm == "ultrafast":
                    run, page = play_ultrafast(tid, task, sid, a.fixtures)
                elif arm == "phi-mcp":
                    run, page = play_phi(tid, task, sid)
                else:
                    try:
                        run, page = play_copper(copper, task, arm, sid)
                    except ProbeDown:
                        print(f"  {tid} {arm}: Copper is not listening on {a.port} — batch stopped", flush=True)
                        sys.exit(3)
                r = record(tid, task, arm, a.round, run, page, a.fixtures, sid)
                fh.write(json.dumps(r) + "\n")
                fh.flush()
                bad = ",".join(k for k, v in r["checks"].items() if not v)
                print(f"  {tid:<11} {arm:<10} {'PASS' if r['pass'] else 'fail':<4} {r['status'] or '?':<8} "
                      f"{r['wall_ms'] or 0:>6} ms {r['decisions'] or 0:>3} dec  obs {f(r['observe_ms'])} dec {f(r['decide_ms'])} "
                      f"txt {f(r['text_ms'])} act {f(r['act_ms'])} set {f(r['settle_ms'])}  tok {r['input_tokens'] or 0}"
                      + (f"  ✗{bad}" if bad else "") + (f"  — {r['note'][:60]}" if not r["pass"] and r["note"] else ""),
                      flush=True)
                time.sleep(0.5)


if __name__ == "__main__":
    main()
