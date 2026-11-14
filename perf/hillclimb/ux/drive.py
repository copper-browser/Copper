#!/usr/bin/env python3
"""Track B evidence pack: pictures of every Copper surface + scripted keyboard checks.

    python3 drive.py LABEL APP OUTDIR

Runs on a Mac (Retina laptop for the real thing). Two fresh headless probe
worlds of APP (never the installed Copper, never port 4123): a first-run world
(nothing in it) and a lived-in world seeded from ux/seed (spaces, pins,
folders, history, bookmarks, icons — no network needed for the sidebar).
Every picture is `bench canvas picture` (the window + its sheets/popovers,
drawn by the app itself, so nothing is brought forward). Names are
`<surface>-<theme>-<size>.png`, so another build's set pairs 1:1.
Writes OUTDIR/shots/*.png, OUTDIR/shots.json, OUTDIR/keys.json.
"""
import hashlib, json, os, re, shutil, signal, socket, subprocess, sys, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
SITE_PORT = int(os.environ.get("UX_SITE_PORT", "4149"))
SITE = f"http://127.0.0.1:{SITE_PORT}"
SIZES = {"1440": (1440, 900), "full": (1728, 1117), "900": (900, 700), "1100": (1100, 720)}  # full = the M1 Pro's whole screen in points; 900/1100 = narrow windows
THEMES = ["light", "dark"]
ONLY = set(filter(None, os.environ.get("UX_ONLY", "").split(",")))  # e.g. UX_ONLY=cmdk-sidebar,split-top for a quick rerun


def find_bench():
    for p in [os.environ.get("BENCH"), os.path.join(HERE, "../../../bench"), os.path.expanduser("~/hc/bin/bench")]:
        if p and os.path.isfile(p):
            return os.path.abspath(p)
    sys.exit("no bench script: set BENCH=/path/to/Copper/bench")


BENCH = find_bench()


class World:
    def __init__(self, name, app, port, log, windowed=False, args=()):
        self.name, self.app, self.port, self.log, self.pid = name, app, port, log, None
        self.windowed, self.args = windowed, list(args)  # windowed: a real window on the screen (key-window run, mini only)
        self.label = f"hc.ux.{name}"
        self.folder = os.path.expanduser(f"~/Library/Application Support/Copper ({name})")
        self.suite = f"com.collinrijock.copper.test.{name}"

    def b(self, *args, timeout=60):
        r = subprocess.run([sys.executable, BENCH, "--world", self.name, *map(str, args)],
                           capture_output=True, text=True, timeout=timeout)
        if r.returncode:
            raise RuntimeError(f"bench {' '.join(map(str, args))}: {r.stderr.strip() or r.stdout.strip()}")
        return r.stdout

    def j(self, *args, **kw):
        out = self.b(*args, **kw)
        try:
            return json.loads(out)
        except ValueError:
            return {"text": out}

    def reset(self, defaults):
        self.quit()
        shutil.rmtree(self.folder, ignore_errors=True)
        subprocess.run(["defaults", "delete", self.suite], capture_output=True)
        for key, kind, value in defaults:
            subprocess.run(["defaults", "write", self.suite, key, kind, value], check=True)
        os.makedirs(self.folder, exist_ok=True)

    def launch(self, size="1440x900"):
        assert self.port != 4123
        open(self.log, "w").close()
        if self.windowed:
            return self.launch_agent()
        subprocess.run(["open", "-n", "-g", "--stderr", self.log, "--env", f"SEARCH_PROBE={self.name}",
                        "--env", "SEARCH_HEADLESS=1", "--env", f"SEARCH_MCP_PORT={self.port}",
                        "--env", f"SEARCH_HEADLESS_SIZE={size}", self.app], check=True)
        for _ in range(120):
            m = re.search(r"on — pid (\d+)", open(self.log).read())
            if m:
                self.pid = int(m.group(1))
                try:
                    self.b("probe", timeout=5)
                    return
                except Exception:
                    pass
            time.sleep(0.5)
        raise RuntimeError(f"probe {self.name} did not come up (log {self.log})")

    def launch_agent(self):
        """A LaunchAgent in the GUI session (gui/UID): over ssh only launchd gives
        an app a window server session it can put a key window in."""
        plist = f"/tmp/{self.label}.plist"
        env = "".join(f"<key>{k}</key><string>{v}</string>" for k, v in
                      {"SEARCH_PROBE": self.name, "SEARCH_MCP_PORT": self.port}.items())
        prog = "".join(f"<string>{a}</string>" for a in [f"{self.app}/Contents/MacOS/Copper", *self.args])
        with open(plist, "w") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
                    f"<key>Label</key><string>{self.label}</string><key>EnvironmentVariables</key><dict>{env}</dict>"
                    "<key>KeepAlive</key><false/><key>RunAtLoad</key><true/>"
                    "<key>LimitLoadToSessionType</key><string>Aqua</string>"
                    f"<key>ProgramArguments</key><array>{prog}</array>"
                    f"<key>StandardErrorPath</key><string>{self.log}</string>"
                    f"<key>StandardOutPath</key><string>{self.log}</string></dict></plist>")
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{self.label}"], capture_output=True)
        subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", plist], check=True)
        for _ in range(120):
            m = re.search(r'"PID" = (\d+);', subprocess.run(["launchctl", "list", self.label], capture_output=True, text=True).stdout)
            if m:
                self.pid = int(m.group(1))
                try:
                    self.b("probe", timeout=5)
                    return
                except Exception:
                    pass
            time.sleep(0.5)
        raise RuntimeError(f"windowed probe {self.name} did not come up (log {self.log})")

    def quit(self):
        if self.windowed:
            subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{self.label}"], capture_output=True)
            self.pid = None
            time.sleep(1)
            return
        if not self.pid:
            return
        try:
            cmd = subprocess.run(["ps", "-p", str(self.pid), "-o", "command="], capture_output=True, text=True).stdout
            if self.app in cmd:  # only our own probe process
                os.kill(self.pid, signal.SIGTERM)
                for _ in range(40):
                    os.kill(self.pid, 0)
                    time.sleep(0.25)
                os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.pid = None
        time.sleep(1)

    def drop(self):
        self.quit()
        shutil.rmtree(self.folder, ignore_errors=True)
        subprocess.run(["defaults", "delete", self.suite], capture_output=True)
        try:
            os.remove(os.path.expanduser(f"~/Library/Preferences/{self.suite}.plist"))
        except FileNotFoundError:
            pass


