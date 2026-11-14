# agentbench — Track D (Jev agent performance)

One suite, every arm alternating within each task, on a headless probe world of a given build.

```sh
# from the devbox (syncs to the mini, runs there, copies results back):
perf/hillclimb/agentbench.sh <label> ~/hc/base/Copper.app            # all groups, ~45 min
ARMS=shipped,classic ROUNDS_ULTRAFAST=3 perf/hillclimb/agentbench.sh try1 ~/hc/try1/Copper.app ultrafast,uibench
# results: mac-mini:~/hc/out/<label>/agentbench/{runs.jsonl,summary.md,meta.json,run.log}
#       →  ~/plans/copper-hillclimb-2026-11-14/out/<label>/agentbench/
python3 perf/hillclimb/agentbench/agentbench.py --out <that dir> --summary   # re-table
```

On the Mac it: writes the probe world `Copper (agentbench)` (agent.json with its own token, port
4160, Jev on; intelligence.json = only `jevKey jevEndpoint jevModel routerKey routerURL routerModel
textModel` copied from `Copper (dev)`, never printed), starts the build as a launchd job in the GUI
session (`SEARCH_HEADLESS=1`; the page measured 1280×800 in base whatever `SEARCH_HEADLESS_SIZE` said — upstream used 1120×780; each run records it), starts
`fixtures/server.py` on 4161, then runs one `lockf -k ~/hc/mini.lock` batch per (group, round), and
stops both at exit. Never touches port 4123 or the installed Copper.

## Suite

| Group | Tasks | Checker (independent of Jev's DONE) | Runs/arm (default) |
|---|---|---|---|
| ultrafast | jev-ultrafast's 3 published: `hotel` (its fixture, frozen copy), `godel` (Main_Page → article), `flights` (ZRH→LON one-way, date moved to **2027-01-20**, upstream's 2026-09-20 is past) | hotel: `#casa-flora` + "Your filters: Design · Free cancellation enabled · Destination Lisbon" (upstream's smoke.py); godel: exact title; flights: search URL, `tfs` has the date, from/to field values, One way, ≥1 "Select flight" all on Wed Jan 20 (upstream's flights.py) | 10 each |
| wikigame | perf/wikigame.py's 10 games | reached target, no typing, no search URL | 1 each (10/arm) |
| uibench | perf/uibench's 8 tasks (frozen copy of app.html) | the app server's verdict | 2 each (16/arm) |
| realweb | `gh-issues` (vscode issue search "minimap"), `wiki-lang` (Alan Turing → German), `amazon-pdp` ("AA batteries" → a /dp/ page, no cart), `pydocs` (pathlib page), `mdn` (Array flatMap page) — all read-only, no login | URL/host/path (+ query/title) | 2 each (10/arm) |

Pass = DONE **and** the checker (uibench: the app's verdict alone, as perf/uibench.py).
Per run (`runs.jsonl`): pass, checks, status/note, wall (jev_run's clock: first decision → end,
initial navigation excluded, upstream's boundary), decisions, actions, per-phase ms
(observe/decide/text/act/settle — sums over steps from the json trace), Jev ms, input tokens,
model/strategy/vision as answered, load average, every step.

## Arms

| Arm | jev_run args | Meaning |
|---|---|---|
| `shipped` | none | the build's default (fork 2026-11: turbo + watched, vision auto) |
| `turbo` | strategy turbo, vision auto | no glide ever; headless never glides, so vs `shipped` it is an A/A noise check |
| `classic` | strategy classic, vision off | the original loop (control) |
| `llm-haiku` | strategy fast,llm=haiku, vision off | a small LLM decides instead of Jev |
| `ultrafast` | — | browser-use jev-ultrafast in Chrome. **Prepared, not run** (needs Collin's OK for Chrome) |
| `phi-mcp` | — | stub: phi via browser_snapshot/click. A full LLM agent per run (~10–60 s, $); `play_phi` says how |

## The ultrafast arm (once Collin approves Chrome on the mini)

Same tasks, same checkers, alternating with the Copper arms in the same batch
(`agentbench.py` shells out to `ultrafast_arm.py` once per run inside jev-ultrafast's uv env).

```sh
ssh mac-mini
brew install --cask google-chrome            # not installed on the mini today; or use a Chrome for Testing build
git clone https://github.com/browser-use/jev-ultrafast ~/src/jev-ultrafast
cd ~/src/jev-ultrafast && git checkout 1231850 && /opt/homebrew/bin/uv sync
# .env from the probe world's keys (never printed). Same Jev model as Copper; text model = Copper's (haiku via the
# router), so only the loop differs. Upstream's own run used inception/mercury-2.5 on OpenRouter (needs an OpenRouter key).
python3 - <<'PY'
import json, os
d = json.load(open(os.path.expanduser("~/Library/Application Support/Copper (agentbench)/intelligence.json")))
env = {"TYPESAFE_API_KEY": d["jevKey"], "TYPESAFE_MODEL": d.get("jevModel", "jev-latest"),
       "TEXT_MODEL_API_KEY": d["routerKey"], "TEXT_MODEL_BASE_URL": d["routerURL"].rstrip("/") + "/v1",
       "TEXT_MODEL": d.get("textModel", "haiku"), "TEXT_MODEL_REASONING": "none"}
p = os.path.expanduser("~/src/jev-ultrafast/.env")
with open(os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
    f.write("".join(f"{k}={v}\n" for k, v in env.items()))
PY
open -g -a "Google Chrome" --args --remote-debugging-port=9222 --user-data-dir=$HOME/hc/chrome-agentbench --no-first-run
/opt/homebrew/bin/uv run --project ~/src/jev-ultrafast browser-harness --doctor     # must say connected
# from the devbox:
AGENTBENCH_ALLOW_CHROME=1 ARMS=shipped,turbo,classic,llm-haiku,ultrafast \
  perf/hillclimb/agentbench.sh ultrafast-vs-<label> ~/hc/<label>/Copper.app ultrafast,wikigame,uibench,realweb
# after: quit that Chrome (pkill -f chrome-agentbench) and rm -rf ~/hc/chrome-agentbench
```

Risks to check on the first run: the router may refuse upstream's
`reasoning` / `response_format` fields for haiku (then drop `TEXT_MODEL_REASONING` or use mercury via
OpenRouter); browser-harness wants a Chrome with remote debugging on — the `--user-data-dir` keeps it off any
real profile. Ultrafast has no observe/act/settle split: its `decide_ms` = Jev latency, the rest stays empty.
