# agentbench: tokens an agent spends driving Copper, Ardia and Playwright MCP

How many tokens Claude Code and Codex spend doing the same eight local web tasks through three browsers. The tasks,
the prompts, the server-side checkers, the grading and the token count are Ardia's own public bench
([ardia-browser/plugins](https://github.com/ardia-browser/plugins/tree/main/plugins/cli/bench), Apache-2.0), used
unchanged at commit `d87fc6cf8aa7b3fa26ad1393a7ef6caa7e7fec28` (2026-11-25). We added two sides to their harness
(`copper_side.py`, `playwright_side.py`) and a one-lane runner (`xbench.py`). Every number on the site comes from
`results/2026-11-25/runs.jsonl`; failures and losses are in it.

## What is measured

- **Tasks**: the eight in their README (`calendar`, `research`, `booking`, `shop`, `multitab`, `news`, `triage`,
  `compare`), each a small web app on 127.0.0.1 with traps, a deadline (480 or 600 s), and a checker on its own
  server (`GET /api/check`). A run passes when the check passes before the deadline and the agent did not reset the
  task (`harness/grading.py`).
- **Tokens**: what the agent CLI reports, counted by their `parse_claude` / `parse_codex` (harness/ardia_side.py):
  Claude Code `result.modelUsage` input + cache-creation + cache-read + output; Codex `turn.completed` usage
  input (incl. cached) + output. The site shows their statistic: the median of a cell's runs
  (`summary.median_tokens`); time is the median wall time of the agent process (`median_time_s`, and
  `median_time_s_passing` over passing runs). Harness errors and rate limits are retried and are not runs.
- **Prompt**: the registry's prompt for every contender (with their date line), plus one line saying how to reach
  the browser:
  - Copper: "Use the `copper` MCP server to reach this browser."
  - Ardia: their line, "Use the `ardia` command with `--port 4621` to reach this Ardia instance."
  - Playwright: "Use the `playwright` MCP server to reach this browser."

## Contenders

| id | browser | how the agent reaches it |
|---|---|---|
| `copper-claude`, `copper-codex` | Copper 1.0.20261124.117 (release, a copy), headless probe world `xbagent` | Copper's built-in MCP server, Streamable HTTP `http://127.0.0.1:4620/mcp`, bearer token from the world's `agent.json` (handed to the agent by env var, never in a command or file) |
| `ardia-claude`, `ardia-codex` | Ardia 0.2.48 (a copy), their side unchanged (`kind: ardia`): hidden instance `open -g -n`, DevTools port 4621 | the `ardia` CLI built from the same plugins commit (`bench.py freeze-cli`, Bun 1.3.14) and its skill installed in the run's workdir |
| `playwright-claude`, `playwright-codex` | Google Chrome 158.0.8127.89 (a copy), headless, fresh throwaway profile per run, DevTools on 4623 | Playwright MCP 0.0.86 (`@playwright/mcp@latest` on 2026-11-25), stdio, `--cdp-endpoint` to that Chrome |

Agents: Claude Code 2.1.322 with `claude-opus-5-5` (effort high) and Codex CLI 0.167.2 with `gpt-6.1-sol`
(reasoning effort high), started exactly as their harness starts them (`ardia_side.claude_command` /
`codex_command`: `claude -p --setting-sources project --strict-mcp-config --no-session-persistence`, `codex exec
--ignore-user-config --ephemeral …`), the MCP sides adding only `--mcp-config` (Claude) or `-c mcp_servers.*`
(Codex) as their OpenCode side does.

**Copper exposes only plain browser tools.** `agent.json` has `"jev": false` and the world has no
`intelligence.json`, so nothing in Copper can call a model; `copper_side.prepare_tab` refuses to run if
`tools/list` holds any `jev_*` or `copper_research` tool, and every record keeps the list. The 45 tools the agent
saw: `browser_tabs browser_sign_in browser_autofill browser_vault_save browser_vault_note browser_navigate
browser_navigate_back browser_navigate_forward browser_snapshot browser_click browser_mouse_click_xy browser_type
browser_fill_form browser_press_key browser_hover browser_select_option browser_handle_dialog browser_drag
browser_take_screenshot browser_evaluate browser_wait_for browser_scroll browser_get_text browser_console_messages
browser_find browser_resize browser_close browser_groups browser_perf_probe browser_crashes browser_file_upload
browser_pdf_save browser_downloads browser_network_requests browser_cookies browser_history browser_bookmarks
browser_permissions browser_handoff browser_spaces canvas_create canvas_join cloud_history_delete voice_status
voice_transcript`.

## What differs per side

- Start page: Ardia's side opens the start URL as the only tab through DevTools; Copper's opens it with
  `browser_tabs new {focus: true}` and closes every other tab (an agent without a tab of its own works on the one
  on screen); Playwright's launches Chrome on it, and Playwright MCP picks up that tab over CDP.
- Browser lifetime: Ardia and Copper keep one instance across runs (Ardia's side does so itself; task state is
  reset on the task server before each run); Chrome is fresh for each Playwright run.
- Claude Code lists MCP tools through its ToolSearch (deferred tools) on the Copper and Playwright sides, as it
  would for any user; the Ardia side has no MCP server, its skill and Bash.

## Results

See `results/2026-11-25/` (`runs.jsonl`, one line per attempt; `summary.json`, Ardia's summary of the same runs)
and `site/assets/agentbench.json` (the page's data, shaped like Ardia's `computerUse.json`).

Run 2026-11-25 18:56 to 2026-11-26 03:01 UTC: 98 of 144 planned runs (repeats 1 and 2 of every cell, plus
repeat 3 of `booking` for the two Ardia contenders, which the round-robin had reached at the 03:00 cutoff). Every
run passed its check; no harness errors, rate limits or retries. The mini was held for other timed runs from 21:15
to about 02:40 UTC (the shared `PAUSE` file), which cost the third repeat. Median tokens per cell (passes/runs):

| task | copper-claude | copper-codex | ardia-claude | ardia-codex | playwright-claude | playwright-codex |
|---|---|---|---|---|---|---|
| calendar | 2/2 319K | 2/2 271K | 2/2 190K | 2/2 147K | 2/2 425K | 2/2 195K |
| research | 2/2 368K | 2/2 545K | 2/2 261K | 2/2 196K | 2/2 367K | 2/2 296K |
| booking | 2/2 1269K | 2/2 490K | 3/3 360K | 3/3 213K | 2/2 740K | 2/2 432K |
| shop | 2/2 853K | 2/2 899K | 2/2 694K | 2/2 390K | 2/2 955K | 2/2 603K |
| multitab | 2/2 1932K | 2/2 1662K | 2/2 418K | 2/2 496K | 2/2 830K | 2/2 694K |
| news | 2/2 553K | 2/2 357K | 2/2 352K | 2/2 202K | 2/2 812K | 2/2 354K |
| triage | 2/2 872K | 2/2 722K | 2/2 590K | 2/2 397K | 2/2 1166K | 2/2 600K |
| compare | 2/2 669K | 2/2 454K | 2/2 465K | 2/2 267K | 2/2 554K | 2/2 440K |
| sum of medians | 6.83M | 5.40M | 3.33M | 2.31M | 5.85M | 3.61M |

Ardia's CLI + skill used the fewest tokens on all eight tasks with both agents. Against Playwright MCP, Copper's
MCP used fewer tokens on four of eight tasks with Claude Code (calendar, shop, news, triage; research a tie) and
more on all eight with Codex; multitab and booking cost Copper the most. The smoke run (`news` once per contender,
all passing) is in `smoke-runs.jsonl`; it is not on the page.

## Caveats

- One Mac mini (Apple M6, 24 GB, macOS 27.0.1) shared with other jobs; one run at a time; a run starts only while
  the 1-minute load is ≤ 10. Tokens don't depend on load; times do somewhat.
- Claude Code's own login on the mini had expired, so Claude Code runs used an OAuth access token from the same
  subscription, passed as `CLAUDE_CODE_OAUTH_TOKEN` (read per run from `claude_token_file`, never logged).
  Ardia's daily run routes Claude Code through VibeProxy; ours talks to Anthropic directly (`claude_route`
  `anthropic` in each record). Codex used the mini's own ChatGPT login.
- `--setting-sources project` keeps user settings out, but Claude Code still lists the machine's user skills in its
  system prompt; that costs every Claude Code contender the same.
- Ardia's CLI is built from the plugins commit (label `0.0.0-bench.1`, source version 0.7.0), as their
  `freeze-cli` does, not the copy an Ardia install would download.
- Two repeats per cell (three for Ardia on booking): a median of two is their mean and moves run to run. Cells keep
  their real run counts.

## Rerun from scratch

On a Mac with Python 3.9+, Node, Bun 1.3.14, Claude Code and Codex logged in:

```sh
git clone https://github.com/ardia-browser/plugins && git -C plugins checkout d87fc6cf8aa7b3fa26ad1393a7ef6caa7e7fec28
cp perf/agentbench/{copper_side,playwright_side,xbench}.py plugins/plugins/cli/bench/harness/
export BENCH_HOME=~/agentbench/home
mkdir -p $BENCH_HOME/{app,copper,chrome} ~/agentbench/pw
ditto <Ardia.app> $BENCH_HOME/app/Ardia.app; ditto <Copper.app> $BENCH_HOME/copper/Copper.app
ditto "<Google Chrome.app>" "$BENCH_HOME/chrome/Google Chrome.app"
(cd ~/agentbench/pw && echo {} > package.json && npm i @playwright/mcp@latest)
(cd plugins/plugins/cli/ts && bun install --frozen-lockfile --ignore-scripts)
(cd plugins/plugins/cli/bench && python3 -I harness/bench.py freeze-cli)
# edit plan.json: ports, pause_file, claude_token_file (or drop the token step and let Claude Code use its login)
XB_ROOT=~/agentbench perf/agentbench/run.sh ~/agentbench/plan.json ~/agentbench/results/full --until <UTC time>
python3 perf/agentbench/export.py ~/agentbench/results/full --bench plugins/plugins/cli/bench --meta meta.json \
  --site site/assets/agentbench.json --runs perf/agentbench/results/<date>/runs.jsonl
python3 perf/agentbench/export.py --self-check
```

`xbench.py` resumes: rerunning it skips runs that already have a clean record.

## Files

- `copper_side.py`, `playwright_side.py`: the two sides (drop-ins for their `harness/`).
- `xbench.py`, `run.sh`: one-lane runner (round-robin order from their `runner.schedule`, retries as their
  scheduler, pause file, load gate, cutoff).
- `plan.json`, `smoke.json`: the plans run; `meta.json`: versions and machine for the export.
- `export.py`: `runs.jsonl` + `site/assets/agentbench.json` (assert self-check: `--self-check`).
