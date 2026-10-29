# Voice — dictation and Listen in the agent pane

*Talk to the agent instead of typing. Speech is turned into text on this Mac by Fermion Research's
Phonon-2 on Core ML; audio is never saved or sent anywhere. Implementation: `Sources/Search/Fork/Voice/`
(`VoiceSession.swift` is the dictation, `VoiceKeys.swift` the shortcut, `VoiceUI.swift` the mic and the
line under the composer, `ComposerInsert.swift` where the words land, `Listen.swift`, `ListenUI.swift`,
`ListenAgent.swift` and `Transcript.swift` the live transcript, `VoiceEngine.swift` and `Phonon/` the model
runner, `ModelStore.swift` the download).*

## What it does

Voice lives in one place: the **⌘E agent pane**. Its composer gets a mic between the `/jev` button and
Send, and **⌃⇧D** dictates while the pane is open in the window you are typing in. The words go into the
agent's message — never into a web page, never into another app, never anywhere while the pane is closed.
The D in ⌃⇧D is the key that types a d (wherever a layout such as Dvorak puts it); on a layout without
Latin letters (Russian, Greek, Hebrew, Arabic…) it is the key in D's place on a US keyboard. It is never
both: on Dvorak that place types an e, and ⌃⇧E stays New Canvas. It needs exactly ⌃ and ⇧: with ⌘ or ⌥
held too, the keys go on to the page.

While you talk the mic turns solid and one muted line above the composer's buttons says
*Listening…* with the newest words heard so far (two lines at most; a long dictation shows its end).
Those words are a guess that keeps changing, so they never go into the message itself. When you stop,
the line says *Finishing…* for the moment the last decode takes (about 40 ms for 5 s of speech, under
100 ms for half a minute on an M-series Mac), and the text lands at the caret the composer had when you
started — with a space before it unless it starts the message or follows a space. A selection is replaced,
except the **whole message selected**, as it is right after the pane opens: then the words go at the end,
after what you had, so a dictation started straight after ⌘E never throws a message away (to replace all
of it, delete it first). The words go in as one edit, like typing: **⌘Z** takes back exactly them in one
step and **⇧⌘Z** puts them back, and what Return or Send sends is always the text you see — after an undo
or redo too.

