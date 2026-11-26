#!/usr/bin/env python3
"""Turn an xbench results dir into the site's data and the raw run list.

    python3 perf/agentbench/export.py RESULTS_DIR --bench <plugins>/plugins/cli/bench --meta meta.json \
        --site site/assets/agentbench.json --runs perf/agentbench/results/2026-11-25/runs.jsonl
    python3 perf/agentbench/export.py --self-check

The cells use Ardia's own summary (harness/summary.py: cell()), mapped the way their site's
apps/site/scripts/sync-computer-use.mjs maps it into computerUse.json: tokens = median total tokens per run
(input incl. cached + output), time = median wall seconds of every graded run, timePassing = the same over passing
runs; harness errors (and rate limits) are not runs. meta.json carries the versions, machine and plugins commit.
"""
import argparse
import datetime
import json
import sys
from pathlib import Path

AGENT = {"claude": "Claude Code", "codex": "Codex"}
MODEL = {"claude-opus-5-5": "Opus 5.5", "gpt-6.1-sol": "GPT-6.1 Sol"}
TOKEN_KINDS = ("input", "cached_input", "cache_write_input", "uncached_input", "output", "reasoning_output", "total")
METRICS = {
    "tokens": "median total tokens per run: input (fresh + cache write + cache read) + output, as the agent CLI "
              "reports them (Claude Code result.modelUsage, Codex turn.completed usage); Ardia's summary.median_tokens",
    "time": "median wall seconds of the agent process, every graded run; summary.median_time_s",
    "timePassing": "median wall seconds over passing runs; summary.median_time_s_passing",
    "runs": "graded runs (harness errors and rate limits retried and not counted)",
    "passes": "runs whose server-side check passed before the deadline with no reset by the agent (harness/grading.py)",
    "totals.tokens": "sum over tasks of the cell's median tokens (the per-side total Ardia's chart shows)",
}


def rnd(v, places):
    return round(v, places) if isinstance(v, (int, float)) else None


def site_data(summary, meta, started_days):
    contenders = [{"id": c["id"], "side": c["side"], "agent": AGENT.get(c["agent"], c["agent"]),
                   "model": MODEL.get(c["model"], c["model"]), "modelId": c["model"], "effort": c.get("effort")}
                  for c in summary["contenders"]]
    cells = [{"task": c["task"], "contender": c["contender"], "runs": c["runs"], "passes": c["passes"],
              "time": rnd(c["median_time_s"], 1), "timePassing": rnd(c["median_time_s_passing"], 1),
              "tokens": round(c["median_tokens"]) if isinstance(c["median_tokens"], (int, float)) else None}
             for c in summary["cells"]]
    days = sorted(started_days)
    return {
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "from": days[0] if days else None,
        "to": days[-1] if days else None,
        **{k: meta[k] for k in ("versions", "machine", "pluginsCommit", "bench") if k in meta},
        "repeats": summary["repeats"],
        "planned": len(summary["tasks"]) * len(contenders) * summary["repeats"],
        "runs": sum(c["runs"] for c in cells),
        "metrics": METRICS,
        "tasks": [{"id": t["id"], "title": t["title"]} for t in summary["tasks"]],
        "contenders": contenders,
        "cells": cells,
        "totals": [{"contender": c["id"],
                    "runs": sum(x["runs"] for x in cells if x["contender"] == c["id"]),
                    "passes": sum(x["passes"] for x in cells if x["contender"] == c["id"]),
                    "tokens": sum(x["tokens"] or 0 for x in cells if x["contender"] == c["id"])} for c in contenders],
    }


def run_line(r):
    tokens = r.get("tokens") if isinstance(r.get("tokens"), dict) else None
    check = r.get("check") if isinstance(r.get("check"), dict) else {}
    return {
        "run_id": r["run_id"], "task": r["task"], "contender": r["contender"], "side": r.get("side"),
        "agent": r.get("agent"), "repeat": int(r["run_id"].rsplit("--r", 1)[1]), "attempt": r.get("attempt", 1),
        "started_at": r.get("started_at"), "pass": bool(r.get("pass")),
        "check": {"pass": check.get("pass"), "matched": check.get("matched"), "total": check.get("total"),
                  "details": check.get("details"), "method": (check.get("method") or {}).get("label")
                  if isinstance(check.get("method"), dict) else check.get("method"),
                  "invariants": check.get("invariants"), "error": check.get("error")},
        "reset_by_agent": r.get("reset_by_agent"), "timed_out": r.get("timed_out"),
        "seconds": r.get("wall_s"), "time_to_correct_s": r.get("time_to_correct_s"),
        "tokens": {k: tokens.get(k) for k in TOKEN_KINDS if k in tokens} if tokens else None,
        "model": r.get("model"), "effort": r.get("effort"),
        "models_reported": sorted((tokens or {}).get("model_usage") or {}) or None,
        "commands": r.get("commands"), "mcp_calls": r.get("mcp_calls"), "mcp_by_tool": r.get("mcp_by_tool"),
        "shell_commands": r.get("shell_commands"), "turns": r.get("turns"), "exit_code": r.get("exit_code"),
        "cli_is_error": r.get("cli_is_error"),
        "error": r.get("harness_error") or r.get("error") or (r.get("errors") or None),
        "harness_error": bool(r.get("harness_error")),
    }