PORTS = [int(p) for p in os.environ.get("UX_PORTS", "4140-4148").split("-")]  # a worker's own range, e.g. UX_PORTS=4231-4232


def free_port():
    for port in range(PORTS[0], PORTS[-1] + 1):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)):
                return port
    sys.exit(f"no free port in {PORTS[0]}–{PORTS[-1]}")


# ---------------------------------------------------------------- seeding

def seed_lived_in(folder):
    """A believable 3-space session that needs no network: real hosts asleep
    with their icons pre-cached, the page on screen served locally."""
    now = time.time()
    spaces = [{"name": "Personal", "id": str(uuid.uuid4()).upper()},
              {"name": "Work", "id": str(uuid.uuid4()).upper()},
              {"name": "Side project", "id": str(uuid.uuid4()).upper()},
              {"name": "Travel", "id": str(uuid.uuid4()).upper()}]  # left empty: the empty-space state
    P, W, S = (s["id"] for s in spaces[:3])
    groups = [{"name": "Reading", "id": str(uuid.uuid4()).upper(), "hue": 0.08, "collapsed": False},
              {"name": "Projects › Copper", "id": str(uuid.uuid4()).upper(), "hue": 0.6, "collapsed": False}]
    G_READ, G_COPPER = groups[0]["id"], groups[1]["id"]

    def t(title, url, space, saved, group=None, active=None):
        e = {"title": title, "url": url, "space": space, "saved": saved, "seen": now}
        if group: e["group"] = group
        if active: e["active"] = True
        return e
    tabs = [
        t("YouTube", "https://www.youtube.com/", P, True),
        t("Copper — Wikipedia", "https://en.wikipedia.org/wiki/Copper", P, True, G_READ),
        t("Hacker News", "https://news.ycombinator.com/", P, True, G_READ),
        t("Field Notes — The Copper Journal", f"{SITE}/article.html", P, False, active=True),
        t("Spaces — Copper Docs", f"{SITE}/docs.html", P, False),
        t("Sign in — Fixture Mail", f"{SITE}/login.html", P, False),
        t("Human Interface Guidelines: Designing for macOS, sidebars, toolbars and everything in between",
          "https://developer.apple.com/design/human-interface-guidelines/designing-for-macos", P, False),
        t("Apple", "https://www.apple.com/", P, False),
        t("copper-browser/Copper", "https://github.com/copper-browser/Copper", W, True, G_COPPER),
        t("Linear", "https://linear.app/", W, True, G_COPPER),
        t("Roadmap", "https://www.notion.so/", W, True),
        t("Pull requests", "https://github.com/pulls", W, False),
        t("Figma", "https://www.figma.com/", S, True),
        t("Apple Developer", "https://developer.apple.com/", S, False),
    ]
    pins = [{"title": "Gmail", "url": "https://mail.google.com/mail/u/0/", "pin": "G", "space": P, "seen": now},
            {"title": "Google Calendar", "url": "https://calendar.google.com/", "pin": "C", "space": P, "seen": now},
            {"title": "GitHub", "url": "https://github.com/", "pin": "H", "space": P, "seen": now}]
    active = next(i for i, e in enumerate(tabs) if e.get("active"))
    shape = {"tabs": tabs, "active": active, "spaces": spaces, "space": P, "pins": pins}
    json.dump(shape, open(os.path.join(folder, "session.json"), "w"))
    json.dump({"groups": groups}, open(os.path.join(folder, "groups.json"), "w"))
    # history.json: [Visit{url,key,title,count,last}], dates as seconds since 2001 (JSONEncoder's default)
    ref = now - 978307200
    visits = [(f"{SITE}/article.html", "Field Notes — The Copper Journal", 9),
              (f"{SITE}/docs.html", "Spaces — Copper Docs", 6),
              ("https://en.wikipedia.org/wiki/Copper", "Copper — Wikipedia", 4),
              ("https://news.ycombinator.com/", "Hacker News", 12),
              ("https://github.com/copper-browser/Copper", "copper-browser/Copper", 7),
              ("https://developer.apple.com/design/human-interface-guidelines/", "Human Interface Guidelines", 3),
              ("https://www.apple.com/", "Apple", 2), ("https://linear.app/", "Linear", 5)]

    def key(url):
        k = re.sub(r"^https?://", "", url.lower())
        return k[4:] if k.startswith("www.") else k
    json.dump([{"url": u, "key": key(u), "title": ti, "count": c, "last": ref - 3600 * i}
               for i, (u, ti, c) in enumerate(visits)], open(os.path.join(folder, "history.json"), "w"))
    bm = lambda title, url=None, kids=None: {k: v for k, v in {"id": str(uuid.uuid4()).upper(), "title": title, "url": url, "children": kids}.items() if v is not None}
    json.dump([bm("Copper Journal", f"{SITE}/article.html"), bm("Copper Docs", f"{SITE}/docs.html"),
               bm("Design", kids=[bm("Human Interface Guidelines", "https://developer.apple.com/design/human-interface-guidelines/"),
                                  bm("Figma", "https://www.figma.com/")]),
               bm("Hacker News", "https://news.ycombinator.com/")], open(os.path.join(folder, "bookmarks.json"), "w"))
    icons = os.path.join(HERE, "seed", "icons")
    if os.path.isdir(icons):
        shutil.copytree(icons, os.path.join(folder, "icons"), dirs_exist_ok=True)
    # What ⌘1…⌘9 should reach: the column top to bottom, pins first; ⌘9 = the last.
    personal = [e["title"] for e in tabs if e["space"] == P and e["saved"] and not e.get("group")] + \
               [e["title"] for e in tabs if e["space"] == P and e.get("group") == G_READ] + \
               [e["title"] for e in tabs if e["space"] == P and not e["saved"]]
    return [f"[{p['pin']}]" for p in pins] + personal  # pins show as "[G] title" in `bench tabs`


