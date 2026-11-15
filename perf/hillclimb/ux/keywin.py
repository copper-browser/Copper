#!/usr/bin/env python3
"""Key-window run: B13 (Keyboard + VoiceOver) and B14 (Motion + interaction states).

    python3 keywin.py LABEL APP OUTDIR      # ux.sh runs it (UX_MODE=keywin) under lockf -k ~/hc/mini.lock

One windowed probe world (a LaunchAgent in gui/UID, the lived-in seed) on the mini's
real screen, pictured with `bench window` (WindowServer's pixels, so mid-animation frames
are real). Writes OUTDIR/keywin.json, OUTDIR/keywin/*.png (focus walk, Welcome),
OUTDIR/motion/<name>/NNN.png + sheet.png, OUTDIR/motion.json.
A hook a build lacks is "n/a: hook missing (needs hc/hooks)", never a crash.
"""
import json, os, re, shutil, socket, struct, subprocess, sys, threading, time

import ax
from drive import World, calm, seed_lived_in, tab_id, free_port, welcome

PIX = os.environ.get("UX_PIX", os.path.expanduser("~/hc/bin/ux-pix"))
MISSING = "n/a: hook missing (needs hc/hooks)"
CONTROLS = {"AXCheckBox", "AXButton", "AXRadioButton", "AXRadioGroup", "AXTextField", "AXPopUpButton", "AXSlider", "AXSwitch",
            "AXToggle", "AXMenuButton", "AXLink", "AXSecureTextField", "AXComboBox", "AXTextArea"}  # as SettingsControls.swift
LIGHTS = {"AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"}  # VoiceOver names these by subrole


def ax_name(e):
    """What VoiceOver reads as the control's name (AXDescription, else title, else its title element, else placeholder)."""
    return e.get("description") or e.get("title") or e.get("titleElement") or e.get("placeholder")


