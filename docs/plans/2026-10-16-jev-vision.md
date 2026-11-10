# Jev vision and Fast mode: what Jev sees, and how fast it can go

**Status: shipped as the default, 2026-10-16.** Two rounds of work. The first added pictures to the Jev loop and measured them on the Wikipedia game: text alone was faster and no less reliable. The second asked a different question — *what is the fastest way to run Jev at all?* — profiled where a step's time goes, built six speed-ups and a picture-only loop, measured them on a click-heavy admin app (`perf/uibench.py`), and shipped the winner: **Fast mode** (the speed-ups) plus **Auto** vision (text, with the numbered picture only where text can't tell controls apart). Round two is first below; round one, unchanged, after it.

## Round two: the fastest way to run Jev

### Where a step's time went (the classic loop, sign-in form)

| Phase | Time | What it was |
|---|---:|---|
| Jev decision | 100–220 ms | one request, operation + target heads |
| Text model for TYPE_TEXT | 700–1,100 ms (Haiku), ~2.5 s (Sonnet) | a second call per typed field |
| Pointer glide before a click | 120–320 ms | cosmetic animation the click waited on |
| Typing | 150–250 ms | one key event per character |
| WAIT | ~250 ms a cycle | a fixed 100 ms sleep, then a whole new decision |
| Reading the page, settling | 5–200 ms | already lean |

So most of a classic step is not Jev. The speed-ups go after the rest:

| `strategy` word | change |
|---|---|
| `fast` | no glide before the click |
| `literal` | the values the goal quotes become Jev questions in the same request (*which field holds "482915"?*); TYPE_TEXT types the matched value, no text model |
| `burst` | every other value Jev matched surely (≥ 60%) is typed in the same breath: a sign-in form is one decision |
| `lean` | page text to 1,200 characters, five recent actions |
| `paste` | the value set in one go (native setter + input/change) |
| `watch` | WAIT ends when the DOM changes (MutationObserver, 1.5 s cap) |
| `turbo` | all six |

And three other ways to decide or see, to answer *is Jev + a text model really the fastest?*: `llm=haiku` (Haiku picks the move and writes the text in one call), `vision: pixels` (no element table: a picture, the operation, and a Box — the click goes where the box is), and the round-one picture modes on top of `turbo`.

### The bench: Northwind Console

`perf/uibench/app.html` is a made-up SaaS admin app served from the test Mac (`perf/uibench/server.py`), so timings are the agent's, not a site's. Eight tasks; the app's own server records what happened, so a pass is the app's verdict, not Jev's DONE.

| Task | What it takes | Fewest actions |
|---|---|---:|
| login | work email + access code, Sign in (a code field: Jev never types into password fields) | 3 |
| settings | open Settings, turn on a switch, pick *Deutsch* in a native select, Save | 4 |
| project | modal: name, a custom ARIA listbox, a radio, Create | 6 |
| checkout | three-step wizard: radio, Next, checkbox, Next, Place order | 5 |
| invoices | a table with eight identical *Approve* buttons: approve INV-1042, confirm | 2 |
| files | icon-only buttons with no name at all: delete one file, confirm | 2 |
| whack | "Click: Kilo" ×12 — raw actions per minute | 12 |
| swatches | "Click the GREEN square" ×8, unlabelled coloured squares | 8 |

### Results

240 runs (10 arms × 8 tasks × 3 rounds), then 168 (the hybrid against the best of them), a headless dev build on an M6 Mac, Haiku as the text model. Medians over passes; APM is actions per minute of wall time.

| Arm | What it is | Pass | Median time | APM | Wrong clicks | Decide ms / decision |
|---|---|---:|---:|---:|---:|---:|
| `classic` | the original loop (Haiku writes text) | 15/24 | 4,260 ms | 93 | 94 | 125 |
| `fast` † | no glide | 14/24 | 2,854 ms | 153 | 102 | 125 |
| `literal` † | + Jev picks quoted values | 17/24 | 1,833 ms | 164 | 99 | 131 |
| `burst` † | + whole form at once | 16/24 | 1,967 ms | 163 | 95 | 119 |
| `turbo` | all six speed-ups, text only | 17/24 | 1,852 ms | 174 | 99 | 114 |
| `turbo` on Jev 1.14 † | | 18/24 | 1,933 ms | 163 | 96 | 115 |
| `llm=haiku` † | Haiku decides instead of Jev | 14/24 | 13,199 ms | 26 | 60 | 1,247 |
| `pixels` † | picture only, click where the box is | 18/24 | 2,955 ms | 111 | 9 | 178 |
| `turbo` + `marks` | numbered picture every read | 24/24 | 2,441 ms | 123 | 0 | 174 |
| `turbo` + `box` | Box picks the element it overlaps most | 24/24 | 2,434 ms | 125 | 0 | 165 |
| **`turbo` + `auto`** | **the hybrid** | **24/24** | **1,673 ms** | **156** | **2** | **127** |
| `turbo` + `auto`, Jev 1.14 | | 24/24 | 1,938 ms | 142 | 2 | 132 |
| **shipped default** | Fast mode + Auto, nothing passed to `jev_run` | **24/24** | **1,905 ms** | **145** | **3** | **134** |
| shipped default, final rule ‡ | after the image-link fix below | 16/16 | 1,809 ms | 155 | 0 | 129 |