def seed_narrow(folder):
    """The lived-in seed with 8 spaces and long tab titles: what a narrow window has to fit."""
    seed_lived_in(folder)
    path = os.path.join(folder, "session.json")
    shape = json.load(open(path))
    shape["spaces"] += [{"name": n, "id": str(uuid.uuid4()).upper()} for n in ("Reading list", "Home renovation", "Taxes 2026", "Recipes")]
    now, P = time.time(), shape["space"]
    for title in ("The Complete Guide to Keyboard Navigation, Focus Rings and VoiceOver Labels in Native macOS Apps (2026 Edition)",
                  "Quarterly planning — Product roadmap, hiring plan and budget review for the second half of the year",
                  "Why every browser tab bar eventually becomes a sidebar: a long essay with far too many footnotes",
                  "Pull request #4821: Make the command bar remember the last query across windows and spaces"):
        shape["tabs"].append({"title": title, "url": f"{SITE}/docs.html?t={len(shape['tabs'])}", "space": P, "saved": False, "seen": now})
    json.dump(shape, open(path, "w"))


def arc_fixture(root):
    """A made-up Arc profile for Move in (never this Mac's Arc)."""
    os.makedirs(os.path.join(root, "User Data", "Default"), exist_ok=True)
    json.dump({"profile": {"name": "Default"}}, open(os.path.join(root, "User Data", "Default", "Preferences"), "w"))
    items = [{"id": "P1", "childrenIds": [], "data": {}}, {"id": "U1", "childrenIds": ["T1", "T2", "T3"], "data": {}}]
    for i, (title, url) in enumerate([("Beta", "https://beta.invalid/one"), ("Gamma", "https://gamma.invalid/"),
                                      ("Delta", "https://delta.invalid/")], 1):
        items.append({"id": f"T{i}", "title": title, "childrenIds": [], "data": {"tab": {"savedURL": url, "savedTitle": title}}})
    json.dump({"sidebar": {"containers": [{"global": {}}, {"spaces": [{"id": "S1", "title": "Research",
               "containerIDs": ["pinned", "P1", "unpinned", "U1"]}], "items": items, "topAppsContainerIDs": []}]}},
              open(os.path.join(root, "StorableSidebar.json"), "w"))
    return os.path.join(root, "User Data")