def ask(w, req, timeout=30):
    """One bench request over the world's socket, no process spawn: bursts of pictures stay fast."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(os.path.join(w.folder, "bench.sock"))
        s.sendall((json.dumps(req) + "\n").encode())
        data = b""
        while True:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            data += chunk
    return json.loads(data.split(b"\n", 1)[0] or b"{}")


def pix(*args):
    if not os.path.exists(PIX):
        return None
    r = subprocess.run([PIX, *map(str, args)], capture_output=True, text=True)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def png_width(path):
    with open(path, "rb") as f:
        return struct.unpack(">I", f.read(24)[16:20])[0]


class Run:
    def __init__(self, w, out):
        self.w, self.out, self.checks = w, out, []
        self.ax = False  # True when the AX probe (ax.py) is trusted and the screen is unlocked: real AX focus, tree, HID keys
        self.ax_blocker = ""
        os.makedirs(os.path.join(out, "keywin"), exist_ok=True)

    def rec(self, name, ok, detail, cat="B13"):
        self.checks.append({"category": cat, "check": name, "pass": ok, "detail": detail})
        print(("PASS" if ok else ("N/A " if ok is None else "FAIL")) + f" {name}: {detail}", flush=True)

    def hook(self, *args, needs=None):
        """(answer, None) or (None, why) — a build without the hook answers an error or lacks `needs`."""
        try:
            a = self.w.j(*args)
        except Exception as e:
            return None, f"{MISSING} — {str(e)[:120]}"
        if needs and needs not in a:
            return None, f"{MISSING} — answer has no {needs!r}"
        return a, None

    def snap(self, name):
        path = os.path.join(self.out, "keywin", name + ".png")
        ask(self.w, {"do": "window", "path": path})
        return path

    # ------------------------------------------------------------ B13 (a) focus rings

    def focused(self):
        """(frame in window points, who) of the element with the keyboard: the AX probe's answer when it can walk
        the window, else the in-process tree (None, None without one)."""
        if self.ax:
            f = ax.ask({"do": "focused", "pid": self.w.pid}).get("focused") or {}
            return f.get("frame"), {k: f[k] for k in ("role", "subrole", "description", "title", "titleElement", "placeholder") if f.get(k)}
        for e in self.w.j("ai", "ax").get("elements", []):
            if e.get("focused"):
                return e.get("frame"), {"role": e.get("role"), "label": e.get("label") or e.get("title")}
        return None, None

    def press(self, shift=False):
        """Tab / ⇧Tab: a real key at the HID tap from the AX probe when trusted, else `bench ai key` (first responder)."""
        if self.ax:
            ax.ask({"do": "key", "key": "tab", "mods": ["shift"] if shift else []})
            return {}
        return self.w.j("ai", "key", "shift-tab" if shift else "tab")

    def walk(self, surface, steps):
        """Tab through one surface: who has the keyboard after each press, and whether a ring is drawn
        (pixels on the focused control's edge that moved against the picture before any Tab)."""
        base = prev = self.snap(f"{surface}-00")
        scale = png_width(base) / 1440
        rows = []
        for i in range(1, steps + 1):
            r = self.press(); time.sleep(0.3)
            pic = self.snap(f"{surface}-{i:02d}")
            f = self.w.j("settings", "ax", "focus")
            frame, who = self.focused()
            ring = None
            if frame and frame[2] > 0:
                x, y, fw, fh = (int(v * scale) for v in frame)
                ring = (pix("diff", base, pic, x, y, fw, fh, int(4 * scale)) or {}).get("changed")
            moved = (pix("diff", prev, pic) or {}).get("changed")
            rows.append({"step": i, "firstResponder": r.get("firstResponder"), "focused": f.get("focused"), "control": f.get("control"),
                         "frame": frame, "axFocus": who, "ring": ring, "moved": moved})
            prev = pic
        back = []
        for i in range(1, 3):  # ⇧Tab twice, each pictured: the ring must walk back
            r = self.press(shift=True); time.sleep(0.3)
            self.snap(f"{surface}-back{i}")
            back.append(self.focused()[1] if self.ax else r.get("focused"))
        stops = {json.dumps([x["firstResponder"], x["focused"]], sort_keys=True) for x in rows}
        ringed = sum(1 for x in rows if (x["ring"] or 0) >= 0.03 or (x["ring"] is None and (x["moved"] or 0) > 0))
        ok = len(stops) >= 3 and ringed == len(rows)
        self.rec(f"Tab walks {surface}: distinct stops, each with a visible ring", ok,
                 f"{len(stops)} distinct stops in {steps} presses; ring or visible change on {ringed}/{steps}; "
                 f"⇧Tab back → {[(b or {}).get('role') for b in back]}" + (" (AX probe: HID keys, AX focus)" if self.ax else ""))
        return {"surface": surface, "steps": rows, "distinct": len(stops), "ringed": ringed, "back": back}

    # ------------------------------------------------------------ B13 (d) VoiceOver names

    def ax_surface(self, name):
        """Every control the AX tree has on screen now (role + the name VoiceOver reads), and the unnamed ones.
        From the AX probe (a real accessibility client, every window of the app) when it can; else in process."""
        if self.ax:
            t = ax.ask({"do": "tree", "pid": self.w.pid}, 90)
            els = [dict(e, window=wd.get("title") or wd.get("subrole")) for wd in t.get("windows", []) for e in wd["elements"]]
            controls = [e for e in els if e.get("role") in CONTROLS]
            unnamed = [e for e in controls if not ax_name(e) and e.get("subrole") not in LIGHTS]
            return {"surface": name, "source": "axprobe", "windows": len(t.get("windows", [])), "elements": len(els),
                    "controls": len(controls), "truncated": t.get("truncated"),
                    "unnamed": [{k: e.get(k) for k in ("role", "subrole", "value", "help", "identifier", "frame", "window")} for e in unnamed],
                    "named": [[e.get("role"), e.get("subrole"), ax_name(e), e.get("window")] for e in controls]}
        els = self.w.j("ai", "ax").get("elements", [])
        if len(els) <= 1:
            return {"surface": name, "elements": len(els), "controls": None, "unnamed": None,
                    "note": f"n/a: {self.ax_blocker or 'no AX tree'} (in process: `bench ai ax` → {len(els)} element; "
                            "SwiftUI builds the tree only for a real accessibility client)"}
        controls = [e for e in els if e.get("role") in CONTROLS]
        # The traffic lights carry no label; VoiceOver names them by subrole, which `ai ax` doesn't return.
        unnamed = [e for e in controls if not (e.get("label") or e.get("title"))
                   and not (e.get("role") == "AXButton" and e["frame"][0] < 90 and e["frame"][1] < 40 and e["frame"][2] < 24)]
        return {"surface": name, "elements": len(els), "controls": len(controls),
                "unnamed": [{k: e.get(k) for k in ("role", "value", "help", "frame")} for e in unnamed]}


# ---------------------------------------------------------------- B14 motion

def record(run, name, trigger, seconds=1.2, cap=24):
    """Frame 000 before the trigger, then `bench window` pictures as fast as they come for SECONDS."""
    d = os.path.join(run.out, "motion", name)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    frames, stamps = [], []
    def grab():
        p = os.path.join(d, f"{len(frames):03d}.png")
        ask(run.w, {"do": "window", "path": p})
        frames.append(p)
    grab(); stamps.append(0)
    answer = {}
    # The trigger on its own thread: some verbs answer only after a settle, and the frames must not wait for it.
    th = threading.Thread(target=lambda: answer.update(trigger() or {}))
    t0 = time.time()
    th.start()
    while time.time() - t0 < seconds and len(frames) < cap:
        grab(); stamps.append(round((time.time() - t0) * 1000))
    th.join(30)
    seq = pix("seq", "--fuzz", 6, *frames) or []  # 6/255: hover fills and fades are faint
    still = len(frames) - 1  # the first frame from which every later one matches the last
    for i in range(len(seq) - 1, 0, -1):
        if seq[i]["last"] > 0.001:
            break
        still = i
    row = {"name": name, "frames": len(frames), "span_ms": stamps[-1], "stable_frame": still, "stable_ms": stamps[still] if seq else None,
           "moved": seq[0]["last"] if seq else None, "ms": stamps, "steps": [s["prev"] for s in seq]}
    if answer.get("error"):
        row["note"] = f"trigger: {answer['error']}"
    elif "summoning" in answer:  # the ⎋ hook says whether the bar is still up
        n = answer.get("presses", 1)
        row["note"] = f"⌘K still open after {n} ⎋" if answer["summoning"] else f"⌘K closed after {n} ⎋"
    pix("sheet", os.path.join(d, "sheet.png"), 6, 320, *frames)
    if shutil.which("ffmpeg"):
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "15", "-i", os.path.join(d, "%03d.png"),
                        "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", os.path.join(d, name + ".mp4")])
    print(f"motion {name}: {row['frames']} frames over {row['span_ms']} ms, still from frame {still} ({row['stable_ms']} ms), moved {row['moved']}", flush=True)
    return row


