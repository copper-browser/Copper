#!/usr/bin/env python3
"""One-lane plan runner for the Copper / Ardia / Playwright token bench, on top of Ardia's harness.

Run from plugins/cli/bench with copper_side.py, playwright_side.py and this file copied into harness/:

    BENCH_HOME=... python3 -I harness/xbench.py PLAN.json RESULTS_DIR [--until 2026-11-26T03:00:00Z]

Order is runner.schedule's (round by round, tasks and contenders rotated each round), one run at a time, task
servers on BENCH_PORT_OFFSET = plan["port_offset"]. A run that ends in a harness error or a rate limit is retried
after 120 s, at most 3 times, as scheduler.Scheduler does; every attempt's record is kept. Before each run it
waits while plan["pause_file"] exists or the 1-minute load is above plan["max_load_1m"], and starts nothing after
--until. Claude Code's OAuth token is read per run from plan["claude_token_file"] (two lines: token, expiry ms).
"""
import argparse
import datetime
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ardia_side
import copper_side
import playwright_side
import runner
import servers
import summary
from procs import read_json, write_json

RETRIES = 3
RETRY_AFTER_S = 120
AUTH_FAILURE = re.compile(r"Failed to authenticate|Not logged in|Please run /login|OAuth token has expired"
                          r"|invalid[_ ]api[_ ]key|authentication_error|401 Unauthorized", re.I)


def log(msg):
    ardia_side.log(f"xbench: {msg}")


def wait_gates(plan, until):
    while True:
        if until and datetime.datetime.now(datetime.timezone.utc) >= until:
            return False
        pause = Path(plan.get("pause_file", "")).expanduser() if plan.get("pause_file") else None
        if pause and pause.exists():
            log(f"paused: {pause} exists")
            time.sleep(30)
            continue
        load = os.getloadavg()[0]
        if load > float(plan.get("max_load_1m", 10)):
            log(f"waiting: 1-minute load {load:.1f}")
            time.sleep(30)
            continue
        return True


def claude_token(plan, deadline_s, until):
    """The OAuth token for Claude Code, waiting until one valid for the whole run (plus a minute) is there."""
    path = Path(plan["claude_token_file"]).expanduser()
    waited = 0
    while True:
        try:
            tok, expires = path.read_text().split("\n")[:2]
            # the file's expiry is phi's (5 min before the real one)
            left = int(expires) / 1000 + 300 - time.time()
            if tok and left > deadline_s + 60:
                return tok
        except (OSError, ValueError):
            left = None
        if until and datetime.datetime.now(datetime.timezone.utc) >= until:
            return None
        if waited % 300 == 0:
            log(f"waiting for a fresh Claude token ({left and round(left)} s left on the one there)")
        time.sleep(30)
        waited += 30


def run_one(item, plan, results_dir):
    c = item["contender"]
    o = {"model": c.get("model"), "effort": c.get("effort"), "port_offset": plan["port_offset"]}
    if c["kind"] == "ardia":
        o.update(port=plan["ardia_port"], cli=plan.get("cli", "dev"), app=plan.get("ardia_app"))
        return ardia_side.run(item["task"], c["agent"], item["run_id"], results_dir, o, contender=c["id"])
    if c["kind"] == "copper":
        o.update(port=plan["copper_port"], world=plan["copper_world"], app=plan.get("copper_app"))
        return copper_side.run(item["task"], c["agent"], item["run_id"], results_dir, o, contender=c["id"])
    if c["kind"] == "playwright":
        o.update(cdp_port=plan["playwright_cdp_port"], chrome=plan.get("chrome_app"), pw_dir=plan.get("pw_dir"))
        return playwright_side.run(item["task"], c["agent"], item["run_id"], results_dir, o, contender=c["id"])
    raise SystemExit(f"unknown kind {c['kind']}")


def auth_failure(rec):
    if rec.get("pass") or rec.get("tokens"):
        return None
    texts = [str(rec.get("final_message") or ""), *map(str, rec.get("errors") or [])]
    try:
        texts.append(Path(rec["stderr_file"]).read_text(errors="replace")[-4000:])
    except (KeyError, OSError):
        pass
    m = next((AUTH_FAILURE.search(t) for t in texts if AUTH_FAILURE.search(t)), None)
    return m.group(0) if m else None


