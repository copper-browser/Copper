#!/usr/bin/python3
"""Site compatibility sweep: the same logged-out pages in Copper and in Safari
on the same Mac. Same WebKit, so a site that works in Safari and not in Copper
is Copper's fault (user agent, missing API, content blocking, headers, storage).

  sites.py copper --app APP --out OUT.json [--port 4320] [--world hc-sites] [--only pypi,arxiv] [--extra HOSTS]
  sites.py safari --out OUT.json [--port 4325] [--only …] [--extra HOSTS]
  sites.py table SAFARI.json COPPER.json [MORE.json …] > table.md

Each site: load its page, then its key read-only flow (a search URL, an item,
a video) and check what should be there. Per row: loads · wall (bot check or
"unsupported browser") · flow · visual (picture not blank, text ≥ 40% of the
other browser's). Never signs in, never submits a form: flows are plain GETs.
--extra is a file of host names, one per line, loaded as https://HOST/ (load
and wall only); keep such lists out of git (they are someone's history).
Python 3.9, stdlib only (the Mac's /usr/bin/python3).
"""
import argparse, base64, fcntl, json, os, re, shutil, socket, subprocess, sys, tempfile, time, urllib.request

HOME = os.path.expanduser("~")

# name, first page, key flow page (or None), JS that is true when the flow worked, media (a video should play)
SITES = [
    ("pypi", "https://pypi.org/", "https://pypi.org/search/?q=requests", "document.querySelectorAll('a.package-snippet').length > 0", False),
    ("pypi-project", "https://pypi.org/project/requests/", None, "/pip install requests/.test(document.body.innerText)", False),
    ("arxiv", "https://arxiv.org/", "https://arxiv.org/abs/1706.03762", "/Attention Is All You Need/.test(document.title + document.body.innerText)", False),
    ("google", "https://www.google.com/", "https://www.google.com/search?q=webkit", "document.querySelectorAll('#search a h3, #rso a h3').length > 0", False),
    ("google-maps", "https://www.google.com/maps/place/Miami", None, "!!document.querySelector('canvas')", False),
    ("google-translate", "https://translate.google.com/?sl=en&tl=es&text=hello", None, "/hola/i.test(document.body.innerText)", False),
    ("gmail", "https://mail.google.com/", None, None, False),
    ("calendar", "https://calendar.google.com/", None, None, False),
    ("drive", "https://drive.google.com/", None, None, False),
    ("docs", "https://docs.google.com/", None, None, False),
    ("meet", "https://meet.google.com/", None, None, False),
    ("gemini", "https://gemini.google.com/", None, None, False),
    ("youtube", "https://www.youtube.com/", "https://www.youtube.com/watch?v=jNQXAC9IVRw", "(() => { const v = document.querySelector('video'); return !!v && v.readyState >= 2 && (v.currentTime > 0 || !v.paused); })()", True),
    ("x", "https://x.com/", "https://x.com/github", "/GitHub/.test(document.body.innerText)", False),
    ("github", "https://github.com/", "https://github.com/search?q=webkit&type=repositories", "/WebKit\\/WebKit|webkit/i.test(document.body.innerText) && document.querySelectorAll('[data-testid=\"results-list\"] a, .search-title a').length > 0", False),
    ("github-repo", "https://github.com/WebKit/WebKit", None, "!!document.querySelector('[data-testid=\"latest-commit\"], #readme, react-app')", False),
    ("slack", "https://app.slack.com/", None, None, False),
    ("claude", "https://claude.ai/", None, None, False),
    ("chatgpt", "https://chatgpt.com/", None, "!!document.querySelector('#prompt-textarea, textarea, [contenteditable]')", False),
    ("notion", "https://www.notion.so/", None, None, False),
    ("wikipedia", "https://en.wikipedia.org/", "https://en.wikipedia.org/w/index.php?search=WebKit", "/WebKit/.test(document.querySelector('#firstHeading')?.innerText || '')", False),
    ("reddit", "https://www.reddit.com/", "https://www.reddit.com/r/MacOS/", "document.querySelectorAll('shreddit-post, article').length > 0", False),
    ("amazon", "https://www.amazon.com/", "https://www.amazon.com/s?k=usb+c+cable", "document.querySelectorAll('[data-component-type=\"s-search-result\"]').length > 0", False),
    ("target", "https://www.target.com/", "https://www.target.com/s?searchTerm=usb+c+cable", "/results|cable/i.test(document.body.innerText)", False),
    ("costco", "https://www.costco.com/", None, None, False),
    ("instagram", "https://www.instagram.com/", None, None, False),
    ("linkedin", "https://www.linkedin.com/", None, None, False),
    ("stackoverflow", "https://stackoverflow.com/questions", None, "document.querySelectorAll('.s-post-summary').length > 0", False),
    ("nytimes", "https://www.nytimes.com/", None, None, False),
    ("bbc", "https://www.bbc.com/news", None, None, False),
    ("medium", "https://medium.com/", None, None, False),
    ("spotify", "https://open.spotify.com/", None, None, False),
    ("netflix", "https://www.netflix.com/", None, None, False),
    ("twitch", "https://www.twitch.tv/", None, None, False),
    ("discord", "https://discord.com/", None, None, False),
    ("figma", "https://www.figma.com/", None, None, False),
    ("apple", "https://www.apple.com/", None, None, False),
    ("paypal", "https://www.paypal.com/", None, None, False),
    ("chase", "https://www.chase.com/", None, None, False),
    ("bofa", "https://www.bankofamerica.com/", None, None, False),
    ("amex", "https://www.americanexpress.com/", None, None, False),
    ("wellsfargo", "https://www.wellsfargo.com/", None, None, False),
    ("robinhood", "https://robinhood.com/", None, None, False),
    ("cloudflare", "https://dash.cloudflare.com/", None, None, False),
    ("openai-platform", "https://platform.openai.com/", None, None, False),
    ("claude-platform", "https://platform.claude.com/", None, None, False),
    ("atlassian", "https://id.atlassian.com/", None, None, False),
    ("tailscale", "https://login.tailscale.com/", None, None, False),
    ("zocdoc", "https://www.zocdoc.com/", None, None, False),
    ("aa", "https://www.aa.com/", None, None, False),
    ("verizon", "https://www.verizon.com/", None, None, False),
    ("expo", "https://expo.dev/", None, None, False),
    ("vimeo", "https://vimeo.com/76979871", None, "!!document.querySelector('video, iframe')", False),
]

