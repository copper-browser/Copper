# Copper Jev Turbo vs fastbrowse — 2026-11-16

**Copper (shipped Fast mode)**: merged fork build `~/hc/final/Copper.app` (d8d3b34 = d684712 minus a test-only change),
headless probe world on the Mac mini, WebKit, 1280×800, Jev `jev-latest` (answered as jev-1.14.0), text model llama.
**fastbrowse 0.10.0** (PyPI, the build its published campaign measured): Python SDK `run_task` on a headless Chrome for
Testing 157 (throwaway profile, normal Chrome UA, 1280×657 page), attached to a tab we open so the checker reads the
page it ends on. No OpenRouter key exists on the devbox or the mini, so it ran on its other supported routes: Jev =
direct TypeSafe with our key (`FASTBROWSE_DECISION_SOURCE=typesafe`, jev-1.14.0), LLM = our router as its `custom`
provider with `luna` (= gpt-6-luna, its default model) at reasoning `low` (its default for Luna). Everything else at
its defaults, except: max steps = the task's (its default is unlimited), and irreversible actions authorized on the
local fixtures only (hotel, uibench), as its own eval does for tasks that ask for a submit.

Same goals, same independent checkers, arms ABBA task by task, 194 runs (97 per arm). Pass = DONE (fastbrowse:
`complete`) **and** the checker; uibench = the app's verdict. fbpub = 9 of fastbrowse's own 53 published tasks
(read-only, no login); questions are checked on the answer (fastbrowse: its answer; Copper: `jev_extract` after
`jev_run`, its time added to the run). Wall over passes; steps = actions over passes. $/run = LLM tokens at list
price + Jev input tokens at $0.042/M (Jev's documented price, as fastbrowse books it); the last column is the
harness's usual assumed $1/M.

| Group | Arm | Pass | False DONE | Wall p50 s | Wall p90 s | Steps p50 | Jev calls p50 | LLM calls p50 | $/run | [$/run at Jev $1/M] |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| ultrafast (hotel, godel, flights ×3) | Copper | 9/9 (100%) | 0 | 1.7 | 7.1 | 4 | 5 | 0 | 0.0021 | 0.0511 |
| | fastbrowse | 9/9 (100%) | 0 | 11.6 | 29.2 | 8 | 33 | 2 | 0.0261 | 0.5196 |
| fbpub (9 of theirs ×3) | Copper | 10/27 (37%) | 0 | 1.0 | 2.4 | 1 | 4 | 1 | 0.0143 | 0.0998 |
| | fastbrowse | 27/27 (100%) | 0 | 4.9 | 11.3 | 3 | 16 | 1 | 0.0125 | 0.2579 |
| realweb (5 ×3) | Copper | 15/15 (100%) | 0 | 2.8 | 5.9 | 2 | 4 | 0 | 0.0020 | 0.0473 |
| | fastbrowse | 9/15 (60%) | 3 | 9.5 | 47.3 | 3 | 75 | 2 | 0.0904 | 1.5849 |
| uibench (8 ×2) | Copper | 16/16 (100%) | 0 | 1.3 | 2.1 | 4 | 6 | 0 | 0.0008 | 0.0195 |
| | fastbrowse | 8/16 (50%) | 0 | 2.7 | 4.5 | 4 | 14 | 0 | 0.0019 | 0.0413 |
| wikigame (10 ×3) | Copper | 30/30 (100%) | 0 | 1.6 | 3.4 | 1 | 2 | 0 | 0.0015 | 0.0368 |
| | fastbrowse | 29/30 (97%) | 0 | 16.5 | 22.5 | 1 | 142 | 1 | 0.1902 | 4.0584 |
| **all** | Copper | 80/97 (82%) | 0 | 1.7 | 3.5 | 2 | 4 | 0 | 0.0051 | 0.0545 |
| | fastbrowse | 82/97 (85%) | 3 | 10.0 | 22.4 | 3 | 30 | 1 | 0.0790 | 1.6271 |

**Where each wins.** Copper is faster on all 24 tasks both passed (median 7.2× faster, never less than 1.6×), ~15× cheaper
per run and never claimed a false DONE: it asks Jev ~4 small text questions a run, where fastbrowse asks ~30 (one Noul
per control on dense pages, a viewport screenshot on every step; a median 608k Jev tokens a run against 32k) and reads long
pages to quote them (Amazon 44 s, a GitHub search paged to page 9 until the step cap). fastbrowse wins on **questions**:
27/27 on its own tasks against Copper's 10/27, because it is built to answer with a cited quote, while Copper's DONE
gate stays "unsure" (<80%) when the goal is a question (github-license, wiki-godel, oscars: answer right 7 of 9 times,
status not DONE), Copper went stale on arXiv's search box 6/6 ("page kept changing"), and PyPI's bot check met WebKit
2/3 times (Chrome 0/3). fastbrowse's misses are form flows and repetition (uibench checkout/files/whack/swatches
`stuck` or `needs_confirmation` 8/8) and one false DONE pattern (wiki-lang: "German Wikipedia is open" on the German
main page, 3/3).

**Caveats.** Chrome (CDP, headless, 1280×657) vs Copper's WebKit (1280×800); no OpenRouter key, so fastbrowse's LLM
was luna via our router (its default model, not its default route; its benchmark used OpenRouter) and its Jev went
direct to TypeSafe; fastbrowse's clock starts at its first page (`page_ready`), Copper's at its first decision (both
exclude the first navigation). Copper's question answers add one `jev_extract` (~1.1 s, the world's router model,
sonnet: $ estimated from page size, which is most of Copper's fbpub $). Small samples (3 runs a task, 1–3 for
uibench/wikigame), one Mac shared with other benches (load median 2.4, max 12), live sites (Google Flights answered
normally today). Raw runs: `runs.jsonl`; harness view: `summary.md`; this table: `python3 table.py runs.jsonl`. Arm:
`perf/hillclimb/agentbench/fastbrowse_arm.py` (hc/harness).