# ---------------------------------------------------------------- pictures

class Shooter:
    def __init__(self, out):
        self.out, self.rows = out, []
        os.makedirs(os.path.join(out, "shots"), exist_ok=True)

    def take(self, w, surface, sizes=("1440", "full"), themes=THEMES, settle=1.0):
        """Every theme × size of SURFACE; answers the first picture's path."""
        if ONLY and surface not in ONLY:
            return None
        first = None
        for theme in themes:
            w.b("ui", "look", theme)
            for size in sizes:
                W, H = SIZES[size]
                w.b("resize", W, H, 1)
                time.sleep(settle)
                name = f"{surface}-{theme}-{size}.png"
                path = os.path.join(self.out, "shots", name)
                first = first or path
                row = {"file": name, "surface": surface, "theme": theme, "size": size}
                try:
                    pic = w.j("canvas", "picture", path)
                    row.update(ok=bool(pic.get("path")), px=pic.get("size"), extras=pic.get("extras", []))
                except Exception as e:  # one surface failing must not end the run
                    row.update(ok=False, error=str(e)[:300])
                self.rows.append(row)
                print(("ok  " if row["ok"] else "FAIL") + " " + name, flush=True)
        w.b("ui", "look", "light")
        w.b("resize", *SIZES["1440"], 1)
        return first

    def skip(self, surface, why):
        if not ONLY or surface in ONLY:
            self.rows.append({"file": None, "surface": surface, "ok": False, "skipped": why})
            print(f"skip {surface}: {why}", flush=True)


def step(label, fn):
    """Run one surface's setup; a failure is recorded, the run goes on."""
    try:
        fn()
        return True
    except Exception as e:
        print(f"FAIL {label}: {e}", flush=True)
        return False


def first_run(w, shoot, tmp):
    """Fresh world: what someone sees in the first minute (B1, B7/B11 empty states)."""
    shoot.take(w, "firstrun-window")
    shown = welcome(w, lambda name: shoot.take(w, name, sizes=("1440",)))
    if not shown["pages"]:
        shoot.skip("welcome", shown["note"])
    def movein():
        root = arc_fixture(os.path.join(tmp, "arc"))
        w.b("flow", "limit", "--only", "Arc")
        w.b("flow", "root", "--source", "Arc", "--path", root)
        w.b("flow", "open")
        for _ in range(60):
            st = w.j("flow", "state")
            if st.get("showing") and st.get("phase") == "preview":
                break
            time.sleep(0.25)
    if step("movein", movein):
        shoot.take(w, "movein-preview", settle=1.2)
        def done():
            w.b("flow", "choose", "--only", "tabs,bookmarks,history")
            w.b("flow", "key", "return")
            for _ in range(80):
                if w.j("flow", "state").get("phase") == "done":
                    return
                time.sleep(0.25)
            raise RuntimeError("Move in never reached done")
        if step("movein-done", done):
            shoot.take(w, "movein-done", settle=1.2)
        w.b("flow", "close"); time.sleep(1)
    for panel in ("history", "downloads", "bookmarks", "passwords"):
        w.b("ui", panel, "on"); time.sleep(1.2)
        shoot.take(w, f"{panel}-empty", sizes=("1440",))
        w.b("ui", panel, "off"); time.sleep(1.2)


PIX = os.environ.get("UX_PIX", os.path.expanduser("~/hc/bin/ux-pix"))
WELCOME = ["hello", "bring", "hold", "links"]  # Welcome.swift's four pages


def same_picture(a, b):
    """True when two pictures match (ux-pix if built, else the bytes)."""
    if not (a and b and os.path.exists(a) and os.path.exists(b)):
        return False
    if os.path.exists(PIX):
        r = subprocess.run([PIX, "diff", a, b], capture_output=True, text=True).stdout
        return json.loads(r or "{}").get("changed", 1) < 0.001
    return hashlib.md5(open(a, "rb").read()).digest() == hashlib.md5(open(b, "rb").read()).digest()