def reduce_motion():
    """System Settings › Accessibility › Display › Reduce motion, as a freshly launched app reads it."""
    r = subprocess.run(["osascript", "-l", "JavaScript", "-e",
                        'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion'],
                       capture_output=True, text=True)
    return {"true": True, "false": False}.get(r.stdout.strip())


def set_reduce_motion(on):
    subprocess.run(["defaults", "write", "com.apple.universalaccess", "reduceMotion", "-bool", "true" if on else "false"],
                   capture_output=True)
    time.sleep(0.5)
    return reduce_motion() == on


def motion(run, art, docs, rm=False):
    """B14 recordings. rm=True: the Reduce Motion pass (names end in -rm): only what Reduce Motion should change."""
    w, rows, sfx = run.w, [], "-rm" if rm else ""
    calm(w); w.b("ui", "sidebar", "on"); w.b("select", art); time.sleep(1)

    def open_bar():  # ⌘K toggles: press again if the hook check left the bar open and the press closed it
        for _ in range(2):
            w.b("key", art, "⌘K", "--app"); time.sleep(0.8)
            if w.j("probe").get("summoning"):
                return

    def esc_close():  # ⎋ until the bar is gone (the first may only clear the pick), so the close itself is recorded
        a = ask(w, {"do": "summon", "text": "", "keys": "⎋"})
        if a.get("summoning"):
            a = dict(ask(w, {"do": "summon", "text": "", "keys": "⎋"}), presses=2)
        return a

    if rm:
        rows.append(record(run, "space-switch" + sfx, lambda: ask(w, {"do": "spaces", "op": "select", "arg": "1"})))
        w.b("spaces", "select", "0"); time.sleep(1.2); w.b("select", art); time.sleep(0.5)
        rows.append(record(run, "cmdk-open" + sfx, lambda: ask(w, {"do": "key", "id": art, "text": "⌘K", "via": "app"})))
        if run.hook("summon", "", "--keys", "⎋", needs="summoning")[0] is not None:
            open_bar()
            rows.append(record(run, "cmdk-close" + sfx, esc_close))
        calm(w); w.b("select", art); time.sleep(0.6)
        rows.append(record(run, "split-create" + sfx, lambda: ask(w, {"do": "split", "arg": docs}), seconds=1.5))
        w.b("split", "off"); time.sleep(0.8)
        for r in rows:
            r["reduceMotion"] = True
        return rows
    rows.append(record(run, "space-switch", lambda: ask(w, {"do": "spaces", "op": "select", "arg": "1"})))
    w.b("spaces", "select", "0"); time.sleep(1.2); w.b("select", art); time.sleep(0.5)
    # The slide held at fixed points (SpaceSlide `bench slide at X`): the in-between frames, exactly.
    held = os.path.join(run.out, "motion", "space-slide-held"); shutil.rmtree(held, ignore_errors=True); os.makedirs(held)
    frames = []
    for i, x in enumerate((0.0, 0.25, 0.5, 0.75, 1.0)):
        w.b("spaces", "slide", "at", x); w.b("spaces", "select", "1"); time.sleep(0.4)
        frames.append(os.path.join(held, f"{i:03d}.png")); ask(w, {"do": "window", "path": frames[-1]})
        w.b("spaces", "slide", "off"); time.sleep(0.5); w.b("spaces", "select", "0"); time.sleep(1.2)
    pix("sheet", os.path.join(held, "sheet.png"), 5, 320, *frames)
    steps = pix("seq", *frames) or []
    rows.append({"name": "space-slide-held", "frames": len(frames), "held_at": [0, 0.25, 0.5, 0.75, 1],
                 "steps": [s["prev"] for s in steps], "note": "phase pinned per frame; steps = pixels moved from the previous point"})
    w.b("select", art); time.sleep(0.6)
    rows.append(record(run, "cmdk-open", lambda: ask(w, {"do": "key", "id": art, "text": "⌘K", "via": "app"})))
    a, why = run.hook("summon", "", "--keys", "⎋", needs="summoning")
    if a is None:
        rows.append({"name": "cmdk-close", "note": why})
    else:
        open_bar()
        rows.append(record(run, "cmdk-close", esc_close))
    calm(w); w.b("select", art); time.sleep(0.6)
    rows.append(record(run, "split-create", lambda: ask(w, {"do": "split", "arg": docs}), seconds=1.5))
    w.b("split", "off"); time.sleep(0.8); w.b("select", art); time.sleep(0.4)
    hn = tab_id(w, "Hacker News")
    rows.append(record(run, "tab-hover", lambda: ask(w, {"do": "sections", "op": "hover", "arg": hn}), seconds=0.8))
    w.b("sections", "hover", "off"); time.sleep(0.5)
    # Pressed: the row picked up and held 40 pt lower by real mouse events (SideHand), then let go.
    rows.append(record(run, "tab-press-drag", lambda: ask(w, {"do": "sections", "op": "drag", "arg": f"{hn} 40 8 hold"}), seconds=0.8))
    w.b("sections", "release"); time.sleep(0.8)
    for r in rows:
        r["reduceMotion"] = False
    return rows


