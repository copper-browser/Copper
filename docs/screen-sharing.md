# Screen sharing: a tab, a window or the screen

When a page asks to share your screen — Present now in Google Meet, Share
Screen in Zoom on the web, a Slack huddle — Copper asks what to share in a
card of its own, the way ⌘K looks:

- **Tabs**: every tab in this window's space, then each other space's under
  its name, each with its icon, title and site. The tab that is asking is left
  out (a call shared into itself is a hall of mirrors), unless the page asked
  to be offered itself (`selfBrowserSurface: "include"` or `preferCurrentTab`),
  and then it comes first, marked *This tab*. Blank and private tabs are never
  offered, and nothing but a tab the card offered can be shared: a private
  tab keeps nothing and is no other page's to see, and a page in an ordinary
  tab has no way to name one. Typing narrows the list.
- **A window…** and **Entire screen…** hand over to macOS's own picker, as
  before.

The card names the site that would be handed the pictures — the frame's,
when the call lives in a frame of another site inside the page, with *In a
frame on* the page's site under it — and the bar says the same.

↑ ↓ (and ⇥) walk the rows, Return shares, Escape, ⌘. or a click outside
cancels. Cancelling tells the page `NotAllowedError`, as Chrome does. A page
that hints what it wants (`video: { displaySurface: "monitor" }`, as Chrome
reads it) gets that row highlighted first.

A shared tab is shared as a page: only its content, never Copper around it, at
up to 30 frames a second and up to 1920 pixels wide (Retina detail, shrunk to
fit; less when the page asks for less). It keeps going while you are on
another tab — the call, your notes, another app — and while the shared tab is
in front. The page sees a video track like Chrome's for a tab:
`getSettings().displaySurface` is `"browser"`, the track's label is the tab's
title as it was when you chose it (a track's label never changes, and the
page is not told the title of every page you then open in the tab), and it
goes over WebRTC like any other.

While a tab is shared, a capsule at the foot of the window says **Sharing
*title* with *site*** and **Stop**. Clicking the title takes you to the shared
tab. It stands aside on the page doing the sharing, which has its own Stop and
its own controls along that edge. The share ends, and the page hears `ended`
on its track, when you press Stop, close the shared tab, or close or leave the
page that is sharing; the page's own `track.stop()` ends it too. A shared tab
and the page sharing it are never put to sleep.

**Tab audio isn't shared.** A page that asks for audio with a tab gets the
video alone, as Chrome gives for a window. For sound, share the screen with
the call's own audio, or play it into the call from the shared tab's site.

## How it works

```
page          getDisplayMedia (wrapped)
  │  "ask" ──────────────► TabShare (Copper)            the page's note: a call is coming
  │  WebKit's own call ──► WebKit ─► _webView:requestDisplayCapturePermission… (Browser, private)
  │                                      │
  │                                Copper's picker
  │              ┌───────────────┬───────┴──────┬─────────────┐
  │              tab             window         screen        cancel
  │     answer "tab" + Deny   WindowPrompt   ScreenPrompt      Deny
  │              │               └── macOS's picker ──┘          │
  ◄── a stream built from        WebKit's stream          NotAllowedError
      pictures of the tab
```

1. **The page's half** (`Fork/TabShare/TabShareScript.swift`, every frame,
   at document start). `MediaDevices.prototype.getDisplayMedia` is replaced by
   a Proxy of itself: same name, same length, `[native code]`, nothing done
   until it is called. Called, it posts an *ask* to Copper and calls WebKit's
   own getDisplayMedia straight away, inside the same click, so WebKit's rules
   — a user gesture, a visible document, one request at a time, the
   `display-capture` permissions policy for frames — stay WebKit's.