# Shown instead of the site: a bot check, a block, or "get a real browser".
WALL = re.compile(r"just a moment|verify(ing)? (that )?you are (a )?human|are you a robot|checking (if the site connection is secure|your browser)"
                  r"|unusual traffic|press (&|and) hold|access denied|request (was )?blocked|client challenge|bot detection"
                  r"|(browser|version) (is )?(not|no longer|isn.t) supported|unsupported browser|upgrade your browser|update your browser"
                  r"|please enable (javascript|cookies)|enable javascript and cookies|captcha|security check|pardon our interruption", re.I)

PROBE = r"""(() => {
  const nav = performance.getEntriesByType('navigation')[0] || {};
  const text = (document.body && document.body.innerText) || '';
  const walls = ['#challenge-form', '#challenge-running', 'iframe[src*="challenges.cloudflare.com"]', '#px-captcha',
    'iframe[src*="captcha"]', '[id^="sec-if-cpt"]', '#cf-chl-widget', 'iframe[title*="challenge" i]', 'form[action*="captcha"]']
    .filter(s => document.querySelector(s));
  return JSON.stringify({url: location.href, title: document.title, status: nav.responseStatus || 0,
    text: text.length, head: (document.title + '\n' + text.slice(0, 2500)), els: document.getElementsByTagName('*').length,
    walls, ua: navigator.userAgent, ready: document.readyState});
})()"""


def wall_of(p):
    if not p:
        return "no page"
    if p.get("walls"):
        return ",".join(p["walls"])
    m = WALL.search(p.get("head", ""))
    # A long page that mentions "captcha" once is a page, not a wall.
    if m and (p.get("text", 0) < 4000 or m.group(0).lower() in ("just a moment", "client challenge")):
        return m.group(0)
    if p.get("status") in (403, 429, 503) and p.get("text", 0) < 4000:
        return "HTTP %d" % p["status"]
    return ""