def export(results, bench, meta_path, site_out, runs_out):
    sys.path.insert(0, str(Path(bench).resolve() / "harness"))
    import summary as ardia_summary  # Ardia's harness/summary.py, unchanged
    from procs import read_json

    s = ardia_summary.build(results)
    raw = [read_json(p) for p in sorted((Path(results) / "runs").glob("*.json"))]
    raw = [r for r in raw if r and r.get("run_id")]
    raw.sort(key=lambda r: (r.get("run_started_epoch") or 0))
    days = {datetime.datetime.fromisoformat(r["started_at"]).astimezone(datetime.timezone.utc).date().isoformat()
            for r in raw if r.get("started_at") and not r.get("harness_error")}
    data = site_data(s, json.loads(Path(meta_path).read_text()), days)
    Path(site_out).parent.mkdir(parents=True, exist_ok=True)
    Path(site_out).write_text(json.dumps(data, indent=2) + "\n")
    Path(runs_out).parent.mkdir(parents=True, exist_ok=True)
    with open(runs_out, "w") as f:
        for r in raw:
            f.write(json.dumps(run_line(r), ensure_ascii=False) + "\n")
    Path(runs_out).with_name("summary.json").write_text(json.dumps(s, indent=2) + "\n")
    return data, len(raw)


def self_check():
    summary = {"repeats": 3, "tasks": [{"id": "news", "title": "News"}, {"id": "shop", "title": "Shop"}],
               "contenders": [{"id": "copper-claude", "side": "copper", "agent": "claude", "model": "claude-opus-5-5",
                               "effort": "high"},
                              {"id": "ardia-codex", "side": "ardia", "agent": "codex", "model": "gpt-6.1-sol"}],
               "cells": [{"task": "news", "contender": "copper-claude", "runs": 3, "passes": 2, "median_time_s": 49.04,
                          "median_time_s_passing": 47.96, "median_tokens": 654281.5},
                         {"task": "shop", "contender": "copper-claude", "runs": 2, "passes": 0, "median_time_s": 480.0,
                          "median_time_s_passing": None, "median_tokens": 100.0},
                         {"task": "news", "contender": "ardia-codex", "runs": 0, "passes": 0, "median_time_s": None,
                          "median_time_s_passing": None, "median_tokens": None}]}
    d = site_data(summary, {"pluginsCommit": "abc", "machine": "m"}, {"2026-11-26", "2026-11-25"})
    assert d["planned"] == 2 * 2 * 3 and d["runs"] == 5, d
    assert (d["from"], d["to"]) == ("2026-11-25", "2026-11-26")
    c0 = d["cells"][0]
    assert c0 == {"task": "news", "contender": "copper-claude", "runs": 3, "passes": 2, "time": 49.0,
                  "timePassing": 48.0, "tokens": 654282}, c0
    assert d["cells"][1]["timePassing"] is None and d["cells"][2]["tokens"] is None
    assert d["contenders"][0]["agent"] == "Claude Code" and d["contenders"][1]["model"] == "GPT-6.1 Sol"
    assert d["totals"][0] == {"contender": "copper-claude", "runs": 5, "passes": 2, "tokens": 654382}
    assert d["pluginsCommit"] == "abc"
    line = run_line({"run_id": "news--copper-claude--r2", "task": "news", "contender": "copper-claude", "pass": True,
                     "tokens": {"input": 10, "output": 2, "total": 12, "raw_usage": {"x": 1}, "model_usage": {"m": {}}},
                     "check": {"pass": True, "method": {"label": "ui"}}, "harness_error": None})
    assert line["repeat"] == 2 and line["tokens"] == {"input": 10, "output": 2, "total": 12}
    assert line["check"]["method"] == "ui" and line["models_reported"] == ["m"] and not line["harness_error"]
    print("self-check ok")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        self_check()
        sys.exit(0)
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--bench", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--site", required=True)
    ap.add_argument("--runs", required=True)
    a = ap.parse_args()
    data, n = export(a.results, a.bench, a.meta, a.site, a.runs)
    print(f"wrote {a.site}: {data['runs']} of {data['planned']} runs, {data['from']} to {data['to']}; {n} records")
