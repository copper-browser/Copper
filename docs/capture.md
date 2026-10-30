# Camera and microphone for web pages

*Google Meet, Zoom on the web, Slack huddles: a page asking for your camera or microphone
(`getUserMedia`). How Copper asks, what it remembers, what macOS has to allow first, and how a call
keeps hearing you while you look at other tabs. Implementation: `Sources/Search/Fork/Capture/`
(`CaptureChoices.swift` the rules, `CaptureDesk.swift` the requests and the bar's state,
`CaptureBar.swift` the bar, `CaptureCalls.swift` a call in the background, `CaptureHook.swift` the
page script and the Permissions API, `CaptureBench.swift` the bench). Screen sharing
(`getDisplayMedia`, a single tab included) is [screen-sharing.md](screen-sharing.md), which answers
WebKit's own display capture question. Copper's own dictation and Listen are [voice.md](voice.md).*

## Asking

A page asking shows one bar at the bottom of the window, in the window that holds its tab:

> 🎙 meet.google.com wants to use your microphone  **Allow**  Don't allow

- **Every request waits its turn.** A second request that arrives while the bar is up — the camera
  after the microphone, the same call open in two tabs, another window — waits behind it and is
  never refused for coming second. (Before, it got "no" without anyone being asked: no microphone,
  and nothing on screen to say why.)
- **One answer covers what it can.** WebKit hands a page's requests over one at a time; Copper's page
  script (below) says what else the page has asked for, so a call that asks for the microphone and
  the camera together is asked about once — *wants to use your camera and microphone* — and one
  Allow settles both. Every waiting request from the site that the answer covers, in any tab, is
  answered together.
- **A tab you are not looking at still asks.** The bar names the site, and **Show** takes you to the
  tab that asked when it is not the one on screen (another space, a background tab).
- Requests from a tab that closed, loaded again or went to another site while waiting are dropped
  (answered no) and leave the bar.
- **An answer is for what you read.** A click on Allow or Don't allow counts only if the bar still
  asks what it showed, and has shown it for half a second: a double click on one site's Allow never
  answers the next site's question, and a page widening its question (*…camera and microphone*)
  as you click never gets what you didn't read.
- A page with no host (a file, a `data:` page) is asked about on its own, every time, and nothing
  is remembered for it.
- **The same bar asks for on-device speech to text** (`window.copper.voice`, listed sites only —
  [voice.md](voice.md) › On web pages): *rgs.apps.exowatt.com wants to use your on-device speech to
  text*, after any camera or microphone question, with Show, the half-second read and the dropping
  of a page that went away as above. Its answer, yes or no, is kept per host (`capture.<host>|voice`)
  and Forget choices forgets it.

## What is remembered

- **Allow is kept, per site and per device.** `meet.google.com` allowed the microphone is not
  allowed the camera; a request for both needs both, and a site allowed only the microphone is
  asked only about the camera. A site is the host, with the port when it is not the scheme's own
  (`localhost:3000`). Kept in Copper's settings as `capture.sites`.