def blank(png_path):
    """True when the picture is (nearly) one colour: sips shrinks it to 32 px BMP, we count colours."""
    if not png_path or not os.path.exists(png_path):
        return None
    tmp = png_path + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", "-z", "32", "32", png_path, "--out", tmp], capture_output=True)
    try:
        data = open(tmp, "rb").read()
    except OSError:
        return None
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    off = int.from_bytes(data[10:14], "little")
    px = data[off:]
    bpp = int.from_bytes(data[28:30], "little") // 8 or 3
    colours = {}
    for i in range(0, len(px) - bpp + 1, bpp):
        c = tuple(v >> 4 for v in px[i:i + 3])
        colours[c] = colours.get(c, 0) + 1
    top = max(colours.values()) if colours else 0
    return top >= 0.97 * (len(px) // bpp)


# ---------------------------------------------------------------- browsers

class Copper:
    """A headless probe world of one build, driven over its bench socket (real tabs, not agent tabs)."""

    def __init__(self, app, world, port, log_dir):
        assert port != 4123, "never the installed Copper's port"
        self.app, self.world, self.port, self.log_dir = os.path.abspath(app), world, port, log_dir
        self.folder = os.path.join(HOME, "Library/Application Support/Copper (%s)" % world)
        self.suite = "com.collinrijock.copper.test." + world
        self.label = "hc.sites." + world
        self.plist = "/tmp/%s.plist" % self.label
        self.sock = os.path.join(self.folder, "bench.sock")

    def start(self):
        self.stop()
        # A fresh world each run: logged out, no cookies from last time.
        shutil.rmtree(self.folder, ignore_errors=True)
        subprocess.run(["defaults", "delete", self.suite], capture_output=True)
        h = 2166136261
        for ch in self.world.encode():
            h = ((h ^ ch) * 16777619) & 0xFFFFFFFF
        stem = ("5E4C%04X-%04X" % (h >> 16, h & 0xFFFF)).lower()
        kit = os.path.join(HOME, "Library/WebKit/com.collinrijock.copper.dev/WebsiteDataStore")
        for d in (os.listdir(kit) if os.path.isdir(kit) else []):
            if d.lower().startswith(stem):
                shutil.rmtree(os.path.join(kit, d), ignore_errors=True)
        for key, kind, value in [("bench", "-bool", "true"), ("welcomed", "-bool", "true"), ("probe.keychain", "-string", "file")]:
            subprocess.run(["defaults", "write", self.suite, key, kind, value], check=False)
        env = {"SEARCH_PROBE": self.world, "SEARCH_MCP_PORT": str(self.port), "SEARCH_HEADLESS": "1",
               "SEARCH_HEADLESS_SIZE": "1440x900"}
        envs = "".join("<key>%s</key><string>%s</string>" % kv for kv in env.items())
        with open(self.plist, "w") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
                    '<key>Label</key><string>%s</string><key>EnvironmentVariables</key><dict>%s</dict>'
                    '<key>KeepAlive</key><false/><key>RunAtLoad</key><true/>'
                    '<key>LimitLoadToSessionType</key><string>Aqua</string>'
                    '<key>ProgramArguments</key><array><string>%s/Contents/MacOS/Copper</string></array>'
                    '<key>StandardErrorPath</key><string>%s/copper-%s.log</string>'
                    '<key>StandardOutPath</key><string>%s/copper-%s.out</string></dict></plist>'
                    % (self.label, envs, self.app, self.log_dir, self.world, self.log_dir, self.world))
        subprocess.run(["launchctl", "bootstrap", "gui/%d" % os.getuid(), self.plist], check=True)
        t0 = time.time()
        while time.time() - t0 < 60:
            try:
                self.ask({"do": "tabs"}, 3)
                return
            except Exception:
                time.sleep(0.5)
        raise RuntimeError("probe world %s did not come up" % self.world)

    def stop(self):
        subprocess.run(["launchctl", "bootout", "gui/%d/%s" % (os.getuid(), self.label)], capture_output=True)
        time.sleep(1)

    def ask(self, req, timeout=30):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(self.sock)
            s.sendall((json.dumps(req) + "\n").encode())
            chunks = []
            while True:
                c = s.recv(1 << 16)
                if not c:
                    break
                chunks.append(c)
        return json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")

    def open(self, url):
        self.tab = self.ask({"do": "open", "url": url})["id"]

    def go(self, url):
        self.ask({"do": "go", "id": self.tab, "url": url})

    def wait(self, seconds):
        try:
            self.ask({"do": "wait", "id": self.tab, "seconds": seconds}, seconds + 5)
        except socket.timeout:
            pass

    def eval(self, js):
        v = self.ask({"do": "eval", "id": self.tab, "js": js}, 20).get("value")
        return v

    def shot(self, path):
        self.ask({"do": "shot", "id": self.tab, "path": path, "width": 1440}, 30)
        return path

    def close(self):
        try:
            self.ask({"do": "close", "id": self.tab}, 10)
        except Exception:
            pass

    def version(self):
        return subprocess.run(["defaults", "read", self.app + "/Contents/Info.plist", "CFBundleShortVersionString"],
                              capture_output=True, text=True).stdout.strip()