def keep_attempt(results_dir, run_id, attempt):
    runs = Path(results_dir) / "runs"
    for suffix in (".json", ".events.jsonl", ".stderr.log"):
        src = runs / f"{run_id}{suffix}"
        if src.exists():
            shutil.move(str(src), str(runs / f"{run_id}.attempt{attempt}{suffix}"))
    rec = read_json(runs / f"{run_id}.attempt{attempt}.json")
    if rec:  # the moved record keeps its run_id, so summary.merged_runs still prefers a clean retry over it
        rec.update(events_file=str(runs / f"{run_id}.attempt{attempt}.events.jsonl"),
                   stderr_file=str(runs / f"{run_id}.attempt{attempt}.stderr.log"), attempt=attempt)
        write_json(runs / f"{run_id}.attempt{attempt}.json", rec)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plan")
    ap.add_argument("results")
    ap.add_argument("--until", help="ISO time (UTC); no run starts after it")
    a = ap.parse_args()
    plan = json.loads(Path(a.plan).read_text())
    results = Path(a.results).expanduser()
    until = datetime.datetime.fromisoformat(a.until.replace("Z", "+00:00")) if a.until else None
    write_json(results / "plan.json", plan)
    items = runner.schedule(plan)
    order = {it["run_id"]: n for n, it in enumerate(items)}
    done = lambda it: (read_json(results / "runs" / f"{it['run_id']}.json") or {"harness_error": 1})
    pending = [it for it in items if done(it).get("harness_error")]
    tries, not_before = {}, {}
    log(f"{len(pending)} of {len(items)} runs to go; offset +{plan['port_offset']}")
    try:
        while pending:
            now = time.time()
            ready = [it for it in pending if not_before.get(it["run_id"], 0) <= now]
            if not ready:
                time.sleep(10)
                continue
            item = ready[0]
            if not wait_gates(plan, until):
                log("cutoff reached; starting nothing more")
                break
            env_token = None
            if item["contender"]["agent"] == "claude":
                env_token = claude_token(plan, 700, until)
                if not env_token:
                    log("cutoff reached waiting for a Claude token")
                    break
                os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = env_token
            else:
                os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
            attempt = tries.get(item["run_id"], 0) + 1
            log(f"start {item['run_id']} (attempt {attempt})")
            t0 = time.time()
            load = round(os.getloadavg()[0], 1)
            try:
                rec = run_one(item, plan, results)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                rec = {"run_id": item["run_id"], "contender": item["contender"]["id"], "task": item["task"],
                       "side": item["contender"]["kind"], "agent": item["contender"]["agent"], "pass": False,
                       "method": None, "invariants": None, "harness_error": f"{type(e).__name__}: {e}"}
            finally:
                os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
            reason = runner.rate_limit_reason(dict(rec, side="ardia" if rec.get("side") in ("copper", "playwright") else rec.get("side")))
            if reason:
                rec["harness_error"] = f"rate_limited: {reason}"
            auth = auth_failure(rec)
            if auth and not rec.get("harness_error"):
                rec["harness_error"] = f"auth: {auth}"
            t1 = time.time()
            rec.update({"host": runner.HOST, "lane": "xbench", "port_offset": plan["port_offset"], "attempt": attempt,
                        "round": item["round"], "lanes_active": 1, "load_1m_at_start": load,
                        "run_started_epoch": round(t0, 3), "run_ended_epoch": round(t1, 3)})
            write_json(results / "runs" / f"{item['run_id']}.json", rec)
            with open(results / "progress.jsonl", "a") as f:
                f.write(json.dumps({"run_id": item["run_id"], "attempt": attempt, "pass": rec.get("pass"),
                                    "tokens": (rec.get("tokens") or {}).get("total"),
                                    "harness_error": rec.get("harness_error"),
                                    "elapsed_s": round(t1 - t0, 1), "ended": datetime.datetime.now(
                                        datetime.timezone.utc).isoformat(timespec="seconds")}) + "\n")
            pending.remove(item)
            if rec.get("harness_error") and attempt <= RETRIES:
                keep_attempt(results, item["run_id"], attempt)
                tries[item["run_id"]] = attempt
                not_before[item["run_id"]] = t1 + RETRY_AFTER_S
                pending.append(item)
                pending.sort(key=lambda it: order[it["run_id"]])
            log(f"{item['run_id']}: pass={rec.get('pass')} tokens={(rec.get('tokens') or {}).get('total')} "
                f"{rec.get('harness_error') or ''}")
            write_json(results / "summary.json", summary.build(results))
    finally:
        os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
        if plan.get("stop_after", True):
            ardia_side.quit_instance({"port": plan["ardia_port"]})
            copper_side.quit_world({"port": plan["copper_port"], "world": plan["copper_world"]})
            servers.stop()
        write_json(results / "summary.json", summary.build(results))


if __name__ == "__main__":
    main()
