#!/usr/bin/env python3
"""The Wikipedia game, played by Jev through a running Copper — one arm per
way of seeing the page, so the arms can be compared on the same games.

    perf/wikigame.py --arms off,screenshot,marks,box:jev-1.14.0 --rounds 2
    perf/wikigame.py --world "Copper (dev)" --port 4124 --games 1-5 --arms off,marks
    perf/wikigame.py --summary results/wikigame.jsonl        # re-read a run

Each game is a start article and a target article; the goal asks Jev to reach
the target by clicking links in the article, never the search box. A run is a
`jev_run` call with `json: true`, in a tab of the harness's own, which is
closed afterwards. An arm is `vision[:model]`: `off`, `screenshot`, `marks` or
`box`, and the Jev to ask (`jev-latest` unless said). Arms alternate within a
game, so the site, the network and the API are shared as evenly as the clock
allows (the shape of jev-ultrafast's own matched runs).

What is scored, per run:
  reached   the tab ended on the target article (its URL path), DONE or not
  done      Jev said DONE *and* the tab is on the target — the only "pass"
  cheated   a TYPE_TEXT step, or a Wikipedia search URL along the way
  wall_ms   jev_run's own clock: from the first decision to the end, loading
            included; the initial navigation is outside it (as upstream)
  jev_ms    Jev's latency summed over the steps; tokens likewise
  box       hits over asks, in box mode

Results go to a JSONL file (one object per run) and a Markdown summary with
per-arm medians. Nothing here needs more than the standard library.
"""

import argparse
import json
import os
import random
import re
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Ten games. The first seven are one link away (the target is linked from the
# start article, most in the lead); the last three take two. Targets are the
# articles' canonical titles, so the final URL can be checked exactly.
GAMES = [
    ("Cheese", "Milk"),
    ("Moon", "Earth"),
    ("Coffee", "Ethiopia"),
    ("Chess", "India"),
    ("Pizza", "Naples"),
    ("William Shakespeare", "Hamlet"),
    ("Python (programming language)", "Guido van Rossum"),
    ("Lionel Messi", "Buenos Aires"),
    ("Mount Everest", "Kathmandu"),
    ("Ludwig van Beethoven", "Austria"),
]

GOAL = (
    "Wikipedia game. Starting from the article that is open, reach the Wikipedia article titled "
    "\"{target}\" by clicking links inside the article text only — one link at a time, scrolling "
    "when the useful link is below the fold. Never use the search box and never type anything. "
    "You are DONE only when the page's title is exactly \"{target}\"."
)


def wiki_url(title):
    return "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"))


def title_of(url):
    """The article title a Wikipedia URL names, or None."""
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return None
    if not parts.netloc.endswith("wikipedia.org"):
        return None
    path = urllib.parse.unquote(parts.path)
    if path.startswith("/wiki/"):
        return path[len("/wiki/"):].split("#")[0].replace("_", " ")
    query = urllib.parse.parse_qs(parts.query)
    if "title" in query:
        return query["title"][0].replace("_", " ")
    return None


def same_title(a, b):
    if a is None or b is None:
        return False
    norm = lambda t: (t[:1].upper() + t[1:]).strip()
    return norm(a) == norm(b)


class Copper:
    """The loopback MCP server of a running Copper, by its agent.json."""

    def __init__(self, world, port=None, token=None):
        support = os.path.expanduser("~/Library/Application Support")
        self.world = world
        config = {}
        path = os.path.join(support, world, "agent.json")
        if os.path.exists(path):
            with open(path) as f:
                config = json.load(f)
        self.port = port or config.get("port", 4123)
        self.token = token or config.get("token", "")
        if not self.token:
            sys.exit(f"no token: {path} has none and --token was not given")
        self.url = f"http://127.0.0.1:{self.port}/mcp"
        self.n = 0

    def call(self, tool, arguments, timeout=240):
        self.n += 1
        body = {"jsonrpc": "2.0", "id": self.n, "method": "tools/call",
                "params": {"name": tool, "arguments": arguments}}
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": f"Bearer {self.token}",
                                              "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            reply = json.load(r)
        if "error" in reply:
            raise RuntimeError(reply["error"].get("message", str(reply["error"])))
        result = reply.get("result", {})
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        if result.get("isError"):
            raise RuntimeError(text.strip() or "tool error")
        return text