† From the first 240-run pass; the rest from the second, 168-run pass (same app, same build but for the hybrid). ‡ 16 runs (8 tasks × 2) after the rule change; the hybrid arm on the same rule: 16/16, 1,783 ms, 0 wrong clicks.

Per task, the shipped default against the original loop (median of passes): sign-in 1.36 s vs 4.32 s, settings 1.93 s vs 2.47 s, project 1.95 s vs 4.26 s, checkout 2.11 s vs 2.94 s, invoices 1.26 s (classic passed 1/3), files 1.13 s (classic 0/3), twelve drill clicks 4.15 s vs 6.24 s, eight swatches 3.25 s (classic 0/3).

What it says:

- **Most of the speed was never Jev's to give.** Jev decides in 110–130 ms; the classic loop spent more than that per click on a cursor animation and 0.7–1 s per typed field on a second model. Dropping the glide, letting Jev pick quoted values itself, and bursting forms makes the same loop 2–2.5× faster on every text task (sign-in 4.3 s → 1.4 s, the project modal 4.3 s → 1.9 s, twelve drill clicks 6.2 s → 3.7 s; ~175 APM).
- **Jev is the fast decider.** Haiku deciding (one call, text included) took 1.2 s a decision against Jev's 0.12 s, passed fewer tasks, and finished at ~26 APM.
- **Text alone can't see what has no name.** Every text-only arm failed the icon buttons and the swatches, and sometimes the identical *Approve* buttons — ~95 wrong clicks each.
- **Pictures fix that, at a price.** The numbered picture (`marks`) and Box-on-elements passed 24/24 with almost no wrong clicks, ~0.6 s a task slower than text.
- **Pure pixels is in between.** It aced the swatches with zero wrong clicks, but a box 20 px off a 32 px icon clicks its neighbour, and a click can't work a native `<select>` (settings 0/3).
- **The hybrid gets both.** Auto sends the numbered picture only on an ambiguous read (a nameless button or switch, three nameless links, three same-named controls, or a move that changed nothing). It passed 24/24 at text speed: 1.7 s median, ~156 APM, 2 wrong clicks.

### And on Wikipedia

The first cut of the hybrid took a picture on nearly every Wikipedia read: two links around images with no alt text are on almost every article, and "a control with no name" caught them. On the game it ran 2.32 s a pass against classic's 2.04 s. The rule now needs a nameless *button* (or switch, checkbox…) or three nameless links. Re-measured (20 runs each): **shipped default 17/20 at 2,027 ms, classic 18/20 at 1,967 ms** — level, the misses the same long-article BLOCKEDs as before; text-only `turbo` was 16/20 at 1,621 ms. Pages that are long text lean on the decision, not the hand, so Fast mode's gains are smaller there.

### Not done

- `pixels` can't work a native `<select>` and misses small icons; it is API-only and stays so. A crop-and-ask-again pass (TypeSafe's own advice for small targets) would be the next thing to try there.
- Long articles: the BLOCKED-after-a-scroll failures are the policy's, on every arm; a guard that refuses BLOCKED under ~60% while SCROLL_DOWN is offered is the cheap fix to try.
- `burst` skips the whole-page freshness check for the second field onward (the form changed on purpose); each field is still resolved, hit-tested and must be visible.

## Round one: pictures on the Wikipedia game


## What changed

TypeSafe's Jev takes images now (docs.typesafe.ai/images — a preview behind the `TypeSafe-Danger-Zone-Images: true` header, Jev 1.13 and 1.14; TypeSafe calls them "Dreamer-ready" and says their models do worse on pictures than on text). Jev 1.14 (2026-10-14) adds a **Box** question: four edges of where something is in a picture, plus a confidence. [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) does not use either: its `main` (last pushed 2026-09-30) and every `codex/*` branch send text only (`screenshots=` there only feeds the inspector and the demo video), and no open PR adds images. So Copper's port (`Fork/MCP/Ultrafast.swift`) got them first:

| `vision` | what rides beside the element table on every decision |
|---|---|
| `off` | nothing more — the original loop |
| `screenshot` | a JPEG of the viewport at 1× in the state (`page.screenshot`), referenced from the rules |
| `marks` | the same picture with every element's index drawn in a tag at its top-left corner, the table's numbering (set-of-marks) |
| `box` | the picture, and one Box question in place of the per-operation target heads: *the one control in `page.screenshot` to act on*. The box's centre is mapped onto the observed element under it (the smallest when they nest, else the nearest within 24 px); when it lands on none, the text head is asked as a second request and the miss is counted. Jev 1.14 only |