2. **WebKit's question.** Copper answers WebKit's private UI-delegate method
   `_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:`
   (`WKUIDelegatePrivate.h`, macOS 13+; `Fork/TabShare/TabShareDelegate.swift`,
   an `@objc` method on `Browser`, the UI delegate of every tab).
   `UIDelegate.mm` asks `respondsToSelector:` for exactly that selector before
   a display request. Without it, WebKit sent screen sharing to the public
   camera method ("wants to use your camera") before WebKit's fix for
   [bug 274896](https://bugs.webkit.org/show_bug.cgi?id=274896) (May 2024),
   and to macOS's picker on its own after. The answer is
   `WKDisplayCapturePermissionDecision`: `Deny` = 0, `ScreenPrompt` = 1,
   `WindowPrompt` = 2. WebKit's request is matched to the page's ask by web
   view, frame, document and origin (see *Who gets the pictures*); a request
   with no ask from its own site is offered a window or the screen only.
3. **A tab.** Copper answers the ask with a share id (128 random bits) and
   refuses WebKit's request; the wrapper lets that refusal go and builds the
   stream itself: a canvas that is never in the document, captured with
   `captureStream()`, drawn with each picture as it arrives. The track is
   dressed as a tab capture (label, `getSettings`, `getCapabilities`,
   `applyConstraints`, `stop`, `clone`).
4. **Pictures** (`Fork/TabShare/TabShareCapture.swift`). `WKWebView.takeSnapshot`
   of the shared tab, one at a time, at the picture's size; JPEG at 0.7 on a
   queue of its own; handed to the page's long poll over its script message
   handler (`WKScriptMessageHandlerWithReply`, base64: WebKit's reply carries
   no bytes). A picture identical to the last is not sent again, except once a
   second, so a still slide still looks alive. A picture is taken only while
   the page is asking for one: a page that stops asking (frozen, throttled,
   gone) costs no snapshots or JPEGs, and a page asking over and over gets
   "nothing new" for all but its last two asks.
5. **Keeping the tab painting** (`Fork/TabShare/TabShareStage.swift`). The
   stage holds only the tab you are on; every other tab's view has no window,
   and WebKit treats a page with no window as hidden: no painting, no
   animation frames. While a tab is shared and not on a stage, its view hangs
   in a borderless panel outside every display, ordered in, with WebKit's
   occlusion detection off for it (`_setWindowOcclusionDetectionEnabled:`,
   guarded) — the trick headless mode and agent tabs use. Choosing the tab
   takes its view back to your stage; leaving it hangs it again on the next
   picture. The page doing the sharing is kept the same way while you are on
   another tab, so a call page never drops to a background tab's pace.
   Occlusion detection is put back when the share ends, for the views this
   turned it off for.

No Screen Recording permission is involved for a tab: Copper pictures its own
web view. *A window…* and *Entire screen…* are WebKit's and macOS's, and need
it as before.

## Who gets the pictures

The page's script and Copper's `copperShare` handler live in the page's own
JavaScript world — the wrapper has to, to wrap the page's getDisplayMedia —
so any script in any frame can post anything to the handler. Nothing it says
about itself is believed: every message is held to the web view, frame,
document and origin WebKit names for it (`WKScriptMessage.frameInfo`; the
frame's `_handle.frameID` and `_documentIdentifier` are WebKit's private
WKFrameInfo accessors, asked for only where this WebKit answers to them —
the document's since macOS 15.4; without them the web view and origin still
bind).

- A share exists only after you pick a tab in the card, and the card comes up
  only for WebKit's own request — a user gesture, a visible document, the
  `display-capture` permissions policy for frames, all WebKit's checks. An ask
  posted on its own puts nothing up and is never answered with a tab.
- WebKit's request is matched to the ask of the very frame and document that
  made it, in its origin; failing that, to one from another frame of the same
  site in the same page (a page calling the getDisplayMedia of an about:blank
  frame it made asks from there), never across opaque origins and never the
  last document's in the same frame. An ask planted by another origin — a
  cross-origin frame posting to the handler itself — is never handed the tab
  you pick for the page; a request with no ask from its own site (a page that
  reached WebKit's getDisplayMedia some way the wrapper never saw: an
  extension's script that kept it before Copper's ran, say) is offered a
  window or the screen, not a tab.
- The share id is 128 random bits, made for one pick, and is the script's
  alone: the track's `deviceId` is the page's own ask id, not the share's.
  Even so, it is no use to anyone else — pictures, `tune` and `stop` answer
  only the one frame and document the share was handed to, in its origin, in
  its web view.
- A new document in that frame ends the share, at once: the main frame's
  commit (`Browser.swift` `didCommit` → `TabShare.committed`), whether or not
  the page let its pagehide be heard, and for a frame, its next message from
  the new document. A share whose page never collects it (it navigated while
  the card was up) ends after five seconds; one whose page stops asking ends
  after twelve; Stop, the shared tab closing and the page's own `stop()` end
  it at once.
- The page can tell it is in Copper: the handler's name is on
  `window.webkit.messageHandlers`, and `Function.prototype.toString` of the
  wrapper reads as a Proxy. Neither tells it anything about your tabs.

## Why this way

Measured on macOS 27.2 (M-series, 1440×848 pt pages), before and after:

| | |
|---|---|
| `takeSnapshot`, 1280×720 / 1920×1080 | 0.6 ms / 2.1 ms (WebKit's GPU process paints it) |
| JPEG 0.7, 1280×720 / 1920×1080 | 1.3 ms, 46 KB / 3 ms, 87 KB |
| decode + draw in the page (`createImageBitmap`) | 2.5 ms / 4.6 ms |
| end to end, page's `<video>` | 30.1 fps at both sizes |
| shared tab off screen, caller in front | 30 fps, every frame different |
| RTCPeerConnection, `framesEncoded` | 29.8–30 fps |
| caller kept painting / not, shared tab in front | 30 / 24 fps encoded |
| cost at 1222×720, % of one core | Copper 9, shared page 4.5, calling page 9, GPU 15 |
| cost at 1920×1130 | Copper 16, shared page 5, calling page 17, GPU 24 |
| for comparison, the shared page animating on screen, no share | 3 / 4 / 0 / 5 |
| windowed, the Copper window behind other apps, 1780×1200 | 30.2 fps, 30 encoded; the shared page not hidden |

`takeSnapshot` on this WebKit pictures `<video>` and WebGL as well as the
page (checked with an H.264 clip and a WebGL canvas).

Rejected:

- **ScreenCaptureKit on the parked window** (`SCStream`, `sourceRect` on the
  web view): needs Screen Recording for Copper — a system prompt for a feature
  that pictures Copper's own page — and WindowServer composites a window off
  every display unreliably (a probe's window picture of an off-screen page
  showed its `<video>` empty).
- **`CALayer.render(in:)`**: the page is a remote layer tree drawn in WebKit's
  processes; rendering it on the UI side gives the backdrop, not the page.
- **`takeSnapshot` of a view with no window**: it answers (0.6 ms), but the
  page is hidden — `requestAnimationFrame` stops, the picture freezes.
- **A loopback WebSocket or HTTP stream**: the message-reply long poll already
  holds 30 fps at 1920 wide for under a millisecond of bridge time per frame,
  needs no port, no token and no origin check, and can't be reached by
  anything but the frame that asked. A `WKURLSchemeHandler` stream would be
  mixed content on https pages.
- **`MediaStreamTrackGenerator` / `VideoTrackGenerator`**: not in this
  WebKit's window scope; a detached canvas's `captureStream()` is everywhere
  and kept its pace in a background page (WebCore pushes a new frame on every
  draw, with no rendering update needed).
- **NSImage's `cgImage(forProposedRect:)`** for the snapshot: it redraws the
  picture for the main screen — a fifth of a core at 30 fps. The
  representation's own CGImage is the one WebKit made.

## Limits

- No tab audio (see above). WebKit gives no public tap on a page's sound.
- A page that calls `getDisplayMedia` some way the wrapper never sees — an
  extension's script that kept WebKit's own before Copper's ran — is offered
  a window or the screen only: a tab is handed only to a frame of the
  requesting site whose ask matches WebKit's request.
- Another page asking while the card is up is refused (NotAllowedError) and
  can ask again; the card is one at a time.
- A shared tab whose page crashes holds its last picture until Copper
  reloads it (when you go to it), then carries on.
- `Function.prototype.toString` of the wrapper reads
  `function ProxyObject() { [native code] }` rather than naming
  getDisplayMedia; `.name` and `.length` are WebKit's.
- Headless runs decline the picker (nobody is there to click it), except in a
  test world, where the bench answers it.
- Choosing the shared tab moves its view from the off-screen panel to your
  stage, and the page sees `visibilitychange` hidden → visible within about
  25 ms (the stage takes a view out of its old window before putting it in).
  The pictures don't stop.

## Testing

- `swift test --filter TabShare`: constraints, sizes, matching an ask to
  WebKit's request (frame, document and origin; never another origin's), the
  names on the card, back-pressure and the ends, the picker's list
  (`TabShareRulesTests`); the page script in JavaScriptCore against a
  stand-in page — untouched until called, the tab path's fixed label and
  private share id (`TabShareScriptTests`).
- `docs/fixtures/tab-share-e2e.sh`: a headless test world end to end — the
  picker, a tab at pace behind the calling tab and over WebRTC, the ends,
  cancel, window and screen through WebKit's mock devices, a cross-origin
  frame, constraints, what it costs, and nothing without a pick: a page
  posting to the handler itself, another tab or frame holding a real share
  id, the next document in the same tab, an ask planted by another origin. Pictures in `/tmp/copper-tabshare-qa`.
- `./bench --world NAME share …`: `state`, `answer tab ID|window|screen|cancel`,
  `keys` and `occlusion ID on|off` (test worlds only; the last lets a windowed
  probe behind your own windows call getDisplayMedia, which wants a visible
  page), `stop`, `caller on|off`, `picture window|picker|bar PATH [dark]`. `SEARCH_SHARE_MOCK=1` at launch, in a
  test world, turns on WebKit's mock capture devices.