- **…for a page you can see.** A page Copper loads off screen before you look at it (another
  space's tab, warmed after launch — `Fork/SpaceWarm.swift`) counts as seen to WebKit, so it can
  ask; a call page there would have started your camera in a tab you never opened. Its site's Allow
  waits until the page is on screen, as WebKit holds its own grants for a hidden page.
- **If macOS refuses one of the devices** (the camera switched off for Copper, say), Allow lets in
  the other and the bar says what macOS refuses; the call keeps its microphone.
- **Don't allow is never written down.** It answers the page in front of you. WebKit itself then
  refuses that page's further asks until it loads again (unless you click in the page to ask), and
  after a reload you are asked again. So an accidental "no" is never a standing block.
- **Changing your mind:** for 8 seconds after Don't allow the bar says *Microphone blocked for
  meet.google.com* with **Allow and reload** — the site is allowed and the refused tabs load again
  so they can ask. Later, reloading the page asks again.
- **Settings › Privacy › Forget choices** forgets every site's Allow.
- **Older choices carry over.** Copper used to keep one yes-or-no per `capture.<host>|<type>`. On the
  first launch with this version every *yes* becomes the devices it named (camera and microphone =
  both) and every *no* is dropped — those sites are simply asked again. The old keys are removed.
- **The Permissions API agrees.** `navigator.permissions.query({name: "microphone"})` says
  `granted` for a site that was allowed it, so a call page goes straight to your devices instead of
  its own "allow your microphone" step; otherwise `prompt`, WebKit's own answer.

## What macOS allows

Pages get the camera and microphone through Copper, so macOS has to allow Copper first (System
Settings › Privacy & Security › Microphone / Camera). WebKit checks that before Copper is asked:

- **Not asked yet:** macOS's own question comes up first, the first time a page asks.
- **Turned off:** the page is refused without a word from WebKit. Copper hears about it (the page
  script reports a refusal) and the bar says so — *macOS isn't letting Copper use your microphone*,
  with **Open System Settings** (straight to the device's list) and **Not now**. Back from System
  Settings with Copper switched on, the bar offers **Reload** for the pages that were refused.
- **Managed / restricted** (a profile, Screen Time): *This Mac's settings don't let Copper use the
  microphone*, with only **Not now**.

Release builds are signed with one stable certificate (since v1.0.20261007.42), so the grant survives
updates. A development build (`com.collinrijock.copper.dev`) has its own grant.

## A call in another tab

Join a call in tab A and switch to tab B: people still hear you, and see you.

- **Capture never stops for a hidden page on a Mac** (WebKit's
  `InterruptAudioOnPageVisibilityChangeEnabled` is off outside iOS; Copper says so explicitly).
- **But a hidden page can't ask again.** Copper's stage holds only the tab on screen, and to WebKit
  a page out of any window — or in a covered window — is hidden. A hidden page's `getUserMedia()`
  waits until it is seen (WebCore `MediaDevices::getUserMedia`, *GetUserMediaRequiresFocus*), and so
  does its `devicechange` event (`MediaDevices::scheduledEventTimerFired`). That is exactly what a
  call does when its microphone changes — AirPods put in or taken out, another input picked — so
  the call went silent until you came back to it.
- **So a page that captures is never hidden.** While it uses the camera or microphone it ignores
  window occlusion (a covered window still counts as seen), and when you pick another tab its page
  waits in the off-screen room the space warm-up uses (`Room`, `Fork/SpaceWarm.swift`), laid out at
  the stage's size, until you come back or the call ends. Then it is an ordinary tab again. A
  capturing tab is never put to sleep ("on a call", `Sleep.swift`). Closing the tab ends the call.
- **Sharing a tab from a call** ([screen-sharing.md](screen-sharing.md)): the shared tab and the
  call are both kept seen, each wherever it is; neither one ending turns the other's occlusion back
  on — a call ending while its page is still sharing goes straight to the share's own stage, and a
  share ending leaves the call's page to the call.
- Measured (mock devices, `./bench --world mic-… privacy capture`): a background call re-asking for
  its microphone 4 s after you left it got it in **4 ms** (before: only when you returned, 8+ s
  later); the same with the window covered.

### One page at a time

WebKit lets one page capture at a time: when a page starts its microphone or camera, capture in
every other page is paused (muted), and nothing un-pauses it. Safari has a button for that in its
address field; Copper had nothing, so a call went silent for good the moment another tab tried its
microphone (a second call, a device test, a voice search).

- **The call on screen gets it back.** When the tab you are looking at was paused for another page
  and no other page is capturing anything any more, it resumes on its own. (Taking it back pauses
  every other page's capture, so it is never done on its own while one is — a call in another tab
  never goes quiet only because you looked at this one.)
- **When another page is still capturing,** the bar says *meet.google.com can't use your
  microphone — another tab is using it* with **Use it here**, which resumes this page and pauses
  the other.
- A page that muted itself through the Media Session API
  (`navigator.mediaSession.setMicrophoneActive(false)`) is left muted: Copper only ever resumes what
  WebKit paused. The page's word is taken for a mute, never for an unmute — that is seen in the
  capture going live again — so no page, or frame in it, can have Copper switch on a microphone it
  muted. Copper has no mute of its own.

## The page script

Every frame gets a small document-start script (`CaptureHook.script`) that wraps
`MediaDevices.prototype.getUserMedia` and the Media Session's `setMicrophoneActive` /
`setCameraActive`. It changes nothing about the call — same arguments, same promise, same answer —
and only tells Copper: a request started (and for which devices), it ended (and whether it was
refused), the page muted itself, a new page loaded. Messages go to the `copperCapture` handler;
nothing leaves the Mac. Any frame can post there and say anything, so nothing a message says can
let a page hear or see you: "a new page" counts only from the main frame, and what a page says it
asks for only widens the bar's question, which you read before answering.

## Devices

- The page follows macOS's default input the way WebKit does: a call using the default microphone
  moves to the new default when its device goes away; when a new one appears, the page hears
  `devicechange` and can switch — now also while it is in a background tab (see above).
- Device names in `enumerateDevices()` appear once the page has captured (WebKit's privacy rule,
  as in Safari); a site's choice of microphone by `deviceId` holds across reloads.
- Copper's own dictation and Listen (`Fork/Voice/VoiceCapture.swift`) open the microphone only while
  they run, with a plain input tap on the default device — no voice processing, no device or format
  change, no ducking — so they never take the microphone from a page, and a page never takes it from
  them: both hear you. (WebKit captures in its GPU process; macOS lets both read the same input.)

## Headless

A headless Copper ([headless.md](headless.md)) has nobody to ask: a request is granted if the site
was already allowed the device, and otherwise refused and logged.

## Checking it

In a test world, `capture.mock` (`defaults write com.officecommun.search.test.<world> capture.mock
-bool true`, or `SEARCH_SHARE_MOCK=1` at launch — one switch, two names) gives every page WebKit's
stand-in camera and microphone (a test pattern and a tone): no hardware, no macOS question. Never
anywhere else.

```
./bench --world mic-a privacy capture            # what is asked, kept, allowed; each call's capture and where its page is
./bench --world mic-a privacy capture allow      # the bar's buttons: allow | deny | show | undo | dismiss | reload | resume
                                                 # (allow, undo and resume only in a test world: the bench is any script of yours)
./bench --world mic-a privacy capture forget     # Settings › Privacy › Forget choices
./bench --world mic-a privacy capture seen on    # a covered probe window's pages count as seen (seen off: as they are)
./bench --world mic-a privacy capture keep off   # stop keeping calls seen, to compare
./bench --world mic-a privacy capture seed paused microphone meet.google.com
./bench --world mic-a privacy capture render /tmp/bar.png [dark]
```

`swift test --filter CaptureChoices` covers the rules: the queue, coalescing, per-device keys, what
is remembered and the migration of the old keys. `SEARCH_CAPTURE_DEBUG=1` (or any test world) logs
every decision on stderr as `copper[capture]: …`.