class Safari:
    """Safari over safaridriver (WebDriver): a clean automation window, no profile of anyone's."""

    def __init__(self, port):
        assert port != 4123
        self.port = port
        self.proc = None

    def call(self, method, path, body=None, timeout=60):
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r).get("value")

    def start(self):
        self.proc = subprocess.Popen(["safaridriver", "-p", str(self.port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(40):
            try:
                self.call("GET", "/status", timeout=2)
                break
            except Exception:
                time.sleep(0.25)
        self.sid = self.call("POST", "/session", {"capabilities": {"alwaysMatch": {"browserName": "safari"}}})["sessionId"]
        self.call("POST", "/session/%s/window/rect" % self.sid, {"width": 1440, "height": 900, "x": 0, "y": 0})
        self.call("POST", "/session/%s/timeouts" % self.sid, {"pageLoad": 30000, "script": 20000})

    def stop(self):
        try:
            self.call("DELETE", "/session/%s" % self.sid, timeout=10)
        except Exception:
            pass
        if self.proc:
            self.proc.terminate()

    def open(self, url):
        self.go(url)

    def go(self, url):
        try:
            self.call("POST", "/session/%s/url" % self.sid, {"url": url}, 40)
        except Exception:
            pass  # a slow load times out; the probe reads whatever is there

    def wait(self, seconds):
        pass  # WebDriver's navigate already waited for the load

    def eval(self, js):
        return self.call("POST", "/session/%s/execute/sync" % self.sid, {"script": "return " + js, "args": []}, 25)

    def shot(self, path):
        data = self.call("GET", "/session/%s/screenshot" % self.sid, timeout=30)
        with open(path, "wb") as f:
            f.write(base64.b64decode(data))
        return path

    def close(self):
        pass

    def version(self):
        return subprocess.run(["defaults", "read", "/Applications/Safari.app/Contents/Info.plist", "CFBundleShortVersionString"],
                              capture_output=True, text=True).stdout.strip()


# ---------------------------------------------------------------- the sweep

def probe(b):
    try:
        v = b.eval(PROBE)
        return json.loads(v) if isinstance(v, str) else None
    except Exception as e:
        return {"error": str(e)[:200]}


def check(b, js, tries=6):
    """The flow's check, a few times over ~6 s (pages that render after load)."""
    for _ in range(tries):
        try:
            if b.eval("!!(%s)" % js) is True:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


def one(b, site, shots):
    name, url, flow, js, media = site
    row = {"site": name, "url": url}
    t0 = time.time()
    try:
        b.open(url)
        b.wait(25)
        time.sleep(3)  # JS bot checks and app shells settle after load
        p = probe(b)
        row["load_s"] = round(time.time() - t0, 1)
        row["page"] = {k: p.get(k) for k in ("url", "title", "status", "text", "els", "ready", "walls", "error")} if p else None
        row["ua"] = (p or {}).get("ua")
        row["wall"] = wall_of(p)
        row["loads"] = bool(p and not p.get("error") and p.get("els", 0) > 20 and p.get("text", 0) > 0)
        shot = os.path.join(shots, name + ".png")
        try:
            b.shot(shot)
            row["blank"] = blank(shot)
        except Exception as e:
            row["blank"] = None
            row["shot_error"] = str(e)[:120]
        if flow or js:
            if flow:
                b.go(flow)
                b.wait(25)
                time.sleep(2)
            row["flow"] = check(b, js) if js else True
            q = probe(b)
            if q:
                row["flow_page"] = {k: q.get(k) for k in ("url", "title", "status", "text")}
                row["flow_wall"] = wall_of(q)
                if row["flow_wall"]:
                    row["wall"] = row["wall"] or "flow: " + row["flow_wall"]
    except Exception as e:
        row["error"] = str(e)[:200]
        row.setdefault("loads", False)
    finally:
        b.close()
    return row


def sites_for(args):
    picked = list(SITES)
    if args.extra:
        known = {re.sub(r"^www\.", "", re.match(r"https?://([^/]+)", s[1]).group(1)) for s in SITES}
        for line in open(os.path.expanduser(args.extra)):
            host = line.strip()
            if host and not host.startswith("#") and re.sub(r"^www\.", "", host) not in known:
                picked.append((host, "https://%s/" % host, None, None, False))
    if args.only:
        want = args.only.split(",")
        picked = [s for s in picked if s[0] in want]
    return picked


def sweep(args, b):
    out = os.path.abspath(args.out)
    shots = os.path.splitext(out)[0] + "-shots"
    os.makedirs(shots, exist_ok=True)
    rows = []
    for s in sites_for(args):
        lock = open(os.path.expanduser(args.lock), "a") if args.lock else None
        if lock:
            fcntl.flock(lock, fcntl.LOCK_EX)  # one site per hold: the shared Mac's measurements run between them
        try:
            r = one(b, s, shots)
        finally:
            if lock:
                lock.close()
        rows.append(r)
        print("%-18s loads=%s wall=%-20s flow=%s blank=%s %ss" % (r["site"], r.get("loads"), (r.get("wall") or "-")[:20],
              r.get("flow", "-"), r.get("blank"), r.get("load_s")), flush=True)
        with open(out, "w") as f:
            json.dump({"browser": args.cmd, "version": b.version(), "when": time.strftime("%Y-%m-%d %H:%M"), "rows": rows}, f, indent=1)
    return rows


# ---------------------------------------------------------------- the table

def verdict(r, other):
    loads = r.get("loads")
    wall = r.get("wall") or ""
    flow = r.get("flow")
    vis = r.get("blank") is False and (not other or not other.get("page") or not r.get("page")
                                       or r["page"].get("text", 0) >= 0.4 * (other["page"].get("text") or 0))
    ok = loads and not wall and flow is not False and vis
    return ok, loads, wall, flow, vis


def table(paths):
    runs = [json.load(open(p)) for p in paths]
    names = []
    for run in runs:
        for r in run["rows"]:
            if r["site"] not in names:
                names.append(r["site"])
    by = [{r["site"]: r for r in run["rows"]} for run in runs]
    heads = ["%s %s" % (run["browser"], run["version"]) for run in runs]
    print("| site | " + " | ".join(heads) + " |")
    print("|---|" + "---|" * len(runs))
    passes = [0] * len(runs)
    for n in names:
        cells = []
        for i, run in enumerate(by):
            r = run.get(n)
            if not r:
                cells.append("—")
                continue
            other = by[0].get(n) if i else (by[1].get(n) if len(by) > 1 else None)
            ok, loads, wall, flow, vis = verdict(r, other)
            passes[i] += ok
            bits = ["✅" if ok else "❌", "load" if loads else "NO LOAD"]
            if wall:
                bits.append("wall: " + wall[:30])
            if flow is not None:
                bits.append("flow ok" if flow else "FLOW FAIL")
            if not vis:
                bits.append("VISUAL")
            cells.append(" · ".join(bits))
        print("| %s | %s |" % (n, " | ".join(cells)))
    print("| **pass** | " + " | ".join("**%d/%d**" % (p, len(r["rows"])) for p, r in zip(passes, runs)) + " |")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["copper", "safari", "table"])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--app")
    ap.add_argument("--out")
    ap.add_argument("--port", type=int)
    ap.add_argument("--world", default="hc-sites")
    ap.add_argument("--only")
    ap.add_argument("--extra")
    ap.add_argument("--lock", help="flock this file around each site (the mini: ~/hc/mini.lock)")
    args = ap.parse_args()
    if args.cmd == "table":
        return table(args.files)
    if args.cmd == "copper":
        b = Copper(args.app, args.world, args.port or 4320, os.path.dirname(os.path.abspath(args.out)))
    else:
        b = Safari(args.port or 4325)
    b.start()
    try:
        sweep(args, b)
    finally:
        b.stop()


if __name__ == "__main__":
    main()