def welcome(w, snap):
    """Every Welcome page (B1) via `bench ui welcome on`; headless worlds drop it unless the build has the
    hc/hooks welcome hook. Pages advance by a click on Continue only (never Bring in / Make default)."""
    w.b("ui", "welcome", "on"); time.sleep(1.5)
    if not w.j("probe").get("welcome"):
        return {"pages": 0, "files": [], "note": "n/a: hook missing (needs hc/hooks) — headless worlds suppress Welcome"}
    files, prev, note = [], None, ""
    for i, page in enumerate(WELCOME):
        path = snap(f"welcome-{page}")
        if same_picture(prev, path):
            note = f"Continue (a click at its spot) didn't reach page {i + 1}"
            break
        files.append(f"welcome-{page}"); prev = path
        if i < len(WELCOME) - 1:
            win = next(x for x in w.j("probe")["windows"] if x["kind"] == "AppKitWindow" and x["visible"])
            W, H = win["frame"][2], win["frame"][3]
            w.b("ai", "click", W / 2 + 216, H - 57)  # Continue: the right end of the 520-pt foot, 40 pt off the bottom (Welcome.swift)
            time.sleep(1.2)
    w.b("ui", "welcome", "off"); time.sleep(1)
    return {"pages": len(files), "files": files, "note": note}


def calm(w):
    """Close ⌘K / ⌘T without a key window (a posted ⎋ never lands): `newtab` without --keep ends in Browser.dismiss()."""
    w.b("newtab", "", "--settle", "0.05"); time.sleep(0.8)


def tab_id(w, title_start):
    for line in w.b("tabs").splitlines():
        m = re.match(r"^[●⚗ ]*\s*([0-9a-f]{8})\s+(.*)$", line)
        if m and m.group(2).startswith(title_start):
            return m.group(1)
    raise RuntimeError(f"no tab titled {title_start!r}")


def lived_in(w, shoot):
    w.b("spaces", "colour", "1", "Blue")
    w.b("spaces", "colour", "2", "Green")
    w.b("spaces", "colour", "3", "Teal")
    art = tab_id(w, "Field Notes")
    docs = tab_id(w, "Spaces — Copper Docs")
    w.b("wait", art, 10)
    time.sleep(1.5)

    for layout, on in (("sidebar", "on"), ("top", "off")):
        w.b("ui", "sidebar", on); time.sleep(0.8)
        shoot.take(w, f"main-{layout}")
        if step("cmdk", lambda: w.b("summon", "")):
            shoot.take(w, f"cmdk-{layout}")
        if step("cmdk-query", lambda: w.b("summon", "spa")):
            shoot.take(w, f"cmdk-query-{layout}", settle=1.5)
        w.b("ai", "key", "escape"); time.sleep(0.6)
        if step("newtab", lambda: w.b("newtab", "copper", "--keep", "--settle", "1.5")):
            shoot.take(w, f"newtab-suggest-{layout}", settle=1.2)
        w.b("ai", "key", "escape"); time.sleep(0.4)
        w.b("select", art); time.sleep(0.6)
        if step("split", lambda: w.b("split", docs)):
            time.sleep(1.5)
            shoot.take(w, f"split-{layout}")
            w.b("split", "off"); time.sleep(0.8)
        w.b("select", art)
    w.b("ui", "sidebar", "on"); time.sleep(0.8)

    w.b("ui", "addressHover", "on"); time.sleep(0.6)
    shoot.take(w, "address-hover", sizes=("1440",))
    w.b("ui", "addressHover", "off")

    # Spaces (B3): another space's tint, an empty space, the Space page.
    w.b("spaces", "select", "1"); time.sleep(1.2)
    shoot.take(w, "space-work")
    w.b("spaces", "select", "3"); time.sleep(1.2)
    shoot.take(w, "space-empty")
    w.b("spaces", "select", "0"); time.sleep(1.2)
    w.b("select", art)
    if step("space-page", lambda: w.b("spaces", "page")):
        time.sleep(1.2)
        shoot.take(w, "space-page", sizes=("1440",))
        w.b("spaces", "page", "close"); time.sleep(1)

    # Settings (B8): every page.
    for page in ["general", "tabs", "spaces", "intelligence", "agents", "cloud", "extensions", "passwords", "privacy", "about"]:
        if step(f"settings {page}", lambda: w.b("settings", "open", page)):
            time.sleep(1.4)
            shoot.take(w, f"settings-{page}", sizes=("1440",))
    w.b("settings", "close"); time.sleep(1)

    # Panels (B7), lived in. One download, from the local site; one saved login (file keychain).
    step("login", lambda: w.b("passwords", "add", "127.0.0.1", "sam@example.com", "fixture-not-a-secret"))
    step("download", lambda: w.b("downloads", "start", f"{SITE}/files/report-2026.zip"))
    time.sleep(3)
    for panel in ("history", "downloads", "bookmarks", "passwords"):
        w.b("ui", panel, "on"); time.sleep(1.4)
        shoot.take(w, f"{panel}-panel")
        w.b("ui", panel, "off"); time.sleep(1.2)

    # Updates + agents (B11, B12).
    if step("update pill", lambda: w.b("updates", "pill", "available")):
        shoot.take(w, "update-pill", sizes=("1440",))
        w.b("updates", "pill", "off")
    w.b("agent", "open"); time.sleep(1.2)
    shoot.take(w, "agent-empty")
    if step("agent chat", lambda: w.b("agent", "seed", "chat")):
        time.sleep(1.2)
        shoot.take(w, "agent-chat")
    if step("agent driver", lambda: w.b("agent", "seed", "driver")):
        time.sleep(1.2)
        shoot.take(w, "agent-driver")
    w.b("agent", "clear"); w.b("agent", "close"); time.sleep(1)
    if step("drive fake", lambda: w.b("drive", "fake", "Claude", "Booking a table", "--doing", "Reading the menu")):
        time.sleep(1.5)
        shoot.take(w, "agent-pill")
        w.b("drive", "unfake")
    w.b("agent", "close"); time.sleep(0.8)

    # Error state (B11): a page whose server refuses the connection.
    def error():
        e = w.b("open", "http://127.0.0.1:4148/").strip().split()[-1]
        time.sleep(2.5)
        w.b("select", e); time.sleep(1)
    if step("error", error):
        shoot.take(w, "error-refused")
    w.b("select", art)

    # Passwords (B6): the save offer after a typed sign-in. Last: the offer bar stays up.
    login = tab_id(w, "Sign in — Fixture Mail")
    def offer():
        w.b("select", login); w.b("go", login, f"{SITE}/login.html"); w.b("wait", login, 10); time.sleep(0.8)
        w.b("type", login, "#user", "alex@example.com")
        w.b("type", login, "#pass", "fixture-typed-not-a-secret")
        w.b("submit", login, "#f")
        time.sleep(2)
    if step("password-offer", offer):
        shoot.take(w, "password-offer")