def parse_arm(spec):
    # vision[:model][@strategy]; no @ is the classic loop (as measured first),
    # @default sends no strategy (this Copper's own default)
    spec_, _, strategy = spec.partition("@")
    vision, _, model = spec_.partition(":")
    vision = vision.strip().lower() or "off"
    if vision not in ("auto", "off", "screenshot", "marks", "box", "pixels"):
        sys.exit(f"arm {spec!r}: vision must be auto, off, screenshot, marks, box or pixels")
    model = model.strip()
    if vision == "box" and not model:
        model = "jev-1.14.0"
    strategy = strategy.strip() or "classic"
    return {"name": spec.strip(), "vision": vision, "model": model, "strategy": None if strategy == "default" else strategy}


def play(copper, game, arm, max_steps, verbose=True):
    start, target = game
    goal = GOAL.format(target=target)
    args = {"goal": goal, "url": wiki_url(start), "newTab": True, "json": True,
            "maxSteps": max_steps, "elements": False, "vision": arm["vision"]}
    if arm["model"]:
        args["model"] = arm["model"]
    if arm.get("strategy"):
        args["strategy"] = arm["strategy"]
    begun = time.time()
    text = None
    error = None
    try:
        text = copper.call("jev_run", args)
        run = json.loads(text)
    except (RuntimeError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
        error = f"{type(e).__name__}: {e}"[:300]
        run = {"status": "error", "note": error, "elapsed_ms": int((time.time() - begun) * 1000),
               "actions": 0, "decisions": 0, "totals": {}, "steps": [], "page": {}}
    finally:
        try:
            copper.call("browser_close", {}, timeout=20)
        except Exception:
            pass
    steps = run.get("steps", [])
    page = run.get("page", {})
    final_title = title_of(page.get("url", ""))
    reached = same_title(final_title, target)
    cheated = any(s.get("kind") == "fill" for s in steps) or any(
        "Special:Search" in (s.get("url") or "") or "search=" in (s.get("url") or "") for s in steps)
    totals = run.get("totals", {})
    out = {
        "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "game": f"{start} → {target}", "start": start, "target": target,
        "arm": arm["name"], "vision": arm["vision"], "model_asked": arm["model"],
        "model": totals.get("model", ""),
        "status": run.get("status"), "note": run.get("note", ""), "run_id": run.get("run_id"),
        "done": run.get("status") == "done" and reached and not cheated,
        "reached": reached, "cheated": cheated,
        "wall_ms": run.get("elapsed_ms"), "harness_ms": int((time.time() - begun) * 1000),
        "actions": run.get("actions"), "decisions": run.get("decisions"),
        "jev_ms": totals.get("jev_ms"), "text_ms": totals.get("text_ms"), "shot_ms": totals.get("shot_ms"),
        "input_tokens": totals.get("input_tokens"), "requests": totals.get("requests"),
        "stale": totals.get("stale"),
        "box_hits": totals.get("box_hits"), "box_asked": totals.get("box_asked"),
        "final_url": page.get("url"), "final_title": page.get("title"),
        "steps": [{"n": s.get("n"), "op": s.get("operation"), "label": (s.get("label") or "")[:80],
                   "p": s.get("probability"), "jev_ms": s.get("jev_ms"), "tok": s.get("input_tokens"),
                   "box_hit": s.get("box_hit"), "changed": s.get("page_changed")} for s in steps],
    }
    if error:
        out["error"] = error
    if verbose:
        mark = "PASS" if out["done"] else ("reached" if reached else out["status"] or "?")
        if cheated:
            mark += " (cheated)"
        print(f"  {arm['name']:<22} {mark:<18} {out['wall_ms'] or 0:>7} ms  {out['actions'] or 0:>2} actions"
              f"  jev {int(out['jev_ms'] or 0):>6} ms  {out['input_tokens'] or 0:>7} tok"
              + (f"  box {out['box_hits']}/{out['box_asked']}" if out.get("box_asked") else "")
              + (f"  — {out['note'][:70]}" if out["status"] not in ("done",) and out["note"] else ""),
              flush=True)
    return out


def median(values):
    values = [v for v in values if isinstance(v, (int, float))]
    return statistics.median(values) if values else None


def fmt(v, unit=""):
    if v is None:
        return "—"
    if isinstance(v, float) and not v.is_integer():
        return f"{v:.1f}{unit}"
    return f"{int(v)}{unit}"


def summarize(results, out=None):
    arms = []
    for r in results:
        if r["arm"] not in arms:
            arms.append(r["arm"])
    lines = ["| Arm | Model | Runs | Pass | Reached | Cheated | Median wall | Median actions | Jev ms / decision | Tokens / decision | Tokens / run | Box hits | Stale |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for arm in arms:
        rs = [r for r in results if r["arm"] == arm]
        passed = [r for r in rs if r["done"]]
        per_decision_ms = [r["jev_ms"] / r["decisions"] for r in rs if r.get("jev_ms") and r.get("decisions")]
        per_decision_tok = [r["input_tokens"] / r["decisions"] for r in rs if r.get("input_tokens") and r.get("decisions")]
        hits = sum(r.get("box_hits") or 0 for r in rs)
        asked = sum(r.get("box_asked") or 0 for r in rs)
        models = sorted({r.get("model") for r in rs if r.get("model")})
        lines.append("| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            arm, ", ".join(models) or "—", len(rs),
            f"{len(passed)}/{len(rs)}",
            f"{sum(1 for r in rs if r['reached'])}/{len(rs)}",
            sum(1 for r in rs if r["cheated"]),
            fmt(median([r["wall_ms"] for r in passed]), " ms") + (" (passes)" if passed else ""),
            fmt(median([r["actions"] for r in passed])),
            fmt(median(per_decision_ms)), fmt(median(per_decision_tok)),
            fmt(median([r["input_tokens"] for r in rs])),
            f"{hits}/{asked}" if asked else "—",
            sum(r.get("stale") or 0 for r in rs)))
    lines.append("")
    lines.append("Per game (wall ms of the run; `×` is a fail, `~` reached without DONE, `!` cheated):")
    lines.append("")
    games = []
    for r in results:
        if r["game"] not in games:
            games.append(r["game"])
    lines.append("| Game | " + " | ".join(arms) + " |")
    lines.append("|---|" + "---:|" * len(arms))
    for game in games:
        cells = []
        for arm in arms:
            rs = [r for r in results if r["game"] == game and r["arm"] == arm]
            cell = []
            for r in rs:
                tag = "" if r["done"] else ("~" if r["reached"] else "×")
                if r["cheated"]:
                    tag += "!"
                cell.append(f"{tag}{r['wall_ms'] or 0}")
            cells.append(" / ".join(cell) if cell else "—")
        lines.append(f"| {game} | " + " | ".join(cells) + " |")
    text = "\n".join(lines) + "\n"
    if out:
        with open(out, "w") as f:
            f.write(text)
    return text


def parse_games(spec):
    if not spec:
        return list(range(len(GAMES)))
    picked = []
    for part in spec.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-", 1)
            picked.extend(range(int(a) - 1, int(b)))
        else:
            picked.append(int(part) - 1)
    return [i for i in picked if 0 <= i < len(GAMES)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", default="Copper", help='the Application Support folder whose agent.json to read ("Copper (dev)")')
    ap.add_argument("--port", type=int, help="override agent.json's port (SEARCH_MCP_PORT)")
    ap.add_argument("--token", help="override agent.json's token")
    ap.add_argument("--arms", default="off,screenshot,marks,box:jev-1.14.0", help="comma list of vision[:model]")
    ap.add_argument("--games", help="which games, 1-based: 1-5 or 1,3,8 (default all)")
    ap.add_argument("--rounds", type=int, default=1, help="repeat every game × arm this many times")
    ap.add_argument("--max-steps", type=int, default=20)
    ap.add_argument("--out", default="perf/results/wikigame.jsonl")
    ap.add_argument("--summary", help="only summarize this JSONL (no runs)")
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()

    if a.summary:
        with open(a.summary) as f:
            results = [json.loads(line) for line in f if line.strip()]
        print(summarize(results, out=a.summary.rsplit(".", 1)[0] + ".md"))
        return

    arms = [parse_arm(s) for s in a.arms.split(",") if s.strip()]
    games = parse_games(a.games)
    copper = Copper(a.world, a.port, a.token)
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    rng = random.Random(a.seed)
    results = []
    total = len(games) * len(arms) * a.rounds
    print(f"{len(games)} games × {len(arms)} arms × {a.rounds} rounds = {total} runs on {copper.url} ({copper.world})")
    n = 0
    with open(a.out, "a") as f:
        for round_ in range(a.rounds):
            for gi in games:
                game = GAMES[gi]
                order = arms[:]
                rng.shuffle(order)
                print(f"\n[{round_ + 1}] {game[0]} → {game[1]}")
                for arm in order:
                    n += 1
                    r = play(copper, game, arm, a.max_steps)
                    r["round"] = round_ + 1
                    results.append(r)
                    f.write(json.dumps(r) + "\n")
                    f.flush()
                    time.sleep(1.0)
    print()
    print(summarize(results, out=a.out.rsplit(".", 1)[0] + ".md"))


if __name__ == "__main__":
    main()