# ---------------------------------------------------------------- the run

def front_app():
    out = subprocess.run("lsappinfo info -only name \"$(lsappinfo front)\"", shell=True, capture_output=True, text=True).stdout
    m = re.search(r'"([^"]+)"', out)
    return m.group(1) if m else "?"


def global_default(key):
    r = subprocess.run(["defaults", "read", "-g", key], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def main():
    label, app, out = sys.argv[1], os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3])
    if subprocess.run("pmset -g ps | grep -q InternalBattery", shell=True).returncode == 0:
        sys.exit("keywin puts a window on the screen: the mini only (this Mac has a battery: someone's laptop)")
    os.makedirs(os.path.join(out, "logs"), exist_ok=True)
    front = front_app()
    try:  # the AX probe (ax.py): a real accessibility client in the GUI session; it also knows if the screen is locked
        axst = ax.start()
        blocker = ax.why_not(axst)
    except Exception as e:
        axst, blocker = {}, f"AX probe didn't start: {str(e)[:160]}"
    locked = axst["locked"] if isinstance(axst.get("locked"), bool) else front == "loginwindow"
    rm0 = reduce_motion()
    env = {"front": front, "screenLocked": locked, "AppleActionOnDoubleClick": global_default("AppleActionOnDoubleClick"),
           "AppleKeyboardUIMode": global_default("AppleKeyboardUIMode"), "reduceMotion": rm0,
           "axProbe": {k: axst.get(k) for k in ("trusted", "locked", "front", "fullKeyboardAccess")}, "axBlocker": blocker}
    rm_set = False
    tag = re.sub(r"[^a-z0-9-]", "", label.lower())[:20] or "x"
    w = World(f"uxkw-{tag}", app, free_port(), os.path.join(out, "logs", "keywin.log"), windowed=True)
    fka_set = False
    report = {"label": label, "app": app, "env": env}
    started = time.time()
    try:
        # Full keyboard access (Tab reaches buttons) is read from the global domain; set only when a
        # key window is possible at all, and always put back.
        if not locked and env["AppleKeyboardUIMode"] not in ("2", "3"):
            subprocess.run(["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", "2"], check=True); fka_set = True
        w.reset([("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("probe.keychain", "-string", "file"),
                 ("sidebar", "-bool", "true"), ("look", "-string", "light")])
        seed_lived_in(w.folder)
        w.launch()
        run = Run(w, out)
        run.ax, run.ax_blocker = not blocker, blocker
        for i, c in enumerate(("Blue", "Green", "Teal"), 1):
            w.b("spaces", "colour", i, c)
        art, docs = tab_id(w, "Field Notes"), tab_id(w, "Spaces — Copper Docs")
        w.b("wait", art, 10); w.b("resize", 1440, 900, 1); time.sleep(1)
        if run.ax:
            env["raise"] = ax.ask({"do": "raise", "pid": w.pid})  # AXFrontmost + AXRaise: key even under cooperative activation
        run.snap("main-sidebar")  # `bench window` also activates the app and makes the window key, when macOS lets it
        p = w.j("probe")
        key = bool(p.get("key"))
        env.update(key=p.get("key"), keyboardNavigation=w.j("settings", "ax", "focus").get("keyboardNavigation"))
        why_not_key = "n/a: no key window — " + ("the Mac's screen is locked (loginwindow in front), so no app can be active"
                                                 if locked else f"{front} stays frontmost")

        # (a) focus rings on Copper's own controls
        walks = []
        if key:
            w.b("ui", "focus", "none")
            walks.append(run.walk("main", 16))
            w.b("summon", ""); time.sleep(0.6)
            walks.append(run.walk("cmdk", 4))
            w.b("select", art); w.b("settings", "open", "general"); time.sleep(1.2)
            walks.append(run.walk("settings-general", 10))
            w.b("settings", "close"); time.sleep(0.8)
        else:
            run.rec("Focus rings on Copper's own controls (Tab/⇧Tab: sidebar, address, buttons, ⌘K, Settings)", None, why_not_key)
        report["walks"] = walks

        # (b) ⎋ closes ⌘K: the real key (needs a key window), and the hook (presses Escape in the bar's field)
        w.b("select", art); time.sleep(0.4)
        if key:
            w.b("key", art, "⌘K", "--app"); time.sleep(0.6)
            opened = w.j("probe").get("summoning")
            w.b("ai", "key", "escape"); time.sleep(0.5)
            closed = not w.j("probe").get("summoning")
            run.rec("⌘K opens, a real ⎋ closes it (key window)", bool(opened and closed), f"open={opened} closed={closed}", cat="B4")
        a, why = run.hook("summon", "copper", "--keys", "⎋", needs="summoning")
        run.rec("⎋ in ⌘K closes the bar (hook: bench summon --keys ⎋)", None if a is None else a.get("summoning") is False,
                why or f"summoning after ⎋ = {a.get('summoning')}", cat="B4")
        calm(w); w.b("select", art); time.sleep(0.4)

        # (c) title-bar double-click does what System Settings says (AppleActionOnDoubleClick; unset = zoom)
        want = (env["AppleActionOnDoubleClick"] or "Maximize").lower()
        a = None
        for x, y in ((1000, 8), (1000, 14), (160, 10)):  # the strip above the page, then above the column
            a, why = run.hook("mouse", "double", x, y, needs="frameAfter")
            if a is None or a.get("frameAfter") != a.get("frameBefore") or a.get("miniaturized"):
                break
        if a is None:
            run.rec("Title-bar double-click zooms the window", None, why, cat="B5")
        else:
            did = "minimize" if a.get("miniaturized") else ("zoom" if a.get("frameAfter") != a.get("frameBefore") else "none")
            ok = did == {"maximize": "zoom", "fill": "zoom", "minimize": "minimize", "none": "none"}.get(want, "zoom")
            run.rec("Title-bar double-click does the System Settings action", ok,
                    f"setting={want} → {did}; {a.get('frameBefore')} → {a.get('frameAfter')} hit={a.get('hit')}", cat="B5")
            if did == "zoom":
                w.b("mouse", "double", x, y)
            w.b("resize", 1440, 900, 1); time.sleep(0.5)

        # (d) VoiceOver names per surface (the window's own AX tree, in process) + the Settings ledger
        surfaces = []
        def surf(name, on, off=None, settle=1.0):
            try:
                on(); time.sleep(settle)
                surfaces.append(run.ax_surface(name))
            except Exception as e:
                surfaces.append({"surface": name, "note": f"error: {str(e)[:160]}"})
            if off:
                try:
                    off(); time.sleep(0.6)
                except Exception:
                    pass
        surf("main-sidebar", lambda: w.b("ui", "sidebar", "on"))
        surf("main-top", lambda: w.b("ui", "sidebar", "off"), lambda: w.b("ui", "sidebar", "on"))
        surf("cmdk", lambda: w.b("summon", ""), lambda: calm(w))
        surf("newtab", lambda: w.b("newtab", "copper", "--keep", "--settle", "1"), lambda: calm(w))
        for page in ["general", "tabs", "spaces", "intelligence", "agents", "cloud", "extensions", "passwords", "privacy", "about"]:
            surf(f"settings-{page}", lambda: w.b("settings", "open", page), settle=1.2)
        w.b("settings", "close"); time.sleep(0.8)
        surf("agent", lambda: w.b("agent", "open"), lambda: w.b("agent", "close"))
        for panel in ("history", "downloads", "bookmarks", "passwords"):
            surf(f"{panel}-panel", lambda: w.b("ui", panel, "on"), lambda: w.b("ui", panel, "off"))
        report["ax"] = surfaces
        tree = [s for s in surfaces if s.get("controls") is not None]
        run.rec("VoiceOver: unnamed controls per surface (AX tree)", (sum(len(s["unnamed"]) for s in tree) == 0) if tree else None,
                f"{sum(len(s['unnamed']) for s in tree)} unnamed of {sum(s['controls'] for s in tree)} controls on {len(tree)} surfaces"
                + (" (AX probe)" if run.ax else "")
                if tree else f"n/a: no AX tree on any of {len(surfaces)} surfaces — {blocker or 'in process: `bench ai ax` → 1 element'}")
        try:
            sweep = w.j("settings", "ax", "sweep", timeout=120)
            report["sweep"] = sweep
            pages = sweep.get("pages", {})
            run.rec("VoiceOver: every Settings control named and reachable (settings ax sweep, the controls' own ledger)", bool(sweep.get("ok")),
                    f"{sweep.get('controls')} controls on {len(pages)} pages; unnamed {len(sweep.get('unnamed', []))}, "
                    f"unreachable {len(sweep.get('unreachable', []))}")
        except Exception as e:
            run.rec("VoiceOver: Settings ledger sweep", None, f"n/a: {str(e)[:160]}")
        w.b("settings", "close"); time.sleep(0.8)

        # Welcome in a windowed world (headless suppresses it unless the hook build lets the bench ask).
        shown = welcome(w, lambda n: run.snap(n))
        report["welcome"] = shown
        run.rec("Welcome shows on `bench ui welcome on`", True if shown["pages"] else None,
                f"{shown['pages']} page(s) pictured: {', '.join(shown['files'])}" if shown["pages"] else shown["note"], cat="B1")

        # B14 motion: Reduce Motion off (all recordings), then on (what it should change); the Mac's setting put back
        report["motion"] = []
        for on in (False, True):
            if rm0 is None:
                report["motion"].append({"name": "reduce-motion", "note": "n/a: can't read Reduce Motion here"}); break
            if reduce_motion() != on:
                rm_set = True
                if not set_reduce_motion(on):
                    report["motion"].append({"name": "rm-" + ("on" if on else "off"), "note": "n/a: couldn't set Reduce Motion"}); continue
                w.quit(); w.launch()  # the app reads it at launch
                art, docs = tab_id(w, "Field Notes"), tab_id(w, "Spaces — Copper Docs")
                w.b("wait", art, 10); w.b("resize", 1440, 900, 1); time.sleep(1)
                if run.ax:
                    ax.ask({"do": "raise", "pid": w.pid})
            report["motion"] += motion(run, art, docs, rm=on)
        report["checks"] = run.checks
    finally:
        w.drop()
        if rm_set:
            set_reduce_motion(rm0)
        if fka_set:
            prior = env["AppleKeyboardUIMode"]
            subprocess.run(["defaults", "delete", "-g", "AppleKeyboardUIMode"] if prior is None else
                           ["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", prior], capture_output=True)
        report["seconds"] = round(time.time() - started)
        json.dump(report, open(os.path.join(out, "keywin.json"), "w"), indent=1)
        if "motion" in report:
            json.dump(report["motion"], open(os.path.join(out, "motion.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
