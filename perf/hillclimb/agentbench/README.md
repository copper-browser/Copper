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
4160, Jev on; intelligence.json = only `jevKey jevEndpoint jevModel routerKey routerURL routerModel` copied from
`Copper (dev)`, never printed; no `textModel` unless `AGENTBENCH_TEXT_MODEL` names one — the bench runs what a fresh
install ships, `dev` takes the dev world's haiku as rounds 1–2 did), starts the build as a launchd job in the GUI
session (`SEARCH_HEADLESS=1`; the page measured 1280×800 in base whatever `SEARCH_HEADLESS_SIZE` said — upstream used 1120×780; each run records it), starts
`fixtures/server.py` on 4161, then works through the whole plan (every group × round × task × arm, the arms of a
task alternating) in `lockf -k ~/hc/mini.lock` holds of `AGENTBENCH_CHUNK` seconds (300): the lock is shared and
every wait for it is long. A Google Flights run waits `AGENTBENCH_FLIGHTS_GAP` (45 s) after the last one on the Mac
(other runs go first meanwhile; when only Flights is left the wait is outside the lock). Already-recorded runs are
skipped, so a rerun resumes. Stops both at exit. Never touches port 4123 or the installed Copper.

When `ARMS` has `same`, a second probe world `Copper (agentbench-same)` runs on port+2 (`AGENTBENCH_SAME_PORT`)
at upstream's conditions. Since round 3 (Collin, 2026-11-14) the bench compares Copper's own methods with each
other — no upstream/Chrome arm — so no arm uses it. `--meta` fails if a world's
page isn't the size asked; `meta.json` has both worlds as configured, and `--summary` adds `resolved`: per arm,
the Jev that answered, the text model that wrote values and the page size measured after each run.

`meta.json` also has `sha` (the build's commit: run with `AGENTBENCH_SRC=<its git worktree>` on the devbox),
`harness_sha` and `binary_sha256` (the first 16 hex of the Copper executable), so two runs say what they measured.

Google Flights: each run records `provider_error` (the final page says Google's "Oops, something went wrong"),
`results_req` (the GetShoppingResults calls the steps logged, builds from hc3/jev) and the From/To `inputs`; the
summary has a table of them per arm. `flights_probe.py` steps Flights one `jev_step` at a time and captures the
Reload control, the page and the tab's requests right after Search (round 3: a visible "Oops, something went wrong.
Reload" panel, GetShoppingResults answered 200 within 0.5 s — Google's error, not a hidden or transient node).

## Suite

| Group | Tasks | Checker (independent of Jev's DONE) | Runs/arm (default) |
|---|---|---|---|
| ultrafast | jev-ultrafast's 3 published: `hotel` (its fixture, frozen copy), `godel` (Main_Page → article), `flights` (ZRH→LON one-way, date moved to **2027-01-20**, upstream's 2026-09-20 is past) | hotel: `#casa-flora` + "Your filters: Design · Free cancellation enabled · Destination Lisbon" (upstream's smoke.py); godel: exact title; flights: search URL, `tfs` has the date, from = Zürich/Zurich or its airport ("Zurich Airport (ZRH)"), to = London, One way, ≥1 "Select flight" all on Wed Jan 20 (upstream's flights.py) | 10 each |
| wikigame | perf/wikigame.py's 10 games | reached target, no typing, no search URL | 3 each (30/arm) |
| uibench | perf/uibench's 8 tasks (frozen copy of app.html) | the app server's verdict | 2 each (16/arm) |
| realweb | `gh-issues` (vscode issue search "minimap"), `wiki-lang` (Alan Turing → German), `amazon-pdp` ("AA batteries" → a /dp/, /gp/product/ or mobile /gp/aw/d/ page, no cart), `pydocs` (pathlib page), `mdn` (Array flatMap page) — all read-only, no login | URL/host/path (+ query/title) | 2 each (10/arm) |
| probes (opt-in) | local pages: `far-link` (the one "Annapurna" link ~40 screens down), `no-link` (a title that isn't linked; scroll for it), `human-check` (a shop whose search lands on a bot check with "I am human") | far-link: reached, no typing; no-link: BLOCKED within 8 actions; human-check: BLOCKED with a human-check hand-back, button never clicked | 2 each |
| paraphrase (opt-in) | hotel and Flights said other ways: `hotel-lc` (all lowercase), `flights-lc` (lowercase), `flights-iata` ("ZRH → LHR on 2027-01-20"), `flights-de` (German) | as the originals (hotel-lc: any case; flights-iata: to = Heathrow) | 2 each |

Pass = DONE **and** the checker (uibench: the app's verdict alone, as perf/uibench.py).
Per run also: values typed straight from the goal (`literal_fills`) vs written by the text model (`text_calls`,
`text_reused`), stale decisions and their operations (`stale_ops`), settles and settles at the 400 ms cap
(builds from hc2/jev; with what was still moving, per step). The summary shows Stale % (stale / decisions),
Settle % (settle ms / wall) and Capped (settles at the cap).
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