def narrow(w, shoot):
    """Narrow windows (B2/B9): 900×700 and 1100×720, 8 spaces, long titles, both layouts, light + dark."""
    for i, c in enumerate(("Blue", "Green", "Teal", "Orange", "Indigo", "Pink", "Yellow"), 1):
        step(f"colour {i}", lambda: w.b("spaces", "colour", i, c))
    art = tab_id(w, "Field Notes")
    w.b("wait", art, 10); time.sleep(1)
    for layout, on in (("sidebar", "on"), ("top", "off")):
        w.b("ui", "sidebar", on); time.sleep(0.8)
        shoot.take(w, f"narrow-{layout}", sizes=("900", "1100"))
        if step("narrow cmdk", lambda: w.b("summon", "")):
            shoot.take(w, f"narrow-cmdk-{layout}", sizes=("900", "1100"))
        calm(w); w.b("select", art); time.sleep(0.6)
    w.b("ui", "sidebar", "on")


# ---------------------------------------------------------------- keyboard + findability (B4, B8, B10)

def checks(w, expected_order):
    res = []
    def rec(cat, name, ok, detail):
        res.append({"category": cat, "check": name, "pass": ok, "detail": detail})
        print(("PASS" if ok else ("N/A " if ok is None else "FAIL")) + f" {name}: {detail}", flush=True)
    active = lambda: w.j("probe").get("active")
    art = tab_id(w, "Field Notes")
    login = tab_id(w, "Sign in — Fixture Mail")
    w.b("ui", "sidebar", "on")
    w.b("wait", art, 10)

    # Tab inside a form field moves between fields; it must not switch tabs.
    for via, extra in (("app", ["--app"]), ("view", [])):
        try:
            w.b("select", login); w.b("go", login, f"{SITE}/login.html"); w.b("wait", login, 10); time.sleep(0.8)
            w.b("eval", login, "document.getElementById('user').focus()")
            w.b("key", login, "⇥", *extra); time.sleep(0.4)
            got, still = w.b("eval", login, "document.activeElement.id").strip(), active() == login
            rec("B10", f"Tab in a form field → next field ({via})", got == "pass" and still, f"focus={got!r} same tab={still}")
            w.b("key", login, "⇧⇥", *extra); time.sleep(0.4)
            got, still = w.b("eval", login, "document.activeElement.id").strip(), active() == login
            rec("B10", f"⇧Tab in a form field → previous field ({via})", got == "user" and still, f"focus={got!r} same tab={still}")
            if via == "app":  # keyboard focus on a button draws a ring (:focus-visible + an outline)
                w.b("eval", login, "document.getElementById('pass').focus()")
                w.b("key", login, "⇥", *extra); time.sleep(0.4)
                r = w.b("eval", login, "(()=>{const e=document.activeElement;return e.id+' fv='+e.matches(':focus-visible')+' outline='+getComputedStyle(e).outlineStyle})()").strip()
                rec("B10", "Tab from the password field reaches the Sign in button, ring visible", r.startswith("go ") and "fv=true" in r and "outline=none" not in r, r)
        except Exception as e:
            rec("B10", f"Tab in a form field ({via})", False, f"error: {e}")

    # ⌃Tab switches tabs.
    try:
        w.b("select", art); time.sleep(0.4); w.b("ui", "focus", "none")
        w.b("key", art, "⌃⇥", "--app"); time.sleep(0.5)
        rec("B10", "⌃Tab → another tab", active() != art, f"active {art} → {active()}")
    except Exception as e:
        rec("B10", "⌃Tab → another tab", False, f"error: {e}")

    # ⌘1–⌘9, pins included: the column's Nth row; ⌘9 the last.
    titles = {}
    for line in w.b("tabs").splitlines():
        m = re.match(r"^[●⚗ ]*\s*([0-9a-f]{8})\s+(.*?)\s{2}", line)
        if m: titles[m.group(1)] = m.group(2)
    for n in range(1, 10):
        want = expected_order[n - 1] if n < 9 else expected_order[-1]
        try:
            w.b("select", art); time.sleep(0.3); w.b("ui", "focus", "none")
            w.b("key", art, f"⌘{n}", "--app"); time.sleep(0.5)
            got = active()
            title = titles.get(got) or next((t for i, t in titles.items() if got and i.startswith(got)), got)
            rec("B10", f"⌘{n} → {want}", bool(title) and title.startswith(want[:20]), f"got {title!r}")
        except Exception as e:
            rec("B10", f"⌘{n} → {want}", False, f"error: {e}")
    w.b("select", art); time.sleep(0.5)

    # ⌘K: opens, arrows move the pick, Escape closes; ⌘L reaches the address field.
    try:
        w.b("ui", "focus", "none"); w.b("key", art, "⌘K", "--app"); time.sleep(0.6)
        opened = w.j("probe").get("summoning")
        w.b("ai", "key", "escape")  # to the window's first responder (the bar's field), as a real ⎋
        closed = False
        for _ in range(10):
            time.sleep(0.2)
            if not w.j("probe").get("summoning"):
                closed = True; break
        rec("B4", "⌘K opens, ⎋ closes", True if (opened and closed) else (False if not opened else None),
            f"open={opened} closed after ⎋={closed}" + ("" if closed else " — ⎋ can't reach the bar's field: a headless window is never key, so "
            "AppKit drops posted key events (proposal: ⎋ in `bench summon --keys`)"))
    except Exception as e:
        rec("B4", "⌘K opens, ⎋ closes", False, f"error: {e}")
    try:
        w.b("summon", "co"); time.sleep(1.2)
        before = w.j("summon", "co", "--keys", "↓").get("picked")
        after = w.j("summon", "co", "--keys", "↓").get("picked")
        rec("B4", "⌘K ↓ moves the pick", after is not None and before is not None and after > before, f"picked {before} → {after}")
        w.b("ai", "key", "escape"); time.sleep(0.5)
    except Exception as e:
        rec("B4", "⌘K ↓ moves the pick", False, f"error: {e}")
    try:
        t0 = time.time(); bar = w.b("bar", "copper docs"); ms = (time.time() - t0) * 1000
        rec("B4", "⌘K finds another open tab by title (\"copper docs\")", "Copper Docs" in bar, f"{ms:.0f} ms round trip; first rows: {' | '.join(bar.splitlines()[:3])}")
        bar = w.b("bar", "hacker")
        rec("B4", "⌘K finds a saved tab by title (\"hacker\")", "Hacker News" in bar, ' | '.join(bar.splitlines()[:3]))
    except Exception as e:
        rec("B4", "⌘K finds tabs", False, f"error: {e}")
    try:
        w.b("ui", "focus", "none"); w.b("key", art, "⌘L", "--app"); time.sleep(0.6)
        p = w.j("probe")
        rec("B4", "⌘L focuses the address field", bool(p.get("field") or p.get("summoning")), f"field={p.get('field')} summoning={p.get('summoning')} firstResponder={p.get('firstResponder')}")
        w.b("ai", "key", "escape"); time.sleep(0.4)
    except Exception as e:
        rec("B4", "⌘L focuses the address field", False, f"error: {e}")

    # Focus ring in the page (WebKit's :focus-visible after a keyboard Tab).
    try:
        w.b("select", art); w.b("eval", art, "document.querySelector('header a').focus()")
        w.b("key", art, "⇥", "--app"); time.sleep(0.4)
        r = w.b("eval", art, "(()=>{const e=document.activeElement;return e.tagName+' fv='+e.matches(':focus-visible')+' outline='+getComputedStyle(e).outlineStyle})()").strip()
        rec("B10", "Tab reaches links (Chromium/Arc do; WebKit's default is form controls only)", "fv=true" in r and "outline=none" not in r, r)
    except Exception as e:
        rec("B10", "page focus ring", False, f"error: {e}")
    rec("B10", "Focus rings on Copper's own controls", None,
        "not measurable here: a headless probe's window is never key, and AppKit/SwiftUI draw focus rings only in the key window")
    rec("B10", "VoiceOver labels on chrome controls", None,
        "not measurable here: SwiftUI builds no AX tree in a headless probe (bench ai ax → 1 AXGroup) and ssh is not AX-trusted")
    rec("B5", "Title-bar double-click fills the screen", None, "no bench verb for a title-bar double-click (proposal: `bench mouse double X Y`)")

    # Settings findability (B8): plain-word questions → the right page in the top 3.
    for q, page in [("dark mode", "general"), ("downloads folder", "general"), ("default browser", "general"),
                    ("passwords", "passwords"), ("sidebar", "tabs"), ("clear history", "privacy"),
                    ("block ads", "privacy"), ("agent", "agents"), ("update", "about"), ("profile", "spaces")]:
        try:
            r = w.j("settings", "search", q)
            rows = r if isinstance(r, list) else r.get("results", [])
            pages = [str(x.get("page", "")).lower() for x in rows[:3]]
            top = [x.get("title", "") for x in rows[:3]]
            rec("B8", f"Settings search “{q}” → {page} in top 3", page in pages, f"top: {list(zip(pages, top))}")
        except Exception as e:
            rec("B8", f"Settings search “{q}”", False, f"error: {e}")
    w.b("settings", "close")
    return res


