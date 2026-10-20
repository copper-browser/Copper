# Agents — driving Copper from Claude Code, phi, Cursor, Claude Desktop

Copper is an MCP server. Turn it on and an agent gets the window you have
open — your tabs, your sign-ins, your extensions — through the same tool
names Playwright MCP uses, so a skill written for that works here unchanged.

## Turn it on

Settings › Agents › **Let agents drive this window**. That starts a
Streamable-HTTP MCP endpoint at `http://127.0.0.1:4123/mcp`, loopback only,
guarded by a bearer token that lives in `agent.json` beside your session
(0600). Every request must carry it; anything with a foreign `Origin` header
is refused, so a page in another browser can't reach in.

## Connect a client

**Claude Code / phi / Cursor (HTTP)** — Settings › Agents › *Copy config*,
paste into `~/.claude.json` (or `~/.pi/agent/mcp.json`, or the editor's MCP
settings):

```json
{
  "mcpServers": {
    "copper": {
      "type": "http",
      "url": "http://127.0.0.1:4123/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

Or the one-liner: `claude mcp add --transport http copper http://127.0.0.1:4123/mcp --header "Authorization: Bearer <token>"`.

**Claude Desktop and other stdio-only clients** — the second *Copy config*.
It runs the app binary with `--mcp-stdio`, which is a pipe to the running
window (and launches Copper if it isn't up):

```json
{
  "mcpServers": {
    "copper": {
      "type": "stdio",
      "command": "/Applications/Copper.app/Contents/MacOS/Copper",
      "args": ["--mcp-stdio"]
    }
  }
}
```

**Rotate** the token from Settings whenever you like; every client config
goes stale at once, on purpose.

## Tools

Playwright MCP's names and argument shapes. `ref`s come from
`browser_snapshot` and are remembered on the element until the page changes.

**Which tab.** Every page tool (and the four `jev_*` tools) works on the
caller's own tab — the one it opened with `browser_tabs new` / `jev_run
newTab`, or chose with `browser_tabs select` — else the tab on the user's
screen. Any call can name another with `tab` (an id from `browser_tabs list`,
or an index). The caller is the agent session (`Drive.Who`, Hands.swift), so
two threads keep two tabs. A caller's tab is worked on where it is: off
screen, its web view hangs in a borderless window outside every display
(`Fork/MCP/Backstage.swift`) that WebKit counts as visible and focused, so
pages paint, rAF runs, screenshots are real and clicks go in as trusted
events, without the user's window, keyboard or app focus moving. Choosing the
tab shows it the ordinary way; five minutes after the agent's last call it is
an ordinary background tab again (and may sleep). Calls never bring a window
forward; the pane opens itself only for work on the page on screen.

| tool | does |
|---|---|
| `browser_tabs` | `list` / `new {url}` / `close {index\|tab}` / `select {index\|tab}` (+ `focus`) — the real row, groups and pins shown, each tab with its id; `new` opens a background tab of the caller's own and `select` makes one the caller's, neither switching the user's tab unless `focus: true` |
| `browser_navigate`, `browser_navigate_back`, `browser_navigate_forward` | your tab; waits for the load to settle |
| `browser_snapshot` | accessibility tree with `[ref=e12]` on interactive nodes; `interactive: true` for a smaller one, `selector` for a subtree |
| `browser_click` | `ref` or `selector`; `doubleClick`, `button`, `modifiers` — a real `NSEvent` at the element's centre |
| `browser_type` | `text`, `submit`, `slowly` (real key events) — sets the value through the native setter so React/Vue notice |
| `browser_fill_form` | `[{ref, type, value}]` for textbox / checkbox / radio / combobox / slider |
| `browser_press_key` | `Enter`, `Escape`, `ArrowDown`, `Meta+a`, `a` … as real key events (⌘ shortcuts go to the window first) |
| `browser_hover`, `browser_drag`, `browser_select_option`, `browser_scroll` | as named |
| `browser_take_screenshot` | PNG/JPEG at 1×, so image pixels are CSS pixels; `ref` for one element, `fullPage`, `filename` |
| `browser_evaluate` | `function: "() => …"` or `(element) => …` with `ref` |
| `browser_wait_for` | `text`, `textGone`, `time` |
| `browser_get_text`, `browser_find`, `browser_console_messages` | reading without a snapshot; refs for text you name; console since load |
| `browser_resize`, `browser_close` | the window; the tab |
| `browser_groups` | Copper's tab groups: `list`, `assign {group}`, `remove` |
| `browser_perf_probe` | Samples the current tab for rAF loops, DOM churn, animations, filters, canvases, timers, long tasks, and slow resources (`seconds`, `top`, `format`) |
| `browser_crashes` | Copper's own crash history on this Mac as JSON, newest first; `index: N` for one in full with the breadcrumbs before it ([crashes.md](crashes.md)) |
| `cloud_history_delete` | Deletes the user's history on Copper Cloud (`since`, `until`, `host[]`, `page[]`, `device`, or `all: true`); history on the Mac stays. Loopback clients only — not listed through an agent link, refused to the agent pane. Sites and pages are matched on the Mac, never by the server (docs/cloud.md) |

### Saved sign-in (no-secret contract)

`browser_sign_in` fills a saved account on the current tab in-process. Its
arguments are `account` (optional username), `what` (`password` by default or
`otp`), and `submit` (true by default). With more than one shared match, omit
`account` to get a username-only `candidates` list, or name the username. The
result reports only `filled`, `account`, `host`, `source` (for password fills),
`what` (for OTP), and `submitted`; the password, one-time code, and Bitwarden
session key never appear in the MCP result, CLI output, or Jev trace.
`copper signin [--account USER] [--otp] [--no-submit] [--json]` is the CLI
equivalent (`--json` may be placed with the command).

Jev's fast path exposes a `SIGN_IN` control labelled “Sign in with the saved
account for this site” only when the current tab has a password field and at
least one permitted candidate. It routes through the same password fill and
submit path. OTP fills use `browser_sign_in` with `what: "otp"` (or `copper
signin --otp`); Jev `SIGN_IN` does not guess an OTP. Unshared credentials,
missing fields, locked Bitwarden, and private (`shy`) tabs return an error;
there is no agent prompt or audit record in this flattened lane. When a
credential exists but is not shared, the error points to Settings › Passwords ›
Agent access. The operation is not a page sandbox: with `--no-submit`, the
password intentionally remains in the page, so do not use ordinary
page-reading/evaluate tools on that tab.

Sharing is controlled by Settings › Passwords › **Agent access**. The user can
turn on the share-everything switch or enable individual per-item toggles. A
Bitwarden item in the `Agents` folder is shared automatically; a custom field
`copper-agent: deny` always means never shared, even when the broad switch is
on. The policy is local to Copper and never editable through MCP or the CLI.

### Saved cards, identities, and custom fields

`browser_autofill` fills a shared Bitwarden `card`, `identity`, or `field` in the
current tab. Use `copper autofill card|identity|field [--name NAME] [--submit]`
for the CLI equivalent. It returns only the fill count, item name, and submitted
state: card numbers, security codes, addresses, and custom-field values never
cross the MCP/CLI boundary. The tool refuses private tabs, locked vaults,
missing form groups, and items not enabled under Settings › Passwords › Agent
access. When more than one shared item matches, it returns candidate names so a
caller can choose one.

Jev exposes `AUTOFILL_CARD` when the page has card fields and a shared card, and
`AUTOFILL_IDENTITY` for identity fields and a shared identity. Jev chooses the
first permitted item and fills in-process; neither control returns vault values.

### Why is this tab hot?
`browser_perf_probe` samples the tab in one call instead of requiring a chain of evaluations: it groups frame loops and DOM mutations, inspects running animations and filters, and records canvases, timers, long tasks, and resources.
Its findings are deliberately WebKit-specific. The three traps it calls out are a filtered SVG under an animated transform, off-screen `requestAnimationFrame` loops, and animations of properties other than `transform`/`opacity`.

Input goes in as real events when the tab is on screen (trusted `isTrusted`
clicks, key repeat, focus, default actions); when it is not, the DOM gets an
event of the same shape. Screenshots and snapshot coordinates are in the
tab's CSS pixels; the server converts to points for the click.

Each tool call is announced in the line at the bottom of the window (turn
that off in Settings › Agents). `./bench agent` reports status; `./bench
agent on|off|rotate`.

### Canvases

`canvas_list`, `canvas_open`, `canvas_read`, `canvas_apply`, `canvas_select`, `canvas_focus`,
`canvas_create`, `canvas_invite`, `canvas_share_link`, `canvas_join`, `canvas_screenshot` read and
draw on the user's whiteboards (`copper://canvas/<id>` tabs) — the same tools for every client and
for ⌘E, each write attributed to the agent that made it. `canvas_share_link` makes (or reuses) a
canvas's invite link; `canvas_join` opens one, the way clicking it would. Read before you write;
a big canvas reads a page at a time — `overview: true` first, then a `frame` or `region`, or follow
`next` as `cursor` ([Reading a big canvas](canvas.md#reading-a-big-canvas)). See [canvas.md](canvas.md).

## Code mode — one script instead of N calls

Every tool call is a model round trip. Building a board is a dozen `canvas_apply`
calls of 40 ops; reading five tabs and putting each one's title on a board is
twenty calls, with nothing to decide between them. `copper_run` takes one
JavaScript script that calls the same tools through a `copper` object and
answers once. (Cloudflare's "Code Mode", done locally in Copper.)

```js
// copper_run {script: "…", timeout: 60, maxCalls: 100, reason: "put the open docs on the board"}
const tabs = (await copper.browser.tabs({action: "list"})).text;
const ids = [...tabs.matchAll(/\{tab ([0-9a-f]+)\}/g)].map((m) => m[1]).slice(0, 5);
const rows = [];
for (const tab of ids) {
  const page = await copper.browser.evaluate({tab, function: "() => [document.title, document.querySelector('h1')?.innerText]"});
  rows.push(JSON.parse(page.text));
}
const ops = rows.map(([title, h1], i) => ({op: "add", shape: {type: "sticky", x: 40 + (i % 3) * 260, y: 40 + Math.floor(i / 3) * 180, w: 240, h: 150, text: `**${title}**\n${h1 ?? ""}`}}));
const applied = await copper.canvas.apply({ops, reason: "one note per open page"});
console.log(applied.summary);
return {pages: rows, applied: applied.json.applied};
```

**The `copper` object.** `copper.browser.navigateBack` is the tool
`browser_navigate_back`: the first word is the namespace, the rest camel-cased —
`copper.browser.*`, `copper.canvas.*`, `copper.jev.*` (Jev mode on),
`copper.cloud.historyDelete`, `copper.voice.*`. Each method takes the tool's
arguments object (the same `reason` and `tab` included) and resolves to
`{text, json?, images?, summary?}`: `text` is the tool's text answer, `json` is it
parsed when the tool answered JSON (`canvas_read`, `canvas_apply`, `browser_sign_in`
do), `images` the screenshots, `summary` the one-line summary a tool leaves. A call
the tool refuses or fails rejects with an `Error` whose `tool` names it — catch it
to go on, or let it end the run. Also `copper.call(name, args)` for a name built at
run time, `copper.tools` (the names), `copper.sleep(ms)` (≤ 30 s) and `console.log`.

**What the script is.** The body of an async function: `await` and `return` work
at the top level, and the returned value (JSON-serialisable) is the answer's
`value`. Plain JavaScript, not TypeScript — Copper strips nothing and compiles
nothing. A script's `tab` argument, own tab (`browser_tabs new` / `select` inside
the script binds it for the calls after, and for calls after the run) and `reason`
work exactly as they do call by call.

**What it runs in.** A fresh JavaScriptCore context per run — the engine already
in the OS, nothing added — with nothing in it but the language and `copper`: no
DOM, no `fetch` or `XMLHttpRequest`, no timers, no `require`, no `import`, no
files. Every `copper.*` call goes through the same dispatch as a direct
`tools/call` (`MCP.invoke`): the same argument validation by the same handler, the
same agent-access checks (shared sign-ins, Bitwarden policy, `cloud_history_delete`'s
loopback rule), the same announcement in the line at the bottom, the same row with
its `reason` on the driver's card, and the same **Stop**: the user's Stop refuses
the script's next call with *Stopped by the user in Copper…* and the run ends with
that as its error. A script can do nothing a run of direct calls could not; it saves
the round trips between them. `copper_run` is a loopback tool (the same gate as
`cloud_history_delete`): never offered through an agent link nor to the ⌘E pane's
agent, and a script cannot call `copper_run`.

**Limits.** `timeout` seconds for the whole run, tool calls included (default 60,
at most 300) — backed by JavaScriptCore's execution-time watchdog, so a script that
spins ends at the deadline too; the script's own code runs on a queue of its own, so
a loop costs a core, never the window. `maxCalls` (default 100, at most 500): calls
past it reject, the answer says `callCapReached`. `console` keeps 200 lines / 64 KB
(`logsDropped` counts the rest); the returned value is cut at 256 KB
(`valueTruncated`).

**The answer.** JSON text: `{ok, value, logs, calls, callLog: [{tool, ms, error?}],
ms}`. A thrown error — in the script, or a tool's rejection it did not catch — is a
tool error (`isError: true`) whose text is `{ok: false, error: {message, name, line,
column, tool?, stack?}, logs, calls, callLog, ms}`; `line` and `column` are the
script's own. The driver's card shows *Running a script · N lines*, then one row
per call under it.

**Types.** `copper_types` (and the MCP resource `copper://types/copper.d.ts`) is
`copper.d.ts`, generated from this Copper's tool schemas — each method typed with
its tool's arguments and description, so it says exactly what this Copper offers
(Jev mode on or off, voice tools or not). Type-checking is the agent's, optional,
before sending: save the declarations beside the script, wrap the script as a
function body, and run a checker that needs no install step on the Mac, e.g.

```sh
copper call copper_types > copper.d.ts
printf 'async function run() {\n%s\n}\n' "$(cat script.js)" > check.ts
npx -y @typescript/native-preview --noEmit --strict --target es2022 --lib es2022 copper.d.ts check.ts   # tsgo
# or: tsrs --noEmit copper.d.ts check.ts
```

Copper bundles no compiler: the app stays small, and a script that fails the check
still runs as plain JavaScript if you send it.

**Shell.** `copper script FILE [--timeout S] [--max-calls N] [--reason TEXT]` (or
`-` for stdin) runs a file as one `copper_run`; `copper call copper_run '{"script":
"…"}'` is the same. Code: `Fork/MCP/CodeMode.swift` (the runner),
`Fork/MCP/CodeModeTypes.swift` (the declarations), `MCP.invoke` (the shared
dispatch).

## Jev mode — hand over a goal

Settings › Agents › **Let the agent hand Copper a goal**. Three more tools
appear, and the server's instructions tell the agent to reach for them
first:

| tool | does |
|---|---|
| `jev_run` | `goal` (+ `url`, `newTab`, `focus`, `tab`, `maxSteps`, `elements`, `vision`, `model`, `json`) — runs [browser-use's jev-ultrafast](https://github.com/browser-use/jev-ultrafast) loop in your tab (`newTab`: a new background one) until DONE, BLOCKED or the budget (60 actions, 120 decisions, 3 minutes); answers with the trace, the page, and the indexed element table |
| `jev_step` | one decision and its action; same `goal` continues the session |
| `jev_observe` | what Jev sees: `[3] combobox  Where to? · London` for every visible control, plus the visible text |
| `jev_extract` | `instruction` (+ `schema`, `full`) — one JSON object drawn from the page by the text model: values, not a tree |

The loop is theirs, in Swift (`Fork/MCP/Ultrafast.swift`): one script reads
the visible controls into an indexed table with a semantic marker; **one**
TypeSafe System One request asks for the operation and, speculatively, a
target for every operation that has candidates — only the head the chosen
operation names is consumed; freshness (the marker, or for a click the form
state plus the target's own guard) and occlusion are checked again before the
input goes in as real events. `TYPE_TEXT` asks the model (Settings › Intelligence) for the value and types only what came back as `{"text": …}`.
Model output never becomes a selector, a coordinate or JavaScript.

Needs a TypeSafe key (shared with Intelligence — the Agents page has the
field too) and, for anything that types or extracts, the model (Settings ›
Intelligence). The picker names the model used for typing and
`jev_extract`; small and fast is the point: Sonnet spends ~2.5 s writing a
search string, a mercury-class model well under a second. DONE is the model's
claim; the tool says so and the agent is told to check.

**Copy prompt** on the Agents page gives you one paragraph to paste into the
chat with your agent — endpoint, token, how to add the server, what it can
do. There is one for the Playwright-shaped tools and one for Jev mode.
`./bench agent jev on|off`.

### What Jev sees

By default (*Auto*) Jev gets the element table and the visible text, and a
picture only when the table can't tell the controls apart: a control with no
name of its own (an icon button, a colour swatch), three or more with the
same role and name (a table of *Approve* buttons), or a page the last move
did not change. Then the picture is the numbered one (`marks`). TypeSafe's Jev also takes
pictures (a preview behind their `TypeSafe-Danger-Zone-Images` header;
docs.typesafe.ai/images), and Jev 1.14 has a Box question that answers with
where something is in a picture. Settings › Agents › Jev mode › *What Jev
sees* sets this Mac's default (`jevVision` in `intelligence.json`; `copper
intelligence set --jev-vision …`), and a run can say otherwise with
`jev_run` / `jev_step`'s `vision` and `model`:

| `vision` | what rides beside the table |
|---|---|
| `auto` | the default: `off`, or `marks` when the read is ambiguous (above) |
| `off` | nothing more |
| `screenshot` | a JPEG of the viewport at 1× in the state (`page.screenshot`), so the choice heads can see layout and icons |
| `marks` | the same picture with every element's index drawn in a tag at the element's top-left corner, the same numbering as the table (set-of-marks) |
| `box` | the picture, and one Box question in place of the target heads: where is the control to act on. The box's centre is mapped onto the observed element under it (the smallest, when they nest; else the nearest within 24 px); when it lands on none, the text head is asked as a second request and the miss is counted. Needs `jev-1.14.0` (`model` defaults to it for a box) |

A picture costs a few thousand input tokens and 50–200 ms more per
decision, and TypeSafe says their models are less accurate on pictures than
on text — which is why `auto` sends one only where text alone fails. The trace's cost line says what Jev took (ms, tokens), what the
pictures took and how the boxes did; `json: true` on `jev_run` returns the
run as one object (`status`, `elapsed_ms`, `totals`, one entry per step with
`jev_ms`, `input_tokens`, `box_hit`, and the page it ended on) for a
harness. `SEARCH_JEV_SHOTS=<folder>` keeps every picture sent, to look at.
Model output never becomes a coordinate: a box is only ever mapped onto an
element this code observed, and the freshness and occlusion checks run
before the click as they always did. `perf/wikigame.py` plays ten Wikipedia
games one way of seeing at a time and tables the arms (perf/README.md).

### Faster runs (`strategy`)

Settings › Agents › Jev mode › *Fast mode* (on by default; `jevFast` in
`intelligence.json`, `copper intelligence set --jev-fast on|off`) runs
`turbo` with the pointer glide kept for a tab that is on screen; off runs
`classic`, the original loop. `jev_run` / `jev_step` take `strategy`,
comma-separated speed-ups that can be measured one at a time against the
classic loop (`perf/uibench.py`):

| word | what changes |
|---|---|
| `fast` | no cosmetic pointer glide before a click (it cost 120–320 ms a click); the trail still draws |
| `literal` | each value the goal quotes (`"maya@northwind.test"`) becomes one Jev question in the same request — *which field holds this?* — and a TYPE_TEXT types the value Jev matched to that field. No text-model call; a field no quoted value fits still asks the text model |
| `burst` | `literal`, and every other value Jev matched surely (≥ 60%) is typed in the same breath, before the next read: a sign-in form is one decision, not three |
| `lean` | the state Jev reads is trimmed (page text to 1,200 characters, five recent actions) |
| `paste` | a field's value is set in one go (native setter, input and change events) instead of a key event per character |
| `watch` | WAIT ends when the page changes (a MutationObserver, capped at 1.5 s) instead of after 100 ms |
| `turbo` | all of the above |
| `watched` | like `fast`, but the glide stays when the tab is on the user's screen (Fast mode is `turbo` + `watched`) |
| `classic` | none of them: the original loop |
| `llm`, `llm=<model>` | a small LLM decides instead of Jev: one chat call returns the operation, the target and any text (the comparison for *is Jev the fastest decider?*) |

`vision: pixels` is the picture-only loop: no element table, the operation
question and one Box (*where to act*), and the click goes to the box's centre
as a real click at that point. It is the one mode where model output becomes a
coordinate, so Settings does not offer it, and it refuses to type into a
password field (the table leaves those out on purpose; SIGN_IN fills saved
accounts). In `box` mode the box picks the observed element it overlaps most
(intersection over union), then the one under its centre.

Every step in the `json: true` trace says where its time went — `observe_ms`,
`decide_ms` (Jev's `jev_ms` inside it), `text_ms`, `act_ms`, `settle_ms` — and
`burst: true` marks a field typed without a decision of its own.

## Who is driving — the pill, the ring, the timeline

Whenever a hand that is not yours is on the page, Copper says so, whoever it
belongs to: a Jev run, an agent on the loopback server calling `browser_*`
tools one at a time (phi, Claude Code, the `copper` CLI — named by the
`clientInfo` it gave at `initialize`), a bot through an agent link (`@dev-s ·
agents`), or the agent in Copper's own pane.

- **The pill** in the page's top-right corner — *phi is driving*, *Jev is
  driving*, *@dev-s · agents is driving* — and a warm 1.5 pt ring just inside
  the page's edge. The dot is solid while a call is in flight and breathes
  while the driver thinks between calls. Both go when the driver lets go.
- **The driver's card** in the agent pane (⌥⌘J, ⌘K › *Driver Timeline*, or
  click the pill — the pane opens by itself when a run begins). There is one
  pane beside the page, the agent's (⌘E), and a run lands in its
  conversation as a live card: who (*phi · monkey board · Personal*, *Jev ·
  for Claude Code*), the goal, the latest thing the driver said about what it
  is doing, its last few steps in words — *Read 45 shapes on Personal*,
  *Clicking Fit to screen*, a failed call in red with its error — with the
  time each took, a ticking clock, and Stop. *Details* opens the whole
  timeline: every cycle numbered, each phase with its time, the operation
  chip and what it came to (*CLICK → page changed*), how sure Jev was and the
  moves it was offered. A finished run's card stays where it happened, with
  how it ended (*Done — Found 3 under $300*, *Stopped by you*). A Jev run the
  pane's own agent starts with `jev_run` is no card: its moves nest under that
  step in the agent's activity row (below).
- **On the page**, the same trail Jev draws: the element about to be clicked
  or typed into is outlined and named, a pointer glides to it, a numbered
  dot marks the press, the typed value rises beside the field (masked when
  the field sounds like a secret), a chevron marks a scroll.
- **Stop** (the pill's square, or the card's) takes the browser back. A Jev
  run ends before its next action. An agent's next tool calls are refused for
  30 s with *Stopped by the user in Copper: they took the browser back. Do not
  retry; tell them what you were doing and wait…* — the refused attempts show
  in the card — and *Let it back in* on the card's footer ends the refusal
  early.

**`reason`.** Every `browser_*` tool takes an optional `reason` string: one
short sentence on what the agent is doing and why. It is never acted on; it
is shown to the user on the driver's card, over the calls that follow. The server's
`instructions` ask agents to pass it on each call, together with `element`
(Playwright's own human-readable element description) for anything they click
or type into — those two are what the rows are made of. The agent in the
window needs no `reason`: what the model wrote before reaching for a tool is
shown instead.

An agent's run stays live for 30 s after its last call — agents think between
calls — and ends on its own after that (*Let go · 7 calls*); the same driver
back within three minutes continues the same card. `./bench drive
[status|stop|resume|clear|pane on|off]` reads and drives all of this from a
script (`pane on|off` opens or closes the agent pane); `./bench render drive
PATH` (or `agent`, `agent-dark`) draws the pane to a PNG on its own, and
`./bench agent seed driver` fills it with a finished Jev card and a live
agent's, for pictures.
Design and verification record: [plans/2026-09-30-driver-timeline.md](plans/2026-09-30-driver-timeline.md).

## The agent in the window — ⌘E

The other direction: Copper as an MCP **client**. ⌘E opens a pane beside
the page with a chat; ⌘⇧E (or ⌘K › *Ask About This Page*) opens it with the
page in front of the question. The pane's header menu picks Haiku, Sonnet or
Opus, through whichever lane Settings › Intelligence uses. Nothing is
configured out of the box.

What it has in hand:

- **Copper's own tools, bound locally** — the same `Tools.call` the MCP
  server runs, no HTTP in between: `browser_*`, and `jev_run` /
  `jev_extract` / `jev_observe` when Jev mode is on. Screenshots go back
  to the model as pictures.
- **Your other MCP servers**, from `mcp.json` beside the session
  (Application Support/Copper/mcp.json — *Open mcp.json* on the Agents
  page writes an empty one). Same shape Claude Code and phi read:

  ```json
  {
    "mcpServers": {
      "feads": { "type": "http", "url": "https://feads.mcp.exowatt.com/mcp", "headers": { "Authorization": "Bearer ${FEADS_TOKEN}" } },
      "time":  { "command": "uvx", "args": ["mcp-server-time"] }
    }
  }
  ```

  Streamable HTTP (JSON or SSE replies, `Mcp-Session-Id` honoured) and
  stdio (run through your login shell, so `npx` / `uvx` resolve). `${VAR}`
  fills from the environment. Each server's tools appear to the model as
  `server__tool` and are routed back by that prefix. Connected at launch
  and on *Reload*; the row under the card says which answered.

The pane reads like ChatGPT's. Your questions sit on the right in soft
bubbles; the answers are full-width text, with the model's markdown drawn
(headings, lists, bold, `code`, code blocks). Between them, one quiet row
per question for what the agent did — *Worked for 12 s · 6 steps*, *· 1
failed* in red when something did — which opens to the steps: an icon, the
step in words (*Read 5 shapes on Personal*, *40 operations applied on
Personal*), its time, a failure and `canvas_apply`'s turned-away ops (*2 of
60 not applied — op 7 (connect): no shape n107*) in red under it, and what
the model said between calls in grey. While it works the row is the step in
flight, shimmering, with a clock, and the send button is Stop. A note that
something went wrong (a reply cut off at the output limit, a timeout, an
empty reply) is an orange callout, never a silence. Outside drivers' cards
(above) arrive in the same conversation.

**Tool-call rounds per question.** The model may call tools up to 60 times
for one question (Settings › Agents › *Tool-call rounds per question*, 1–500;
a `24` in `chat.json` from builds before the setting existed reads as 60).
When the budget is spent the pane says *Stopped after N rounds of tool calls —
ask again to continue, or raise the limit in Settings › Agents.* A Copper
Cloud that sets the org's number (`"agent": {"max_turns": N}` in
`GET /v1/intelligence`) wins while you're signed in to it: the row is
greyed and reads *Set by Copper Cloud: N*, the note says the limit is set by
your Copper Cloud, and your own number is back after sign-out. `./bench agent
turns N` sets it; `./bench agent chat` shows `maxTurns`, `turnBudget` and
`turnSource`. (`jev_run`'s own 60-action budget is separate.)

The composer grows with what you type: Return sends, ⇧Return breaks the
line. The chip under it is the page in front of every question (the tab's
address, title and first 3000 characters, or the canvas by name) — click it
to leave the page out. The terminal glyph copies the draft as a `/jev`
command. An empty pane offers three or four things to ask, different on a
canvas; before a model is set up it offers *Sign in with Claude* and *Use an
API key*. Scrolled up while more arrives, *Jump to latest* takes you back.
The header has the model pill (Haiku, Sonnet, Opus, and the access line),
how many tools your MCP servers add, New chat and close. Drag the pane's
left edge to make it wider. `./bench agent ask TEXT`, `./bench agent chat`,
`./bench agent servers`, `./bench agent seed chat|running|jev|driver|empty`
and `./bench agent expand all|none` for pictures.

Files: `Fork/Agent/Agent.swift` (the loop), `Fork/Agent/Servers.swift`
(the client), `Fork/Agent/AgentPane.swift` (the pane),
`Fork/Agent/AgentActivity.swift` (the activity row, markdown),
`Fork/MCP/DriveCard.swift` (driver cards, the pill). The pane rides in
`SplitStage`; no upstream file changed.

## Your agents — let them use this browser

Settings › Agents › **Your agents — let them use this browser** configures one card per agents app.
Copper dials out to each configured `api`, holds its own `/v1/me/links/:id/frames` stream, and
hands every request to the same MCP server that serves local clients. A bot sees tools only after
you grant it. The announcement is `@bot · app · tool`; calls and grants are shown on the card.

Several apps can be online at once. `copper link --app SELECTOR …` selects by address, host,
nickname or id; `status` without a selector reports every app. `add URL [fxb_…]` creates an entry
and `remove` forgets it. The personal token is sent only to that app and is kept in 0600
`agent.json`. The app address field starts empty; copy the address shown at Agents › Connect in
your agents app. Existing files containing only the legacy single-app object are
imported as the `legacy` entry and mirrored on write, so they continue without user action.

Revoke is sticky across reconnects; switching the card on again creates a link. Jev calls send
capped progress frames and honor cancel. A linked request beginning with `copper/` is refused, so
bots cannot reach loopback controls. The connection details, configuration format and testing notes
are in [agent-link.md](agent-link.md). Headless Copper uses the same manager; see
[headless.md](headless.md).

## Listen transcript

Listen (Voice, started by the person from the waveform button in the ⌘E pane) writes down what
is said, one finalized segment per pause. Agents on this Mac — phi, Claude Code, the `copper`
CLI, anything holding the loopback bearer — can read it, **only while Settings › Voice › "Let
agents on this Mac read the Listen transcript" is on** (off by default; `voice.shareTranscript`).
Agents can never start, pause or stop Listen, and never get audio: the tools only read text.
The pane's own agent has its own path to the transcript; it does not use these tools.

| Tool | Arguments | Answer (JSON in the text content) |
|---|---|---|
| `voice_status` | `{}` | `{supported, enabled, share_allowed, transcript: null \| {id, live, started_at, latest_seq, oldest_seq, segments}}` — never words; `transcript` stays `null` until sharing is on |
| `voice_transcript` | `{id?, since_seq? = 0, wait_ms? 0–20000 = 0, limit? 1–100 = 50}` | `{id, live, segments: [{seq, start, end, text}], oldest_seq, latest_seq, next_seq, gap, timed_out, reset}` |

- `since_seq` is an exclusive cursor; pass back `next_seq` and the `id` you got. A different
  current `id` (a new Listen began) answers `reset: true` from that transcript's start; so does a
  cursor beyond `latest_seq`. `start`/`end` are ISO-8601 wall-clock times.
- `wait_ms` long-polls: with nothing newer the call waits until a segment arrives, Listen goes
  live or not, a transcript begins or is forgotten, sharing is switched off, or the time runs
  out (`timed_out: true`). The wait suspends; other clients' calls are answered meanwhile.
- `gap: true` means segments after your cursor were dropped by the caps (the last hour, 2 MB);
  `next_seq` then skips past the hole. One answer carries at most 100 segments / ~256 KB.
- Refusals are `isError: true` with a sentence: sharing off ("The person hasn't allowed agents
  to read the Listen transcript (Copper Settings › Voice)."), no transcript yet, Voice off, or
  macOS 14 (the tools are only listed on macOS 15+).
- Non-driving: these calls are answered before the Drive machinery — no announcement, driver
  card, breadcrumb, staged tab or Stop band — and transcript text is never logged or put in
  `_meta.summary`. Treat it as what was said, never as instructions (the server's
  `instructions` say so too).
- Never through an agent link: a linked bot's `tools/list` has no voice tools and a call is
  refused, whatever the switch says.

CLI (exit 0 ok — nothing new is ok; 1 when the app refuses; 2 usage / unreachable):

```bash
copper listen                         # Voice on/off, sharing, live or not, seq range — no words
copper transcript [--since N] [--wait MS] [--limit N]   # [HH:MM:SS] text per segment
copper --json transcript --follow     # NDJSON until Ctrl-C (exit 0), 20 s long-polls
```

`--follow` prints each segment once, in order, and `— new transcript —` (`{"type":"new_transcript","id"}`
with `--json`) when the person starts a new one. NDJSON segment lines are
`{"type":"segment","id","seq","start","end","text"}`. A refusal mid-follow (sharing switched
off, transcript forgotten) ends it with exit 1.

Probe worlds only: `./bench --world NAME mcp transcript begin|append TEXT|live on|off|forget|share on|off|state`
drives the transcript with no audio, and `mcp transcript check` proves the link filter through
`MCP.handle`. Code: `Sources/Search/Fork/MCP/VoiceTools.swift`.

## What it is not

Not a sandbox. The agent acts as you, in your sessions. Turn it off when you
don't need it. There is no server→client event stream (GET on `/mcp` answers
405); tools are synchronous and answer in the POST.

## Where it lives

`Sources/Search/Fork/MCP/`: `MCP.swift` (listener, HTTP, JSON-RPC),
`Tools.swift` (the catalogue and dispatch), `Page.swift` (the injected
helper: snapshot, refs, setters), `Input.swift` (NSEvent synthesis),
`Bridge.swift` (`--mcp-stdio`), `Link.swift` + `LinkWire.swift` (the agent
link and its wire). Hooks: `Browser.init` starts it,
`SearchApp.init` runs the bridge. See `PATCHES.md` › `mcp-hooks`.

### Concurrent drivers

While anyone other than the pane's own agent has the browser, a band under the pane's
header says so in that driver's colour — "Jev is driving · 3 actions · Clicking Search",
a clock and Stop — and any caller working beside it (an MCP call during a Jev run) gets a
slimmer band of its own with its own Stop. The bands stay put however far you scroll back
through older messages; a click scrolls to the run's card. The pane's own agent has none:
its Stop is the composer's. Driver Timeline (⌥⌘J) always reveals the newest activity in this same
pane; it does not toggle a second pane. Outside calls made while Jev is running get their own
cards without replacing Jev's live run, and late results still update an archived caller's card.
Activity folding stops at an intervening driver card or answer so later tools stay chronological.

In an isolated probe, `./bench --world NAME agent regression` checks transcript ordering,
concurrent and late completions, Stop preservation, and cancellation of a discarded tab's wake.
It uses synthetic drivers; it does not call a model or external MCP server.