The picture is taken right after the read (trail layer hidden), re-rendered into a bitmap of known size so the marks and the box maths share one scale, kept within TypeSafe's 280–1568 px sides, and sent base64 under a fresh UUID reference. `Jev.ask` grew `assets` and a per-call `model`; a Box answer is parsed into `Answer.boxes`. Per-step `input_tokens`, `jev_ms`, `shot_ms`, `box_hit` and `requests` go into the trace and into `jev_run`'s `json: true` object. `SEARCH_JEV_SHOTS=<folder>` keeps every picture sent. Model output never becomes a coordinate: a box only ever selects an element this code observed, and the same freshness and occlusion checks run before the click.

## The Wikipedia game

`perf/wikigame.py`: ten games (start article → target article; seven one link away, three two away), each a `jev_run` with the goal *reach the article titled X by clicking links in the article only, never the search box*, in a tab of the harness's own, verified by the final URL. Six arms, alternating within each game, two rounds: **120 runs**, 20 per arm. Headless dev build of this branch on an M6 Mac (1280×800 viewport, Wikipedia live), 2026-10-16 14:17–14:31 EDT. A pass is Jev's DONE on the target with no TYPE_TEXT. `wall` is `jev_run`'s clock (first decision to the end, page loads included; the initial navigation outside it); *Jev ms* and tokens are per decision, summed per run. Raw runs: `perf/results/wikigame.jsonl`.

| Arm | Model | Pass | Median wall (passes) | Median actions | Jev ms / decision (p50 · p90) | Tokens / decision | Tokens / run | Box | Stale |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `off` | jev-1.13.0 | 17/20 | **1,978 ms** | 2 | **193 · 298** | 5,659 | 17,560 | — | 1 |
| `off` | jev-1.14.0 | **18/20** | 2,072 ms | 2 | **170 · 216** | 5,502 | 18,203 | — | 2 |
| `screenshot` | jev-1.13.0 | 17/20 | 2,609 ms | 2 | 352 · 520 | 7,796 | 23,155 | — | 0 |
| `marks` | jev-1.13.0 | **18/20** | 2,825 ms | 2 | 400 · 730 | 7,757 | 23,270 | — | 0 |
| `marks` | jev-1.14.0 | 16/20 | 3,068 ms | 2 | 340 · 477 | 7,832 | 23,500 | — | 0 |
| `box` | jev-1.14.0 | 14/20 | 3,288 ms | 2 | 321 · 454 | 5,134 | 15,957 | 22/22 hit | 7 |

Per game, wall ms of each run (`×` a fail): see `perf/results/wikigame.md`.

### What it says

- **Text is fastest, and no less reliable.** A picture adds about 2,200 input tokens (+40%) and 160–210 ms of Jev latency per decision, plus 10–20 ms to take it; passes land 30–55% later on the clock. Pass rates are 16–18 of 20 for every arm but box, which is within the noise of two rounds: the failures are the same games on every arm.
- **Jev 1.14 on text is the best arm here** (18/20, 170 ms p50, 216 ms p90 — the tightest latency of all). The model, not the modality, is the upgrade worth taking.
- **Box lands, then disappoints.** Every box Jev returned landed on an offered element (22/22) and the second request was never needed, so the mapping works. But the box arm passed 14/20: it said BLOCKED with 31–46% confidence more often than any other arm (6 of its failures), it picked citation brackets (`[ 12 ]`) twice — the smallest element under a box drawn over a sentence — and it was the only arm with stale retries (7: a click chosen by position landing after the page had moved). It is also the slowest on the clock. The token count is lower only because the target heads are gone.
- **Why anything fails.** 19 of the 23 failures across all arms are Jev choosing BLOCKED at 31–58% after one to three scrolls, on three games (Messi → Buenos Aires, Beethoven → Austria, Coffee → Ethiopia) where the link is below the fold or two hops away. That is the policy's jaggedness on long articles, shared by every arm; a scroll-then-BLOCKED guard (refuse BLOCKED under 60% while SCROLL_DOWN is still offered) would likely lift every arm equally. Nothing cheated: no arm typed into the search box.
- **Pictures did help once.** Both runs of Moon → Earth and Pizza → Naples were one click on every arm; on Shakespeare → Hamlet the marks arm was slower (7.3 s and 7.4 s on one run each) because Jev clicked a nearby link first. There was no game where a picture arm was reliably faster than text.

So: `off` stays the default, and the picture modes are there for pages the table cannot describe (icon-only buttons, canvases, layout that carries meaning) and for when TypeSafe's picture accuracy catches up. The harness is there to re-run when it does.

## Not done

- The Settings picker shows the four modes but says nothing about cost; a per-run note in the trace does (`Jev: 1,102 ms, 20,822 tokens · pictures: marks, 32 ms`).
- Box mode's nearest-element rule prefers the smallest containing element; a word-sized citation link inside a sentence wins over the sentence's link. Preferring the candidate whose label the goal mentions, or excluding `sup` reference links from box candidates, would fix the two bad clicks.
- No multipart upload: the picture goes base64 in JSON, about a third larger on the wire. Fine at 250 KB.
- `jev_step` reads `vision`/`model` only when a session starts.