def main():
    label, app, out = sys.argv[1], os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3])
    tag = re.sub(r"[^a-z0-9-]", "", label.lower())[:20] or "x"
    tmp = os.path.join(out, "tmp")
    os.makedirs(tmp, exist_ok=True)
    os.makedirs(os.path.join(out, "logs"), exist_ok=True)
    shoot = Shooter(out)
    port = free_port()
    started = time.time()
    common = [("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("probe.keychain", "-string", "file")]

    first = World(f"uxfirst-{tag}", app, port, os.path.join(out, "logs", "first.log"))
    try:
        # Truly fresh: no "welcomed", so the first-run path a new profile gets (start card, default layout) is what's pictured.
        first.reset([d for d in common if d[0] != "welcomed"])
        first.launch()
        first_run(first, shoot, tmp)
    finally:
        first.drop()

    w = World(f"ux-{tag}", app, port, os.path.join(out, "logs", "lived.log"))
    keys = []
    try:
        w.reset(common + [("sidebar", "-bool", "true"), ("glyph", "-string", "icons"), ("look", "-string", "light")])
        order = seed_lived_in(w.folder)
        w.launch()
        keys = checks(w, order) if not ONLY else []  # first, so the column is still the seeded one
        lived_in(w, shoot)
        if os.environ.get("UX_KEEP_ICONS"):  # what Marks fetched → OUTDIR/icons, to refresh ux/seed/icons
            shutil.copytree(os.path.join(w.folder, "icons"), os.path.join(out, "icons"), dirs_exist_ok=True)
    finally:
        w.drop()
    if not ONLY or any(o.startswith("narrow-") for o in ONLY):
        n = World(f"uxnarrow-{tag}", app, port, os.path.join(out, "logs", "narrow.log"))
        try:
            n.reset(common + [("sidebar", "-bool", "true"), ("glyph", "-string", "icons"), ("look", "-string", "light")])
            seed_narrow(n.folder)
            n.launch()
            narrow(n, shoot)
        finally:
            n.drop()
    json.dump(shoot.rows, open(os.path.join(out, "shots.json"), "w"), indent=1)
    if keys or not ONLY:
        json.dump(keys, open(os.path.join(out, "keys.json"), "w"), indent=1)
    load = os.getloadavg()
    json.dump({"label": label, "app": app, "seconds": round(time.time() - started), "load": [round(x, 2) for x in load],
               "port": port, "shots": sum(1 for r in shoot.rows if r.get("ok")),
               # picture pixels per window point: 2.0 on a Retina panel at its default scaling; a "More Space"
               # setting renders lower (e.g. 1.96), which thins text ink — compare only runs with the same scale.
               "scale": next((round(r["px"][0] / SIZES[r["size"]][0], 3) for r in shoot.rows if r.get("ok") and r.get("px")), None), "failed": [r for r in shoot.rows if not r.get("ok")]},
              open(os.path.join(out, "run.json"), "w"), indent=1)
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