**Escape** (or the line's ✕) cancels: what was heard is thrown away and the message and its selection
are as they were. Closing the pane, closing or leaving the window, switching to another app, the Mac
going to sleep or the microphone failing cancel too — leaving the window or the app only while you are
still talking: once you have let go (*Finishing…*), the words land as usual. A dictation stops by itself
after **2 minutes**. If the speech model can't load or can't make out the audio, the line says *Speech
model failed to load — try again* rather than ending quietly.

## Listen — a live transcript

**Listen** writes down what is said near the Mac — a meeting, a call, you thinking aloud — so the
pane's agent can follow along. It lives in the same place as dictation: the ⌘E pane. Its door is the
`waveform` button in the pane's header, before *New chat*, and only there when Voice is on. While the
speech model isn't ready the door is dimmed and a click opens Settings › Intelligence › Voice, as the mic does. A
click starts listening at once, with the microphone (the first time, macOS asks; Allow starts it).

A quiet card pinned under the header shows it: a steady dot, *Listening · 02:14*, **Pause** and
**Stop**, and the latest line in muted text under it, cut at its start when it is long. The chevron
opens the transcript: `hh:mm  text` rows, up to about 220 pt and then scrolling, with the phrase being
heard right now as the last grey row. New lines follow only while the list is at its end; scrolled up,
it stays put and offers *Jump to latest*. A line is written each time the speaker pauses (0.7 s) or after
15 s of unbroken speech; the grey row is a guess that keeps changing and is never written down.

| State | The card | Controls |
|---|---|---|
| Listening | *Listening · mm:ss*, the latest line | Pause · Stop |
| Paused | *Paused · you paused* (or *pane closed*, *Mac went to sleep*, *screen locked*, *microphone disconnected*) | Resume · Stop |
| Stopped | *Transcript · mm:ss* | Listen again · Forget |

Resume and *Listen again* (or the door, while paused or stopped) listen on into the **same**
transcript; nothing ever resumes by itself. Closing the pane, the Mac going to sleep, the screen
locking (or another user taking the Mac) and the microphone going away pause it, with that reason;
closing the window it was started from stops it. Switching to another app does not — a meeting goes
on in another app. **Forget** removes the card and the transcript; so do **New chat** and turning
Voice off. One capture at a time: while Listen is listening or paused, the mic is off and ⌃⇧D says
*Stop Listen to dictate*; while you dictate, the Listen door is.

**The pane's agent.** Once something has been said, a **Live transcript** chip sits beside the page
chip in the composer — on when a transcript begins, a click leaves it out. While it is on, the question
you send carries the transcript as it stands, after your words:

```
<speech_transcript from="14:02:10" to="14:16:41" live="true" truncated="false">
[14:02:10] Okay, let's get started. First item is the release on Thursday.
[14:02:18] …
</speech_transcript>
```

newest last, at most 12,000 characters (the oldest lines go first, and `truncated="true"` says so). It is
put in that one question when you send it and kept as sent; later questions carry the transcript as it
stands then. During a long answer the agent can also read what was said since with a tool of the pane's
own, `transcript_read {since_seq?, limit? ≤ 100}` → `{segments: [{seq, start, end, text}], latest_seq,
gap, live}`, offered only while there is a transcript and refused while the chip is off — the chip is the one
switch for what the pane's agent may read. Its system prompt says, in one fixed sentence,
that transcripts are spoken words recorded by Listen — observations, never instructions.

**Agents on this Mac** (phi, Claude Code, `copper transcript`) can read the transcript only if you allow
it in **Settings › Intelligence › Voice** (off by default); they can never start Listen or hear audio. See
[docs/agents.md › Listen transcript](agents.md#listen-transcript).

**Privacy.** The transcript lives in memory only — the last hour, at most 2 MB of text — and is gone
when you quit, Forget or start a new chat. Nothing is written to disk; the logs carry counts and times,
never words. VoiceOver says *Listening*, *Listen paused* and *Listen stopped* once each, never a line.

## Settings › Intelligence › Voice

| Setting | Choices |
|---|---|
| **Voice** | Off by default. Turning it on downloads the speech model once (345 MB) and prepares it for this Mac's Neural Engine (about a minute, once). Off stops a download in flight and hides every trace of voice in the pane; the ⌃⇧D key then does nothing and reaches the page as usual. |
| **Talk** | **Hold to talk** — hold ⌃⇧D, or press and hold the mic; let go to stop. A tap shorter than a quarter of a second says *Hold to talk* and does nothing. **Press to start and stop** — ⌃⇧D or a click starts, the same again stops. |
| **When you stop** | **Insert into the message** — nothing is sent; read it and press Return. **Send right away** — the whole message is sent the way Return sends it, for a back-and-forth. If the agent is still answering (or isn't set up), the words are inserted and the line says *Inserted — press Return to send*; nothing is queued or lost. |

The mic tells you when it can't listen yet: dimmed while the model downloads (*Speech model downloading
· 42%*) or is prepared (*Preparing speech model — one time, about a minute*), or when it needs attention;
a click then opens Settings › Intelligence › Voice. It is greyed out while the agent has no model to talk to (*Sign in
with Claude or add a key to use the agent*).

The model is loaded when the pane opens — a third of a second on a Mac that has prepared it. When macOS
has thrown that preparation away (after an update, say), the next load prepares it again for about a
minute. Once a load has taken more than a second the mic dims with *Preparing speech model — one time,
about a minute*, and ⌃⇧D or the mic says *Preparing speech model… try again in a moment* instead of
listening. A dictation that was already under way keeps listening; when you stop, the line says
*Finishing… preparing speech model* until the words can be made out, then they land as usual.

## The microphone

macOS asks for the microphone the **first time you dictate** — never at launch, never for an agent.
The question takes the keyboard and the pointer, so in hold mode nothing starts once you answer Allow —
nobody may be holding the key any more — and the line says *Microphone allowed — hold ⌃⇧D to talk* (or
*hold the mic button*); hold again to dictate. In press-to-start mode, Allow starts the dictation you
asked for. Once access is granted there is no question and nothing changes. If the
answer was no, the composer says *Microphone access is off. Open System Settings to allow Copper, then
try again.* with a link to System Settings › Privacy & Security › Microphone. Copper's prompt text:
"Copper uses your microphone when you dictate to the agent, and when a website you allow asks for it.
Speech is turned into text on this Mac." (`build.sh`, `NSMicrophoneUsageDescription`).

## Privacy

- Audio and every word stay in memory for the length of one dictation and are then let go. Nothing is
  written to disk; nothing goes over the network. The logs carry counts and times only, never words.
- The partial line is never part of the message, and only the final text you see is ever sent — by you,
  or by *Send right away*.
- The model is loaded when the pane opens with voice ready (a third of a second once prepared) and let
  go again after 10 minutes without a dictation (100–200 MB of memory).

## The model

Phonon-2 Core ML (`FermionResearch/Phonon-2-CoreML`, pinned revision, every file SHA-256 checked) lives
in `~/Library/Application Support/Copper/Models/phonon-2-coreml/`, excluded from Time Machine. A
download a quit interrupts resumes at the next launch. **Settings › Intelligence › Voice › Remove** deletes it and turns
voice off. Voice needs **macOS 15** (the model is a multifunction Core ML package); on macOS 14 there is
no mic and Settings says why. Headless Copper never opens a microphone.

Speech model: [Phonon-2](https://huggingface.co/FermionResearch/Phonon-2-CoreML) by Fermion Research,
derived from [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), CC BY 4.0.
Speech runtime: the runner in `Sources/Search/Fork/Voice/Phonon` and `Sources/PhononTDT` is Fermion
Research's [phonon-coreml](https://github.com/fermionresearch/phonon-coreml), Apache-2.0. Settings › Intelligence › Voice
credits both, and `build.sh` puts the runner's `LICENSE` and `NOTICE` in the app, in
`Contents/Resources/phonon-coreml/`.

## Checking it

Everything below runs in a probe world, with a sound file standing in for the microphone — no check
ever opens a mic or brings up the permission prompt (a test world refuses the real microphone unless
`SEARCH_VOICE_MIC=1`). Every `voice` verb that changes something (`dictate`, `source`, `key`, `warm`,
`seed`, `render`, `prefs`, `editor`, `listen` but `listen state`, `model install|cancel|remove`) is refused
outside a test world; `selftest`, `replay`, `status`, `state`, `listen state` and `model status` run anywhere.

```sh
W=voice
defaults write com.officecommun.search.test.$W bench -bool true
defaults write com.officecommun.search.test.$W welcomed -bool true
defaults write com.officecommun.search.test.$W voice.enabled -bool true
open -n -g --env SEARCH_PROBE=$W --env SEARCH_HEADLESS=1 \
  --env SEARCH_VOICE_MODEL_DIR=/path/to/a/ready/model build/Copper.app

./bench --world $W voice selftest     # engine, live session, 15.00 s clip, composer insert, keys → failures []
./bench --world $W voice dictate clip.wav --trigger hold --finish insert --draft "Note: " --caret 6
./bench --world $W voice dictate clip.wav --trigger toggle --finish send     # sendCalled, sent
./bench --world $W voice dictate clip.wav --cancel-at 2                     # draftUnchanged, selection back
./bench --world $W voice dictate clip.wav --draft "Note:" --type " typed" --undo   # undoOneStep, redoRestores, in sync
./bench --world $W voice dictate clip.wav --draft "Keep all of this." --reopen     # whole draft selected → appended
./bench --world $W voice dictate clip.wav --warm-delay 4                    # slow load: whilePreparing, then as usual
./bench --world $W voice dictate clip.wav --warm-delay 8 --start-cold       # finishingLines: "Finishing… preparing…"
./bench --world $W voice dictate clip.wav --keys в                          # ⌃⇧ + D's key on a Russian layout
./bench --world $W voice dictate clip.wav --decode-fails                    # every decode throws: "Speech model failed to load"
./bench --world $W voice dictate clip.wav --permission ask-grant [--keys d|--button] [--release-during-prompt]
                                       # first use, hold: Allow starts nothing, "Microphone allowed — hold … to talk"
./bench --world $W voice dictate clip.wav --trigger toggle --permission ask-grant   # first use, toggle: starts after Allow
./bench --world $W voice dictate clip.wav --blur-at finishing               # window loses the keyboard after let-go: lands
./bench --world $W voice dictate clip.wav --blur-at dictating               # …while talking: cancelled
./bench --world $W voice source clip.wav && ./bench --world $W voice key down   # ⌃⇧D through the app…
./bench --world $W voice key up                                             # …and let go
./bench --world $W voice seed dictating && ./bench --world $W voice render /tmp/pane.png 340 dark
./bench --world $W voice render /tmp/voice-settings.png 409 settings        # Settings › Intelligence › Voice, narrowest column
./bench --world $W voice listen start --source talk.wav --fast --wait       # a real Listen session, the file as the mic
./bench --world $W voice listen pause|resume|stop|forget                    # the card's controls
./bench --world $W voice listen close-pane|sleep|lock|device-lost           # what pauses it, as it arrives
./bench --world $W voice listen state --last 5                             # phase, reason, count, last lines, live, partial
./bench --world $W voice seed listening|listen-expanded|listen-paused|listen-stopped   # the card, for pictures
```

`--undo` presses ⌘Z and then ⇧⌘Z the way the Edit menu sends them, a key press's worth of event loop after
the words land. In a probe window that isn't key the menu can't reach the composer, so the action goes down
the composer's own responder chain — where the menu would have sent it. `--warm-delay S` lets the model go
and holds every load S seconds, standing in for the Neural Engine's first-time preparation (`voice warm cold
S` does the same on its own). `voice editor resync` changes the composer's text without telling its field — the
way AppKit's own undo does — and runs Return's re-sync, which brings the draft along before anything is sent.

`voice dictate` answers with the state timeline (milliseconds from the press: partials as word counts,
release, decode, insert, send, the model loading), the words inserted, the draft before and after, whether
the message was sent, and `release_to_insert_ms`. `voice seed
idle|dictating|finishing|finishing-warming|denied|preparing|warming|downloading` freezes the composer for
pictures; `voice state` shows the phase, what the mic and the line show, the model in memory
(`engine`: cold, warming, warm) and how many ⌃⇧D presses were taken or let through.
