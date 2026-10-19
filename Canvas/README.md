# Canvas

The infinite whiteboard Copper shows at `copper://canvas/<id>`: stickies (markdown), text, frames
(optionally holding an image), arrows that attach to shapes or their sides, images, link cards and
live web frames (a link with `live: true`: the site itself in an iframe, `src/canvas/frames.ts`);
select, multi-select, marquee, move, resize, undo/redo, search, live cursors, a laser pointer
everyone on the board sees, and agent presence. Boards from Easels come over through `importLegacy`.

It is a Vite + React 19 + TypeScript + Tailwind v4 page, built with **bun** into one self-contained
file, **`dist/canvas.html`** (≈ 500 KB; every script and style inlined, no fonts or other requests).
That file is committed and copied into the app bundle; the app does not need bun to build.

The page never talks to the network (its CSP has `connect-src 'none'`; a live frame's iframe is
the site's own document, allowed by `frame-src https: http:`). Copper hosts it in a `WKWebView`,
persists its Yjs updates, and relays the sync socket over the bridge described below.

## Develop

```sh
cd Canvas
bun install
bun run dev            # then open http://localhost:5173/?dev=1
```

`?dev=1` (only outside Copper) stands in for the host: it records page → host messages on
`window.__copperHost.messages`, initialises a demo canvas from a stored state, and accepts:

| Param | Effect |
|---|---|
| `empty=1` | start from a blank board |
| `peers=1` | a simulated collaborator's cursor and selection (awareness); with `laser=1` she circles a note with the laser every few seconds |
| `agent=1` | a simulated agent that thinks, then writes notes through `apply` |
| `online=1` | the relayed sync socket against an in-page server (`src/dev-relay.ts`) |
| `theme=dark\|light` | force a theme (otherwise `prefers-color-scheme`) |
| `status=…&pending=N` | what the host would say through `setStatus` (e.g. `status=shared-offline&pending=3`) |
| `frames=1` | a live web frame (Wikipedia) beside the demo; with `peers=1` the collaborator is using it. `frames=refused` also says the host reports frame loads, so the frame (which nobody reports outside Copper) shows its "doesn't allow embedding" card |
| `readonly=1`, `name=…`, `kind=personal\|shared` | init options |

Checks (all must pass):

```sh
bun run test        # vitest (4 workers, from vitest.config.ts)
bun run typecheck   # tsc --noEmit
bun run lint        # eslint (typescript-eslint, react-hooks)
bun run build       # → dist/canvas.html
./build.sh          # bun install --frozen-lockfile && bun run build (no-op without bun)
```

## Embedding (host side)

1. Load `canvas.html` (e.g. `loadFileURL`) in a `WKWebView` with a script message handler named
   **`canvas`**. Keep `allowsMagnification = false`: the page handles pinch and ⌘-scroll itself.
2. Wait for `{"type":"ready","version":"1.0.0"}`, then call `copperCanvas.init({...})`.
3. Store every `{"type":"update","b64"}` in order (append-only log); replay them, or a snapshot
   from `copperCanvas.exportState()`, as `init.state` next time. Updates only depend on earlier
   updates from the same page, so keep the whole log (or compact it with `exportState`).
4. Online canvases: answer `{"type":"wsOpen","url"}` by opening the pinned, authenticated socket to
   `/v1/canvases/:id/ws`, then call `copperCanvas.wsState("open")`; forward every binary server frame
   with `copperCanvas.wsMessage(b64)` and every `{"type":"ws","b64"}` to the server; on a drop call
   `copperCanvas.wsState("closed")` (the provider reconnects by sending `wsOpen` again, with backoff);
   on `{"type":"wsClose"}` close the socket.
5. The page captures ⌘F for its own search; let that key reach the web view on canvas tabs.

The y-websocket provider closes a connection that has received nothing for 30 s. Like the
reference server, the sync server should broadcast awareness to every peer including the sender
(each client renews its awareness every 15 s), or otherwise send something at least every 30 s.

## Window API — host → page

Every function accepts a JSON string or a plain value and never throws into the host (failures are
reported as `{"type":"log","level":"error"}`). `apply` and `read` return JSON strings.

```js
copperCanvas.version                       // "1.0.0"

copperCanvas.init({
  docId: "8f1c…",                          // room name for the sync socket
  name: "Personal", kind: "personal",      // "personal" | "shared"
  me: { id: "u-123", name: "Ada", color: "#2f6fdf" },
  state: "AQL…" | null,                    // base64 Yjs update, applied before anything else
  online: false,                           // true → connect the relayed provider
  readOnly: false,
})                                          // a second init replaces the session

copperCanvas.applyUpdate("AQL…")            // a stored or relayed update (not echoed back)
copperCanvas.wsMessage("AAEC…")             // one binary frame from the server
copperCanvas.wsState("open" | "closed")
copperCanvas.exportState()                  // → base64 of the whole doc

copperCanvas.apply(JSON.stringify({
  as: { id: "agent:scout", name: "Scout", color: "#2b9348" },   // optional; default "Agent"
  ops: [
    { op: "add", shape: { type: "sticky", id: "n1", text: "**Ship** it", color: "yellow" } }, // no x/y → free space near the viewport centre
    { op: "add", shape: { type: "frame", x: 0, y: 0, w: 640, h: 400, title: "Ideas" } },
    { op: "add", shape: { type: "link", url: "https://example.com", title: "Example" } },
    { op: "add", shape: { type: "image", src: "https://…/a.png", naturalW: 800, naturalH: 600 } },
    { op: "add", shape: { type: "timeline", id: "t1", title: "Q4", start: "2026-10-01", end: "2026-12-31",
                          items: [{ date: "2026-10-14", label: "Kickoff" }] } },
    { op: "update", id: "n1", patch: { color: "pink", text: "Shipped" } },
    { op: "move", id: "n1", dx: 40, dy: 0 },
    { op: "resize", id: "n1", w: 260, h: 220 },
    { op: "connect", from: "n1", to: "n2", label: "then", fromSide: "right", toSide: "left" },
    { op: "delete", id: "n2" },
    { op: "clear" },
  ],
}))
// → '{"applied":8,"ids":["n1","…","…","…","n1","n1","n1",null,null,null],
//     "errors":[{"index":7,"op":"connect","error":"`to`: no shape n2"},{"index":8,"op":"delete","error":"no shape n2"}]}'

copperCanvas.read('{"full":false, "ids":["n1"], "types":["sticky"], "inView":true}')  // all optional
// → '{"canvas":{"id","name","kind"},"viewport":{"x","y","w","h","zoom"},
//     "shapes":[{"id","type","x","y","w","h","color","z","by","text"|"title"|"label"|"url",…}],
//     "agents":[{"id","name","color","cursor","status","updatedAt"}],"selection":["n1"],"count":12}'

copperCanvas.select(["n1", "n2"])           // also '["n1"]' or "n1"; not reported back as a selection message
copperCanvas.zoomTo(["n1"])                 // animated flight to the shapes' bounds
copperCanvas.setAgent({ id: "agent:scout", name: "Scout", color: "#2b9348",
                        cursor: { x: 120, y: 40 }, status: "thinking" })   // partial patches merge
copperCanvas.setAgent({ id: "agent:scout", remove: true })
copperCanvas.setStatus({ mode: "shared-offline", pending: 3 })  // what the title pill says; see below
copperCanvas.setShare({ canShare: true, members: 2 }) // show/enables the native Share button
copperCanvas.setShare({ canShare: false, reason: "Sign in to share" }) // disabled with a tooltip
copperCanvas.presence()                       // [{id,name,color,kind,cursor:{x,y}|null}] for everyone else
copperCanvas.theme("dark")                  // "light" | "dark" | "system" (default: system)
copperCanvas.frameEvent({ name, kind: "nav", url, title, icon }) // a live frame's report (also "escape", "blank"); → true if a frame took it
copperCanvas.frameHost({ reports: true })   // the host reports every frame: one that never does didn't load
copperCanvas.framePoster(name, "data:image/jpeg;base64,…" | null)  // the picture a framePoster asked for (see Staying fast); → true if asked

await copperCanvas.importLegacy({           // an Easels board onto this canvas (see below)
  doc: "AVji…",                             // base64 of the board's doc.yjs
  files: { "9f2c…": "data:image/webp;base64,…" },   // fileId → data: URL
  title: "Launch plan",                     // optional
})                                          // → {imported: 9, skipped: 3, error?: "…", already?: true}
```

### Importing an Easels board

`importLegacy(payload)` brings a board from Easels (the whiteboard Canvas replaced) onto the open
canvas. `payload` is an object or its JSON string:

| Field | |
|---|---|
| `doc` | base64 of the legacy Yjs document: what Easels kept in `easels/<id>/doc.yjs` (one `Y.encodeStateAsUpdate`). A stream of updates works too — a list of base64 updates, or one buffer of `4-byte big-endian length + bytes` or `varuint length + bytes` records. |
| `files` | `{ [fileId]: dataURL }` for the pictures in `easels/<id>/files/`; keys may be `fileId` or `file:fileId`. A bare base64 PNG/JPEG/GIF/WebP or an `https:` URL is accepted too. |
| `title` | optional; else the document's own `meta.title` |

It returns a **Promise** (pictures are measured first) that always resolves, never rejects:

```js
{ imported: 9,      // shapes written (a frame and the picture placed in it count as two)
  skipped: 3,       // legacy entries not brought over: unknown types, arrows with a missing end, pictures
  error: "1 picture could not be imported (gone-file)",   // only when something the old board showed is missing,
                    // or nothing could be read (bad JSON, not a Yjs update, read-only, no init)
  already: true }   // only when this exact document was imported into this canvas before (nothing written)
```

What it does:

- **One transaction**, origin `import`: posted to the host as one `{"type":"update"}` and relayed
  like any local change, but **not on the undo stack** (a stray ⌘Z must not empty a migrated board).
- **sticky** → sticky (same box, colour, markdown body as a `Y.Text`; `fontSize: 14`, the size Easels
  drew notes at). **frame** → frame (its `text` is the title). A frame with a picture (`image:
  "file:<id>"`) also gets an **image** shape inside it, `object-fit: contain` within an 8 px inset,
  natural size read from the image header (PNG, JPEG, GIF, WebP, SVG), else by decoding it, else the
  frame's size; data URLs over 2 MB are re-encoded smaller. **arrow** (`from`/`to` = `shape:<id>`) →
  arrow with `{ref}` ends and its text as the label, in the default colour (Easels drew arrows in one
  colour); an arrow whose end is missing is skipped, as Easels did not draw it either.
- Ids are kept so arrows resolve; an id the canvas already uses gets a fresh one and the arrows
  follow. Colours: palette names as they are, `#hex` passed through, `rgb()` / common colour words
  to the nearest palette colour. `by` is dropped. Stacking: frames, then pictures, then notes and
  arrows, all above what the canvas already holds.
- If the import would land on shapes already on the canvas it is moved beside them. The board then
  flies to what came over.
- `meta.name` becomes `title` when the canvas has none yet (empty, "Canvas", "Untitled canvas"…).
  The title pill still shows the host's `init.name`.
- The document's fingerprint is kept in `meta.importedLegacy`; importing the same bytes again into
  the same canvas answers `{imported: 0, skipped: 0, already: true}` and writes nothing.

### Connection status

`setStatus({mode, pending?})` tells the page how the host sees the board's connection, for the
title pill (top left). It is idempotent, survives `init` (so it may come before or after one), and
`setStatus(null)` clears it. `mode`:

| Mode | Pill | Use when |
|---|---|---|
| `local` | gray dot, "On this Mac" | the board never leaves this Mac |
| `personal-synced` | green dot, "Synced" | Personal, syncing to the account |
| `shared-live` | green dot, "Live", collaborators' avatars | a shared board with its room connected |
| `shared-offline` | amber dot, "Offline · changes saved on this Mac · N pending" | a shared board whose room is not connected (signed out, disconnected, no network) |

`pending` (optional, ≥ 0) is the number of local changes not yet handed to the cloud; it shows only
while offline. "Synced" and "Live" show only once the page's own socket has synced — before that the
pill says "Connecting" (or "Offline" if the socket dropped). Narrow windows keep a short text
("Offline · 3 pending"), never just a dot; the full sentence is in the pill's tooltip.

Without `setStatus` the page derives the pill as before from `init` and the socket — "On this Mac",
"Connecting", "Live", "Offline" — except that a `kind: "shared"` board initialised with
`online: false` reads "Offline · changes saved on this Mac" rather than "On this Mac".

### Sharing and presence

`setShare({canShare, members?, reason?})` controls the Share pill in the top-right chrome. It is
hidden until called, disabled (with `reason` as its tooltip) when `canShare` is false, and emits
`{"type":"share"}` when clicked so Copper can open its native Share sheet. Extra fields are ignored;
`setShare(null)` hides the pill. `presence()` returns current human awareness peers and live agents,
excluding this page, with each person's world-space cursor (or `null`). Human names and colours come
from `init.me`, which is also published in awareness.

### Ops semantics

- One transaction per call, ops in order; a bad op is skipped and reported, the rest apply.
  `ids[i]` is the id op `i` created or touched (`null` when it failed, and for `clear`).
  At most 500 ops per call. Agent ops are undoable by the user (one step per call).
- `add` defaults: sticky 200×200 yellow, text 240×36, frame 480×320 gray, link 300×84 white,
  image at natural size (≤ 480 wide), arrow needs `from`/`to`. Unknown props are errors.
  Friendly aliases: `text` on a frame/link is its `title`, on an arrow its `label`.
- Arrow ends: a shape id (`"n1"` or `"shape:n1"`), `{ref, side?}` with side `top|right|bottom|left`,
  or a free point `{x, y}`. Arrows have no box of their own.
- `move` on a frame carries the shapes lying wholly inside it; on an arrow it moves free ends.
- `delete` also deletes the arrows that end on the shape. `clear` keeps `meta` and `agents`.
- Images: `src` is a `data:image/…` URL (≤ 2 MB) or an `https:` URL. Link `url`: http(s), mailto,
  copper. `color`: yellow, pink, blue, green, purple, gray, white or `#hex`.
- A call with `as` marks that agent `writing` (cursor at the last thing it touched), then `idle`
  1.5 s later.
- A timeline (`src/canvas/timeline.ts`) is a sticky with `view:"timeline"` whose text is the
  timeline (`timeline-text.ts`). `add` takes `title`, `start`/`end` (YYYY-MM-DD), `step`
  (day|week|month|quarter|year; by the span when omitted) and `items:[{date, end?, label, text?,
  color?}]` — `text` makes a bubble, `end` a section. `update` takes the same (`items` replaces the
  list) plus `addItems` and `editItems:{ref: patch | null}`, a ref being `"YYYY-MM-DD · label"`, a
  label, a date or an index; refs that miss fail the op before it writes. `view:"timeline"` /
  `view:null` convert in place. `read` adds `view, title, start, end, step, items:[{date, end?,
  label, text?, color?, kind}]`.

## Page → host messages

`window.webkit.messageHandlers.canvas.postMessage(JSON.stringify(msg))`:

| Message | When |
|---|---|
| `{"type":"ready","version"}` | the API is installed; call `init` |
| `{"type":"update","b64"}` | after every local transaction (user, agent ops, presence, meta) — not for `init.state`, `applyUpdate` or server frames |
| `{"type":"selection","ids"}` | the user's selection changed |
| `{"type":"share"}` | the Share pill was clicked; Copper opens its native sheet |
| `{"type":"presence","people":[{"id","name","color","kind"}]}` | everyone else in the room, diffed and debounced (≤500 ms) |
| `{"type":"ws","b64"}` | a frame for the relayed socket |
| `{"type":"wsOpen","url"}` / `{"type":"wsClose"}` | open / close the relayed socket |
| `{"type":"openUrl","url"}` | a link card was opened or a link in a note clicked (the page never navigates) |
| `{"type":"log","level","msg"}` | diagnostics |
| `{"type":"framePoster","name","id","url","rect":{x,y,w,h},"maxWidth"}` | a live frame's site could be pictured now (its iframe's content box, CSS px of the page's viewport, fully on screen, nothing but arrows drawn over it); answer with `copperCanvas.framePoster(name, dataUrl)` or don't |

## Document schema

One Y.Doc per canvas (see `src/canvas/types.ts`):

- `shapes: Y.Map<id, Y.Map<prop>>` — per-property last-writer-wins. Every shape: `id, type, x, y, w,
  h, color, by, createdAt, updatedAt, z`. `sticky {text, fontSize?}`, `text {text, fontSize?,
  align?}` — `text` is a **Y.Text** (plain strings written by other writers are read too and
  upgraded on the next edit); `frame {title, image?:{src, naturalW, naturalH}}`; `arrow {from, to,
  label?}`; `image {src, naturalW, naturalH}`; `link {url, title, favicon?}`. Titles, labels and
  urls are plain strings. A sticky's `view` (`"checklist"`, `"timeline"`) draws its text as a card;
  everything such a card shows is read from that text (an older page shows the note).
- `agents: Y.Map<agentId, {name, color, cursor:{x,y}|null, status:'idle'|'thinking'|'writing',
  updatedAt}>` — whole values. Each entry is a two-second lease: every op renews it, the cursor fades
  over its last 200 ms, and the page that wrote it deletes it when it runs out (only if nobody has
  written the entry since), on `pagehide`, on `destroy` and when the sync socket drops; readers
  hide any entry older than two seconds too, so a peer that vanished leaves no ghost
  (`src/canvas/agents.ts`, `Session` in `src/controller.ts`).
- `meta: Y.Map` — `name`, `createdBy` (written once by the page that made the canvas).
- Awareness (human cursors): `{user:{id,name,color}, name, color, cursor:{x,y}|null, selection:[ids],
  laser: LaserWire|null}`. `laser` is the stroke someone is drawing with the laser pointer (**K**):
  `{id, color, start, end|null, pts:[x, y, dt, …]}` in world coordinates, at most 400 points, sent
  ≤ 30×/s while drawing and kept ~3 s after release so peers see it hold and fade. It is never written
  to the document; receivers re-anchor the sender's clock to their own (`src/canvas/laser/`).

Undo is a `Y.UndoManager` on `shapes` tracking the page's own origins (`local`, `agent`); stored
and relayed updates are never undone.

Sticky text is never shrunk to fit. A note whose markdown is taller than its box shows a fade and a
**Show all** pill that grows it to fit (one undo step, up to 960 px; a longer note opens in its
editor, which scrolls). While you type, a note grows the same way. Read-only boards show it all
locally without writing.

## Layout

```
src/
  main.tsx          mounts the board, installs window.copperCanvas, posts ready (or starts ?dev=1)
  api.ts            the window API (JSON in/out, never throws)
  controller.ts     the session: Y.Doc, store, awareness, provider, selection, agents, viewport
  host-bridge.ts    page → host framing (webkit handler, or the __copperHost double)
  bridge-socket.ts  BridgeSocket, the WebSocketPolyfill for y-websocket
  ops.ts            apply + read (the agent contract)
  canvas/legacy.ts  reading an Easels document for importLegacy
  placement.ts      free-slot placement near the viewport centre
  theme.ts          light / dark / system
  dev.ts, dev-relay.ts   ?dev=1 host double and in-page sync server
  canvas/           doc model, geometry, arrows, search, markdown, images, presence, and the UI
  canvas/laser/     the laser pointer: trails, awareness wire format, canvas renderer
  canvas/debug.ts   render counters; ?dev=1 adds window.__canvasDebug (seed a big board, frame times)
```

## Staying fast

A pan or zoom re-renders the board shell, never the shapes: every shape view is memoised on its
plain shape, and the board's actions (and the view flight they use) keep their identity across
renders. Wheel and pinch events move the view once per animation frame however many arrive; the
viewport's page rect is cached, so pointer and wheel events never force layout; the shape layer is
promoted (`will-change: transform`) only while the view moves. Awareness changes that only involve
this page (our own cursor and laser) and peer updates that move nothing drawn (a peer's laser, the
15 s renewal) re-render nothing. Measure with `?dev=1`:

```js
__canvasDebug.seed({ stickies: 150, frames: 12, arrows: 50 })
__canvasDebug.perf.start(); /* pan, drag, … */ __canvasDebug.perf.stop()
// → { frames, p50, p95, max, over16, over33, boardRenders, shapeRenders }
```

On any build, `window.__canvasCounters` has the running render counts (board, shapes, the whole
shape layer) and `performance.getEntriesByType('mark')` has `canvas:ready`, `canvas:init`,
`canvas:board` and `canvas:painted`. The big-board bench is `docs/fixtures/canvas-big`.

**Big boards** (≈ 1,500 shapes, dozens of live frames and images) stay light because the board
only draws what it needs, always deciding from the doc, never the DOM — so search, marquee,
snapping, frames' children, zoom-to-fit, keyboard moves, comments and the tools see every shape:

- *Culling* (`canvas/culling.ts`). Only shapes meeting the visible world plus half a viewport on
  each side are mounted, with what must stay (selection up to 64, the shape being edited, the
  frame in use, an open comment's or menu's shape, live frames keeping their page). The rect is
  recomputed in batches — when less than a quarter viewport of margin is left, or on settle —
  and while the view moves a re-cull mounts at most 150 new shapes a frame, nearest the middle
  first. Arrows are drawn from the doc's boxes, so one to an unmounted shape still lands on it.
- *One transformed layer, no per-shape work per frame.* The shape layer (`ShapeLayer.tsx`) is
  memoised as a whole; a pan or zoom changes its transform and nothing it renders. Its `--z` is
  the zoom the view last *settled* at (changing an inherited property restyles every shape); the
  few things that must stay the same size on screen through a zoom (frame titles, a live frame's
  ring) get the exact zoom as their own `--zx`. The view has settled 200 ms after it last moved.
- *Low-zoom LOD* (`canvas/lod.ts`, `Lod.tsx`). A note, text, checklist or timeline whose text
  would be under 4 px on screen draws its colour block and its first line (a checklist its rows
  as one line each), same box, same `data-id`. The LOD zoom goes down in 8 % steps mid-gesture,
  up only once the zoom has doubled, and exactly on settle.
- *Images* (`canvas/thumbs.ts`). An image drawn at under half its natural width draws a
  downscaled copy (96–768 px buckets, made two at a time on a canvas, kept as object URLs, LRU
  ≤ 192 MB decoded); a picture first seen zoomed out is never decoded at full size. Zooming back
  in draws the source again. A *vector* image (SVG) always draws a bitmap copy at the size it is
  shown (96–4096 px in ≈ √2 steps, ≤ 16 MP), since WebKit otherwise redraws the vector at every
  new scale; copies are made only while the view is still, a smaller copy stands in mid-zoom,
  and one with no copy yet waits as a plain card until the view stops. Card-sized images
  (≤ 2 M world px²) are their own compositing layer, so a zoom scales them on the GPU.
- *Card shadows* (`canvas/shadows.ts`). `--shadow-note` is drawn from a nine-slice bitmap
  rendered at startup (light and dark, radii 4/6/12) on a `::before`, not a blurred box-shadow
  that is re-blurred at every scale; stickies, image cards, checklists and timelines wear it
  (`baked-shadow`, index.css), and keep the box-shadow if the bitmaps can't be made.
  `docs/fixtures/canvas-easel` has the bench and the numbers.
- *Live frames* (`canvas/frames.ts` `planLiveFrames`). At most 6 iframes: the frame in use always;
  then frames on screen and ≥ 260 px wide on screen (kept down to 200 px), nearest the middle
  first. New ones mount only once the view has settled; one no longer wanted keeps its page 8 s
  (while there is room), so panning back doesn't reload it.
- *Posters* (`canvas/posters.ts`). A frame without its page shows the last picture of its site
  under its normal title bar. The page can't draw a cross-origin frame, so it asks the host
  (`framePoster`, above) once a live frame has been still for 2 s, at most every 30 s, and once
  more right before it unloads a frame that is still fully on screen (holding the page ≤ 1.2 s
  for it). The host's picture is of the board's view, so a frame is asked only while nothing is
  drawn over its page that must not be in it (`canvas/poster-view.ts`): every element painted
  above it — tool bar, zoom bar, panels, chat, menus, popovers, toasts, pins, cursors, handles,
  rings, the laser — is tested by its box, shadow, outline or ring against the iframe's box, not
  by sampling points. Arrows crossing the page and shapes with an opaque box (a note, a card, an
  image) may be in the picture: the board draws them again exactly over their copies at any zoom,
  and drops the picture the moment one of them or the frame changes (`PosterScene`). A selected
  arrow, text (it shows through), a frame's page or anything drawing outside its own box keeps
  the frame from being pictured until it is clear. An answer is kept only if the page is still
  clear and the view hasn't moved when it comes. Pictures are cached in memory by shape id + URL
  (LRU ≤ 40 MB; a frame whose URL moved on drops its own). A fresh page stays under its poster
  until it has painted, so nothing flashes.
  A host that never answers leaves frames on their card (title, favicon, host), and after three
  unanswered asks is no longer waited for before an unload.
- `ready` is posted when the API is installed, before any shape, frame or image loads.

Not in this version: comments/reactions (the `comments` map is left alone), multi-shape resize,
alignment guides.
