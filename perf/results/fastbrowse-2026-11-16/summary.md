# Agentbench — fastbrowse

Build: `/Users/collinrijock/hc/agentbench-app/fastbrowse/Copper.app` (202611151934, commit d8d3b34, binary 6845e6cc5a3dc17e; harness 5a60417) on Mac18,5. Load avg during runs: median 2.4, max 12.

Probe worlds (configured): main: Jev jev-latest, text model (build default), viewport [1280, 880, 1].
Resolved per arm (from the runs): fastbrowse: Jev jev-1.14.0 (fastbrowse), text model (none called), viewport 1280x657; shipped: Jev jev-1.14.0, text model llama, viewport 1280x800.

Pass = DONE + independent checker (uibench: the app's own verdict). Wall = jev_run's clock (first decision → end, initial navigation excluded, as upstream). Wall stats over passes; IQR = p25–p75 (the noise band). Phase ms = medians of per-run sums over all runs. Decisions count every decision asked (DONE/BLOCKED and stale ones too); tokens likewise on builds from hc2/jev (older builds summed only the steps taken). Stale % = stale decisions / decisions. Capped = settles that ran into their 400 ms cap (builds from hc2/jev say; — otherwise). Settle % = settle ms / wall. $/run and $/pass = what the router billed + Jev's own input tokens at an assumed $0.042 per million (AGENTBENCH_JEV_USD_PER_M; TypeSafe names no price).

## By group × arm

| Group | Arm | Pass | False DONE | Wall p50 | Wall p90 | IQR | Decisions p50 | Actions p50 | Stale % | observe | decide | text | act | settle | Settle % | Capped | Jev ms/dec | Tokens/run | Text calls/run | $/run | $/pass |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| ultrafast | shipped | 9/9 (100%) | 0/9 | 1,670 | 7,051 | 908–5,576 | 5.0 | 4.0 | 20.5% | 137 | 946 | 0.0 | 116 | 499 | 27% | 2% | 150 | 46,224 | 0.0 | 0.002 | 0.002 |
| ultrafast | fastbrowse | 9/9 (100%) | 0/9 | 11,596 | 29,189 | 7,897–20,181 | 33 | 8.0 | 0.0% | — | — | 2,461 | — | — | — | — | 207 | 608,459 | 2.1 | 0.026 | 0.026 |
| wikigame | shipped | 30/30 (100%) | 0/30 | 1,577 | 3,398 | 1,192–2,067 | 2.0 | 1.0 | 11.4% | 394 | 478 | 0.0 | 4.6 | 542 | 37% | 4% | 170 | 23,532 | 0.0 | 0.002 | 0.002 |
| wikigame | fastbrowse | 29/30 (97%) | 0/30 | 16,519 | 22,507 | 13,083–18,732 | 142 | 1.0 | 0.0% | — | — | 2,611 | — | — | — | — | 280 | 2,818,062 | 0.8 | 0.190 | 0.197 |
| uibench | shipped | 16/16 (100%) | 0/16 | 1,348 | 2,095 | 800–1,575 | 5.5 | 4.5 | 0.0% | 37 | 743 | 0.0 | 29 | 275 | 27% | 0% | 128 | 14,735 | 0.0 | 0.001 | 0.001 |
| uibench | fastbrowse | 8/16 (50%) | 0/16 | 2,722 | 4,536 | 2,412–4,068 | 18 | 4.5 | 0.0% | — | — | 0.0 | — | — | — | — | 129 | 37,579 | 0.3 | 0.002 | 0.004 |
| realweb | shipped | 15/15 (100%) | 0/15 | 2,758 | 5,887 | 2,082–3,520 | 4.0 | 2.0 | 15.4% | 194 | 827 | 0.0 | 132 | 516 | 23% | 8% | 163 | 43,519 | 0.2 | 0.002 | 0.002 |
| realweb | fastbrowse | 9/15 (60%) | 3/15 | 9,518 | 47,254 | 9,207–26,945 | 21 | 3.0 | 0.0% | — | — | 2,570 | — | — | — | — | 261 | 1,877,163 | 2.1 | 0.090 | 0.151 |
| fbpub | shipped | 10/27 (37%) | 0/27 | 1,006 | 2,432 | 953–2,302 | 2.5 | 1.0 | 32.7% | 145 | 641 | 379 | 99 | 265 | 14% | 4% | 179 | 33,726 | 0.6 | 0.014 | 0.039 |
| fbpub | fastbrowse | 27/27 (100%) | 0/27 | 4,890 | 11,343 | 3,946–5,700 | 16 | 3.0 | 0.0% | — | — | 736 | — | — | — | — | 214 | 205,603 | 1.0 | 0.012 | 0.012 |

## By task × arm (pass · wall p50 / p90 · decisions p50 over passes · values typed from the goal / by the text model, per run)

| Task | shipped | fastbrowse |
|---|---:|---:|
| hotel | 3/3 · 891 / 908 · 5.0 dec · 1.0 lit / 0.0 txt | 3/3 · 7,483 / 7,897 · 33 dec · 1.0 lit / 1.0 txt |
| godel | 3/3 · 1,670 / 1,917 · 4.0 dec · 1.0 lit / 0.0 txt | 3/3 · 11,596 / 12,157 · 31 dec · 0.0 lit / 2.0 txt |
| flights | 3/3 · 6,918 / 7,051 · 17 dec · 2.0 lit / 0.0 txt | 3/3 · 22,427 / 29,189 · 60 dec · 1.0 lit / 3.0 txt |
| Cheese → Milk | 3/3 · 1,023 / 1,283 · 3.0 dec · 0.0 lit / 0.0 txt | 3/3 · 13,886 / 17,403 · 49 dec · 0.0 lit / 1.0 txt |
| Moon → Earth | 3/3 · 1,923 / 2,067 · 3.0 dec · 0.0 lit / 0.0 txt | 3/3 · 16,519 / 18,732 · 237 dec · 0.0 lit / 0.0 txt |
| Coffee → Ethiopia | 3/3 · 1,314 / 1,501 · 2.0 dec · 0.0 lit / 0.0 txt | 3/3 · 12,207 / 14,158 · 113 dec · 0.0 lit / 0.0 txt |
| Chess → India | 3/3 · 3,398 / 3,640 · 3.0 dec · 0.0 lit / 0.0 txt | 2/3 · 20,328 / 20,813 · 231 dec · 0.0 lit / 1.0 txt |
| Pizza → Naples | 3/3 · 1,195 / 1,207 · 2.0 dec · 0.0 lit / 0.0 txt | 3/3 · 13,083 / 14,455 · 92 dec · 0.0 lit / 1.0 txt |
| William Shakespeare → Hamlet | 3/3 · 1,982 / 3,539 · 3.0 dec · 0.0 lit / 0.0 txt | 3/3 · 17,894 / 18,099 · 142 dec · 0.0 lit / 1.0 txt |
| Python (programming language) → Guido van Rossum | 3/3 · 930 / 1,350 · 2.0 dec · 0.0 lit / 0.0 txt | 3/3 · 8,883 / 8,992 · 65 dec · 0.0 lit / 0.0 txt |
| Lionel Messi → Buenos Aires | 3/3 · 1,748 / 2,180 · 2.0 dec · 0.0 lit / 0.0 txt | 3/3 · 20,014 / 22,507 · 217 dec · 0.0 lit / 1.0 txt |
| Mount Everest → Kathmandu | 3/3 · 1,186 / 1,214 · 2.0 dec · 0.0 lit / 0.0 txt | 3/3 · 15,700 / 16,940 · 127 dec · 0.0 lit / 1.0 txt |
| Ludwig van Beethoven → Austria | 3/3 · 2,258 / 3,697 · 5.0 dec · 0.0 lit / 0.0 txt | 3/3 · 22,963 / 27,173 · 144 dec · 0.0 lit / 1.0 txt |
| ui-login | 2/2 · 1,430 / 1,511 · 4.0 dec · 2.0 lit / 0.0 txt | 2/2 · 2,318 / 2,441 · 17 dec · 2.0 lit / 0.0 txt |
| ui-settings | 2/2 · 1,322 / 1,348 · 5.0 dec · 0.0 lit / 0.0 txt | 2/2 · 3,398 / 4,385 · 22 dec · 0.5 lit / 0.5 txt |
| ui-project | 2/2 · 1,566 / 1,575 · 7.0 dec · 1.0 lit / 0.0 txt | 2/2 · 4,302 / 4,536 · 28 dec · 1.0 lit / 0.0 txt |
| ui-checkout | 2/2 · 1,178 / 1,184 · 6.0 dec · 0.0 lit / 0.0 txt | 0/2 · — / — · — dec · 0.0 lit / 0.0 txt |
| ui-invoices | 2/2 · 632 / 634 · 3.0 dec · 0.0 lit / 0.0 txt | 2/2 · 2,722 / 2,778 · 15 dec · 0.0 lit / 1.0 txt |
| ui-files | 2/2 · 755 / 800 · 3.0 dec · 0.0 lit / 0.0 txt | 0/2 · — / — · — dec · 0.0 lit / 0.0 txt |
| ui-whack | 2/2 · 2,176 / 2,257 · 13 dec · 0.0 lit / 0.0 txt | 0/2 · — / — · — dec · 0.0 lit / 1.0 txt |
| ui-swatches | 2/2 · 1,906 / 1,972 · 9.0 dec · 0.0 lit / 0.0 txt | 0/2 · — / — · — dec · 0.0 lit / 0.0 txt |
| fb-wiki-open | 3/3 · 2,302 / 2,433 · 4.0 dec · 0.0 lit / 1.0 txt | 3/3 · 11,861 / 12,276 · 31 dec · 0.0 lit / 2.0 txt |
| fb-arxiv-open | 0/3 · — / — · — dec · 0.0 lit / 1.0 txt | 3/3 · 4,241 / 5,574 · 16 dec · 0.0 lit / 1.0 txt |
| fb-hn-comments | 3/3 · 864 / 993 · 3.0 dec · 0.0 lit / 0.0 txt | 3/3 · 5,081 / 5,700 · 11 dec · 0.0 lit / 1.0 txt |
| fb-hn-top | 3/3 · 965 / 1,018 · 1.0 dec · 0.0 lit / 0.0 txt | 3/3 · 4,236 / 4,890 · 7.0 dec · 0.0 lit / 2.0 txt |
| fb-github-license | 0/3 · — / — · — dec · 0.0 lit / 0.0 txt | 3/3 · 1,535 / 2,004 · 8.0 dec · 0.0 lit / 0.0 txt |
| fb-wiki-godel | 0/3 · — / — · — dec · 0.0 lit / 1.0 txt | 3/3 · 10,093 / 10,115 · 30 dec · 0.0 lit / 1.0 txt |
| fb-arxiv-title | 0/3 · — / — · — dec · 0.0 lit / 1.0 txt | 3/3 · 4,907 / 4,944 · 18 dec · 0.0 lit / 1.0 txt |
| fb-pypi-version | 1/3 · 2,432 / 2,432 · 5.0 dec · 0.0 lit / 1.0 txt | 3/3 · 4,953 / 4,979 · 17 dec · 0.0 lit / 1.0 txt |
| fb-oscars-2012 | 0/3 · — / — · — dec · 0.0 lit / 0.0 txt | 3/3 · 2,934 / 3,026 · 12 dec · 0.0 lit / 0.0 txt |
| gh-issues | 3/3 · 2,806 / 3,127 · 4.0 dec · 1.0 lit / 0.0 txt | 0/3 · — / — · — dec · 0.0 lit / 3.0 txt |
| wiki-lang | 3/3 · 2,161 / 2,365 · 3.0 dec · 0.0 lit / 0.0 txt | 0/3 · — / — · — dec · 0.0 lit / 1.0 txt |
| amazon-pdp | 3/3 · 5,887 / 5,927 · 5.0 dec · 1.0 lit / 0.0 txt | 3/3 · 43,928 / 47,254 · 75 dec · 0.0 lit / 2.0 txt |
| pydocs | 3/3 · 839 / 3,140 · 3.0 dec · 1.0 lit / 0.0 txt | 3/3 · 9,320 / 11,121 · 19 dec · 0.0 lit / 2.0 txt |
| mdn | 3/3 · 2,366 / 3,520 · 4.0 dec · 0.0 lit / 1.0 txt | 3/3 · 9,169 / 9,518 · 20 dec · 0.0 lit / 2.0 txt |

Best method per task (pass rate, then wall p50): hotel: **shipped** (3/3, 891 ms) · godel: **shipped** (3/3, 1,670 ms) · flights: **shipped** (3/3, 6,918 ms) · Cheese → Milk: **shipped** (3/3, 1,023 ms) · Moon → Earth: **shipped** (3/3, 1,923 ms) · Coffee → Ethiopia: **shipped** (3/3, 1,314 ms) · Chess → India: **shipped** (3/3, 3,398 ms) · Pizza → Naples: **shipped** (3/3, 1,195 ms) · William Shakespeare → Hamlet: **shipped** (3/3, 1,982 ms) · Python (programming language) → Guido van Rossum: **shipped** (3/3, 930 ms) · Lionel Messi → Buenos Aires: **shipped** (3/3, 1,748 ms) · Mount Everest → Kathmandu: **shipped** (3/3, 1,186 ms) · Ludwig van Beethoven → Austria: **shipped** (3/3, 2,258 ms) · ui-login: **shipped** (2/2, 1,430 ms) · ui-settings: **shipped** (2/2, 1,322 ms) · ui-project: **shipped** (2/2, 1,566 ms) · ui-checkout: **shipped** (2/2, 1,178 ms) · ui-invoices: **shipped** (2/2, 632 ms) · ui-files: **shipped** (2/2, 755 ms) · ui-whack: **shipped** (2/2, 2,176 ms) · ui-swatches: **shipped** (2/2, 1,906 ms) · fb-wiki-open: **shipped** (3/3, 2,302 ms) · fb-arxiv-open: **fastbrowse** (3/3, 4,241 ms) · fb-hn-comments: **shipped** (3/3, 864 ms) · fb-hn-top: **shipped** (3/3, 965 ms) · fb-github-license: **fastbrowse** (3/3, 1,535 ms) · fb-wiki-godel: **fastbrowse** (3/3, 10,093 ms) · fb-arxiv-title: **fastbrowse** (3/3, 4,907 ms) · fb-pypi-version: **fastbrowse** (3/3, 4,953 ms) · fb-oscars-2012: **fastbrowse** (3/3, 2,934 ms) · gh-issues: **shipped** (3/3, 2,806 ms) · wiki-lang: **shipped** (3/3, 2,161 ms) · amazon-pdp: **shipped** (3/3, 5,887 ms) · pydocs: **shipped** (3/3, 839 ms) · mdn: **shipped** (3/3, 2,366 ms).

## Google Flights: Google's own errors ("Oops, something went wrong" on the final page) and Reload clicks

| Arm | Runs | Pass | Provider error at the end | Runs that clicked Reload | Reload clicks p50 (those runs) | Results call statuses |
|---|---:|---:|---:|---:|---:|---|
| shipped | 3 | 3 | 0 | 2 | 1.0 | 200×3 |
| fastbrowse | 3 | 3 | 0 | 2 | 1.5 | — (builds before hc3/jev log none) |

## Sending, waiting and what the router billed (all groups)

WAIT = act + settle ms of each WAIT step (r3: 3 s capped in 8/16 Flights runs). Duplicate submits = a form sent again with nothing shown between (council R4). $ = the router's figure (x-litellm-response-cost) when it gives one, else list price; Jev's own tokens are not priced.

| Arm | Runs | WAIT steps | WAIT ms p50 / p90 | WAITs ≥ 2.9 s | Forms sent | Duplicate submits | Resends stopped | Router tokens in/out per run | $/run | $ total |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| shipped | 97 | 15 | 1,259 / 1,327 | 0 | 5 | 0 | 0 | 0.0 / 0.0 | 0.0029 | 0.286 |
| fastbrowse | 97 | 5 | 0.0 / 0.0 | 0 | 0 | 0 | 0 | 16,366 / 52 | 0.0112 | 1.082 |

## Failures (status · failed checks · note)

- fb-arxiv-open · shipped · r1: blocked · path · The page kept changing under the agent: Target changed or is covered. Observe again.
- fb-github-license · shipped · r1: unsure · - · Jev said DONE, 75% sure — unsure: Jev stayed under 80% after a second look — check the page
- fb-wiki-godel · shipped · r1: unsure · - · Jev said DONE, 61% sure — unsure: Jev stayed under 80% after a second look — check the page
- fb-arxiv-title · shipped · r1: blocked · answer · The page kept changing under the agent: Target changed or is covered. Observe again.
- fb-pypi-version · shipped · r1: blocked · answer · Jev said BLOCKED, 51% sure — the page asks for a human check (CAPTCHA): hand it to the user
- fb-oscars-2012 · shipped · r1: unsure · answer · Jev said DONE, 56% sure — unsure: Jev stayed under 80% after a second look — check the page
- fb-arxiv-open · shipped · r2: blocked · path · The page kept changing under the agent: Target changed or is covered. Observe again.
- fb-github-license · shipped · r2: unsure · - · Jev said DONE, 62% sure — unsure: Jev stayed under 80% after a second look — check the page
- fb-wiki-godel · shipped · r2: unsure · - · Jev said DONE, 55% sure — unsure: Jev stayed under 80% after a second look — check the page
- fb-arxiv-title · shipped · r2: blocked · answer · The page kept changing under the agent: Target changed or is covered. Observe again.
- fb-oscars-2012 · shipped · r2: unsure · - · Jev said DONE, 75% sure — unsure: Jev stayed under 80% after a second look — check the page
- gh-issues · fastbrowse · r1: budget · - · Keep the minimap size when the zoom level is slightly negative on high DPI screens
Show the minimap slider while scrolli
- wiki-lang · fastbrowse · r1: done · path · The German-language version of Wikipedia is open at https://de.wikipedia.org/wiki/Wikipedia:Hauptseite. [1](<https://de.
- gh-issues · fastbrowse · r2: budget · - · Issues

Keep the minimap size when the zoom level is slightly negative on high DPI screens
Show the minimap slider while
- wiki-lang · fastbrowse · r2: done · path · Die deutsche Wikipedia ist geöffnet: https://de.wikipedia.org/wiki/Wikipedia:Hauptseite [1](<https://de.wikipedia.org/wi
- gh-issues · fastbrowse · r3: budget · - · Keep the minimap size when the zoom level is slightly negative on high DPI screens
Show the minimap slider while scrolli
- wiki-lang · fastbrowse · r3: done · path · complete
- ui-checkout · fastbrowse · r1: stuck · app_ok · Partial evidence only. Remaining coverage is omitted; totals may be incomplete.

Express (1–2 days) — $18 [1](<http://12
- ui-files · fastbrowse · r1: needs_confirmation · app_ok · click 'button (3 of 18)' needs confirmation
- ui-whack · fastbrowse · r1: stuck · app_ok · 2 of 12 · 0 wrong [1](<http://127.0.0.1:4291/app?task=whack&sid=ui-whack-fastbrowse-cb03c98b#:~:text=Reaction%20drill>) 
- ui-swatches · fastbrowse · r1: stuck · app_ok · Partial evidence only. Remaining coverage is omitted; totals may be incomplete.

0 of 8 · 0 wrong [1](<http://127.0.0.1:
- fb-arxiv-open · shipped · r3: blocked · path · The page kept changing under the agent: Target changed or is covered. Observe again.
- fb-github-license · shipped · r3: unsure · - · Jev said DONE, 68% sure — unsure: Jev stayed under 80% after a second look — check the page
- fb-wiki-godel · shipped · r3: unsure · - · Jev said DONE, 69% sure — unsure: Jev stayed under 80% after a second look — check the page
- fb-arxiv-title · shipped · r3: blocked · answer · The page kept changing under the agent: Target changed or is covered. Observe again.
- fb-pypi-version · shipped · r3: blocked · answer · Jev said BLOCKED, 58% sure — the page asks for a human check (CAPTCHA): hand it to the user
- fb-oscars-2012 · shipped · r3: unsure · answer · Jev said DONE, 50% sure — unsure: Jev stayed under 80% after a second look — check the page
- ui-checkout · fastbrowse · r2: stuck · app_ok · Partial evidence only. Remaining coverage is omitted; totals may be incomplete.

Express (1–2 days) — $18 [1](<http://12
- ui-files · fastbrowse · r2: stuck · app_ok · Partial evidence only. Remaining coverage is omitted; totals may be incomplete.

budget-2026.xlsx [1](<http://127.0.0.1:
- ui-whack · fastbrowse · r2: stuck · app_ok · Partial evidence only. Remaining coverage is omitted; totals may be incomplete.

The Reaction drill shows 2 of 12 · 0 wr
- ui-swatches · fastbrowse · r2: stuck · app_ok · Partial evidence only. Remaining coverage is omitted; totals may be incomplete.

0 of 8 · 0 wrong [1](<http://127.0.0.1:
- wiki04 · fastbrowse · r3: stuck · reached · https://en.wikipedia.org/wiki/History_of_India [1](<https://en.wikipedia.org/wiki/Chess>)
