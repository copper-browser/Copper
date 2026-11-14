"""One run of browser-use jev-ultrafast, for agentbench's `ultrafast` arm. NOT run in Phase 0
(it drives Chrome over CDP; waiting for Collin's OK). agentbench.py calls it once per run:

    uv run --project ~/src/jev-ultrafast --env-file ~/src/jev-ultrafast/.env python ultrafast_arm.py \
        --url URL --goal GOAL --max-actions 20 --read '() => ({url: location.href, ...})'

Prints one JSON line: {"run": <jev_run-shaped dict>, "page": <READ_PAGE result>}, so the same
checkers score both browsers. The clock is upstream's own (first prediction → DONE/BLOCKED,
initial navigation excluded), same boundary as Copper's jev_run elapsed_ms.
"""

import argparse
import json
import os
import sys
import time

from jev_ultrafast import Agent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--goal", required=True)
    ap.add_argument("--max-actions", type=int, default=20)
    ap.add_argument("--read", required=True, help="a sync JS function returning the checker's page dict")
    a = ap.parse_args()
    run = {"status": "error", "note": "", "elapsed_ms": None, "steps": [], "totals": {}}
    page = {}
    agent = None
    try:
        agent = Agent(a.url, a.goal)
        for state in agent.run():
            if len(state["history"]) >= a.max_actions:
                run["note"] = f"agentbench budget: {a.max_actions} actions"
                break
        state = agent.snapshot()
        run["status"] = "blocked" if run["note"] else state["status"]
    except Exception as e:  # noqa: BLE001 — a failed run is a data point, not a crash
        run["note"] = f"{type(e).__name__}: {e}"[:300]
        state = agent.snapshot() if agent else {}
    finally:
        if agent:
            try:
                page = agent.browser.evaluate(f"({a.read})()") or {}
            except Exception as e:  # noqa: BLE001
                page = {"read_error": f"{type(e).__name__}: {e}"[:200]}
            agent.close()
    decisions = state.get("decisions") or []
    history = state.get("history") or []
    jev_ms = sum(d.get("latency_ms") or 0 for d in decisions)
    run.update({
        "elapsed_ms": state.get("elapsed_ms"),
        "decisions": len(decisions),
        "actions": len(history),
        "totals": {
            "jev_ms": jev_ms, "decide_ms": jev_ms,  # upstream has no observe/act/settle split
            "text_ms": sum(c.get("latency_ms") or 0 for c in state.get("text_calls") or []),
            "input_tokens": sum((d.get("usage") or {}).get("input_tokens") or 0 for d in decisions),
            "requests": len(decisions), "model": os.environ.get("TYPESAFE_MODEL", "jev-latest"),
            "strategy": "jev-ultrafast", "vision": "off",
        },
        "steps": [{"operation": h.get("operation"), "kind": h.get("kind"), "label": h.get("action"),
                   "text": h.get("text"), "probability": h.get("probability"), "url": h.get("url"),
                   "jev_ms": h.get("latency_ms"), "text_ms": h.get("text_latency_ms")} for h in history],
        "page": {"url": (state.get("page") or {}).get("url")},
        "ran_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    })
    print(json.dumps({"run": run, "page": page}))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
