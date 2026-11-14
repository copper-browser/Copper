#!/usr/bin/python3
"""Coverage runner: every job in jobs.py against a headless probe world of one
Copper build, over its loopback MCP port (token from the world's agent.json).
Python 3.9, stdlib only (the mini's /usr/bin/python3).

  run.py --app APP --out DIR [--world hc-cov] [--port 4150] [--fixtures 8795]
         [--only id,prefix…] [--keep]
  run.py --matrix          rewrite matrix.md's job table from jobs.py

Never touches the installed Copper: world "Copper (<world>)", port 4150–4159,
a launchd job of its own (hc.coverage.<world>), a fake `bw` (bw-mock.py) and the
probe file keychain.
"""
import argparse, base64, glob, json, os, re, shutil, socket, struct, subprocess, sys, time, traceback, urllib.error, urllib.request, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")


class Fail(Exception):
    pass


class Missing(Exception):
    pass


class NeedsSecret(Exception):
    pass


class Hung(Exception):
    """A call got no answer: Copper (or the tab) stopped answering."""


class Skip(Exception):
    pass


# ---------------------------------------------------------------- the world

class World:
    def __init__(self, app, name, port, log_dir, headless=True):
        self.app, self.name, self.port, self.log_dir = os.path.abspath(app), name, port, log_dir
        self.headless = headless
        self.folder = os.path.join(HOME, "Library/Application Support/Copper (%s)" % name)
        self.suite = "com.collinrijock.copper.test." + name
        self.label = "hc.coverage." + name
        self.plist = "/tmp/%s.plist" % self.label
        self.token = None
        self.seed = None  # session.json for a fresh world (two spaces: c5.spaces_move needs a second)
        assert port != 4123 and 4130 <= port <= 4239, "coverage ports: 4130-4239 (each worker its own range), never 4123"

    def env(self):
        env = {"SEARCH_PROBE": self.name, "SEARCH_MCP_PORT": str(self.port), "SEARCH_BW_PATH": os.path.join(HERE, "bw-mock.py")}
        if self.headless:
            env.update(SEARCH_HEADLESS="1", SEARCH_HEADLESS_SIZE="1440x900")
        return env

    def defaults(self):
        for key, kind, value in [("bench", "-bool", "true"), ("welcomed", "-bool", "true"),
                                 ("probe.keychain", "-string", "file")]:
            subprocess.run(["defaults", "write", self.suite, key, kind, value], check=False)

    def start(self, fresh=False):
        self.stop()
        if fresh:
            shutil.rmtree(self.folder, ignore_errors=True)
            subprocess.run(["defaults", "delete", self.suite], capture_output=True)
            # The world's WebKit stores (cookies, localStorage), named by an FNV-1a hash of the world (Store.swift).
            h = 2166136261
            for ch in self.name.encode():
                h = ((h ^ ch) * 16777619) & 0xFFFFFFFF
            stem = "5E4C%04X-%04X" % (h >> 16, h & 0xFFFF)
            kit = os.path.join(HOME, "Library/WebKit/com.collinrijock.copper.dev")
            for d in glob.glob(os.path.join(kit, "WebExtensions", stem + "-*")) + glob.glob(os.path.join(kit, "WebsiteDataStore", stem.lower() + "-*")):
                shutil.rmtree(d, ignore_errors=True)
        self.defaults()
        if fresh and self.seed:
            os.makedirs(self.folder, exist_ok=True)
            with open(os.path.join(self.folder, "session.json"), "w") as f:
                json.dump(self.seed, f)
        if fresh and os.environ.get("COV_JEV_KEYS", "1") != "0":
            self.jev_keys()
        if not self.headless:
            # A windowed world serves agents only when agent.json says so (headless defaults it on).
            os.makedirs(self.folder, exist_ok=True)
            path = os.path.join(self.folder, "agent.json")
            cfg = {}
            if os.path.exists(path):
                cfg = json.load(open(path))
            cfg.update(enabled=True, port=self.port, token=cfg.get("token") or os.urandom(24).hex())
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
                json.dump(cfg, f)
        envs = "".join("<key>%s</key><string>%s</string>" % kv for kv in self.env().items())
        with open(self.plist, "w") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>'
                    '<key>Label</key><string>%s</string><key>EnvironmentVariables</key><dict>%s</dict>'
                    '<key>KeepAlive</key><false/><key>RunAtLoad</key><true/>'
                    '<key>LimitLoadToSessionType</key><string>Aqua</string>'
                    '<key>ProgramArguments</key><array><string>%s/Contents/MacOS/Copper</string></array>'
                    '<key>StandardErrorPath</key><string>%s/copper.log</string>'
                    '<key>StandardOutPath</key><string>%s/copper.out</string></dict></plist>'
                    % (self.label, envs, self.app, self.log_dir, self.log_dir))
        subprocess.run(["launchctl", "bootstrap", "gui/%d" % os.getuid(), self.plist], check=True)
        t0 = time.time()
        while time.time() - t0 < 60:
            if self.health() and self.read_token():
                return time.time() - t0
            time.sleep(0.25)
        raise RuntimeError("probe world did not come up on %d (see %s/copper.log)" % (self.port, self.log_dir))

    def jev_keys(self):
        """Only the Jev + text-model keys from the dev world (agentbench.sh's way), for c7.inject_jev; never printed."""
        src = os.path.join(HOME, "Library/Application Support/Copper (dev)/intelligence.json")
        if not os.path.exists(src):
            return
        dev = json.load(open(src))
        keep = {k: dev[k] for k in ("jevKey", "jevEndpoint", "jevModel", "routerKey", "routerURL", "routerModel", "textModel") if k in dev}
        os.makedirs(self.folder, exist_ok=True)
        with os.fdopen(os.open(os.path.join(self.folder, "intelligence.json"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            json.dump(keep, f)

    def stop(self):
        subprocess.run(["launchctl", "bootout", "gui/%d/%s" % (os.getuid(), self.label)], capture_output=True)
        for _ in range(40):
            if not self.health(timeout=0.5):
                break
            time.sleep(0.25)

    def pid(self):
        """This world's process, from its launchd job."""
        p = subprocess.run(["launchctl", "list", self.label], capture_output=True, text=True)
        m = re.search(r'"PID" = (\d+);', p.stdout)
        return int(m.group(1)) if m else None

    def read_token(self):
        try:
            with open(os.path.join(self.folder, "agent.json")) as f:
                cfg = json.load(f)
            self.token = cfg.get("token") or None
            return self.token
        except Exception:
            return None

    def health(self, timeout=3):
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d/health" % self.port, timeout=timeout) as r:
                return json.load(r)
        except Exception:
            return None

    def cli(self, args, stdin=None, timeout=60, env=None):
        e = dict(os.environ, SEARCH_PROBE=self.name, SEARCH_MCP_PORT=str(self.port))
        e.pop("COPPER_AGENT_PORT", None)
        e.update(env or {})
        try:
            p = subprocess.run([self.app + "/Contents/MacOS/Copper", "--cli"] + args, input=stdin, env=e,
                               capture_output=True, text=True, timeout=timeout)
            return p.returncode, p.stdout, p.stderr
        except subprocess.TimeoutExpired:
            raise Hung("copper %s: no answer in %ds" % (" ".join(args[:2]), timeout))

    def bench(self, args, timeout=20):
        b = os.environ.get("HC_BENCH")
        if not b or not os.path.exists(b):
            raise Missing("bench script not found (set HC_BENCH)")
        p = subprocess.run(["python3", b, "--world", self.name] + args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()


# ---------------------------------------------------------------- MCP client

class Result:
    def __init__(self, raw, ms):
        self.raw, self.ms = raw, ms
        content = raw.get("content") or []
        self.text = "\n".join(c.get("text", "") for c in content if c.get("type") == "text")
        self.images = [base64.b64decode(c["data"]) for c in content if c.get("type") == "image"]
        self.error = bool(raw.get("isError"))


class Session:
    """One MCP client (one Mcp-Session-Id): Copper treats it as one agent with its own tab."""

    def __init__(self, world, name="hc-coverage"):
        self.world, self.sid, self.tabs = world, None, []
        r, headers = self._post({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": name, "version": "1"}}}, 15)
        self.sid = headers.get("Mcp-Session-Id")
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, 5)

    def _post(self, body, timeout):
        h = {"Authorization": "Bearer " + self.world.token, "Content-Type": "application/json",
             "Accept": "application/json, text/event-stream"}
        if self.sid:
            h["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request("http://127.0.0.1:%d/mcp" % self.world.port, json.dumps(body).encode(), h)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = r.read()
                headers = dict(r.headers)
        except socket.timeout:
            raise Hung("no answer in %ss" % timeout)
        except urllib.error.URLError as e:
            if isinstance(e.reason, socket.timeout):
                raise Hung("no answer in %ss" % timeout)
            raise Hung("unreachable: %s" % e.reason)
        if not data.strip():
            return {}, headers
        text = data.decode()
        if text.startswith("event:") or text.startswith("data:"):
            text = "\n".join(l[5:] for l in text.splitlines() if l.startswith("data:"))
        return json.loads(text), headers

    def tools(self, raw=False):
        r, _ = self._post({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}, 15)
        return r["result"]["tools"] if raw else [t["name"] for t in r["result"]["tools"]]

    def call(self, tool, args=None, timeout=20, ok=True):
        t0 = time.time()
        r, _ = self._post({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                           "params": {"name": tool, "arguments": args or {}}}, timeout)
        if "error" in r:
            raise Fail("%s: JSON-RPC error %s" % (tool, r["error"].get("message")))
        res = Result(r.get("result") or {}, int((time.time() - t0) * 1000))
        if ok and res.error:
            raise Fail("%s → error: %s" % (tool, res.text[:300]))
        return res

    # helpers every job uses ------------------------------------------------
    def open(self, url, timeout=25):
        res = self.call("browser_tabs", {"action": "new", "url": url}, timeout)
        m = re.search(r"\{tab ([0-9a-zA-Z]+)\}", res.text)
        if not m:
            raise Fail("browser_tabs new gave no tab id: " + res.text[:200])
        self.tabs.append(m.group(1))
        return m.group(1)

    def ev(self, tab, fn, timeout=15):
        """browser_evaluate a function returning JSON.stringify(...) → the value."""
        args = {"function": fn}
        if tab:
            args["tab"] = tab
        res = self.call("browser_evaluate", args, timeout)
        try:
            return json.loads(res.text)
        except ValueError:
            return res.text

    def r(self, tab, key=None):
        got = self.ev(tab, "() => JSON.stringify(window.__r || {})")
        if not isinstance(got, dict):
            raise Fail("could not read page state: %r" % (got,))
        return got.get(key) if key else got

    def wait_r(self, tab, key, want=None, timeout=8.0):
        t0, last = time.time(), None
        while time.time() - t0 < timeout:
            last = self.r(tab, key)
            if last is not None and (want is None or (want(last) if callable(want) else last == want)):
                return last
            time.sleep(0.25)
        raise Fail("page never recorded %s%s (last: %r)" % (key, "" if want is None else " as expected" if callable(want) else " = %r" % (want,), last))

    def ref(self, tab, name, interactive=True):
        """The [ref=eN] of the first snapshot line naming `name`."""
        snap = self.call("browser_snapshot", {"tab": tab, "interactive": interactive}).text
        for line in snap.splitlines():
            if name in line:
                m = re.search(r"\[ref=(e\d+)\]", line)
                if m:
                    return m.group(1)
        raise Fail("snapshot has no ref for %r" % name)

    def close_all(self):
        for t in self.tabs:
            try:
                self.call("browser_tabs", {"action": "close", "tab": t}, 8, ok=False)
            except Exception:
                pass
        self.tabs = []


# ---------------------------------------------------------------- PNG reader

def png_info(data):
    """(width, height, pixel(x, y) -> (r, g, b)) for an 8-bit RGB/RGBA PNG; stdlib only."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + n
    bpp = {2: 3, 6: 4}.get(color)
    if depth != 8 or not bpp:
        return w, h, None
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, lambda x, y: tuple(rows[y][x * bpp:x * bpp + 3])


# ---------------------------------------------------------------- running

class Ctx:
    def __init__(self, world, fixtures_port, out_dir):
        self.world = world
        self.F = "http://127.0.0.1:%d" % fixtures_port          # first origin
        self.F2 = "http://127.0.0.1:%d" % (fixtures_port + 1)   # second origin (cross-origin frames, popups)
        self.LH = "http://localhost:%d" % fixtures_port         # a real host name (passkeys need one)
        self.out = out_dir
        self.user_tab = None
        self.tools = []
        self.state = {}
        self.sessions = []

    def session(self, name="hc-coverage"):
        s = Session(self.world, name)
        self.sessions.append(s)
        return s

    def setup(self):
        """The user's tab: a page on screen that no job may touch."""
        s = Session(self.world, "hc-setup")
        res = s.call("browser_tabs", {"action": "new", "url": self.F + "/index.html", "focus": True}, 25)
        self.user_tab = re.search(r"\{tab ([0-9a-zA-Z]+)\}", res.text).group(1)
        self.user_session = s

    def user_tab_line(self):
        """`<url> {tab id}` of the tab on the user's screen."""
        res = Session(self.world, "hc-watch").call("browser_tabs", {"action": "list"}, 10)
        for line in res.text.splitlines():
            if "on screen" in line:
                m = re.search(r"\] \((\S*)\) \{tab (\w+)\}", line)
                return "%s {tab %s}" % m.groups() if m else line
        return ""


def run(args):
    import jobs
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    world = World(args.app, args.world, args.port, out, headless=args.mode == "headless")
    ctx = Ctx(world, args.fixtures, out)
    A, B = "AAAAAAAA-0000-4000-8000-0000000000C1", "BBBBBBBB-0000-4000-8000-0000000000C2"
    world.seed = {"active": 0, "space": A, "spaces": [{"id": A, "name": "HC Alpha", "hue": 0.1}, {"id": B, "name": "HC Beta", "hue": 0.6}],
                  "tabs": [{"url": ctx.F + "/index.html", "title": "HC coverage", "space": A, "saved": True}]}
    selected = [j for j in jobs.JOBS if not args.only or any(j.id == o or j.id.startswith(o) for o in args.only.split(","))]
    # c7.not_running_cli stops the world: last, by itself.
    selected.sort(key=lambda j: j.id == "c7.not_running_cli")
    runs = []
    for n in range(args.repeat):
        load = os.getloadavg()
        print("coverage run %d/%d (%s): %d jobs, world %s on %d, fixtures %s, load %.2f" % (
            n + 1, args.repeat, args.mode, len(selected), world.name, world.port, ctx.F, load[0]), flush=True)
        ctx.state = {}
        boot = world.start(fresh=True)
        version = (world.health() or {}).get("version")
        ctx.setup()
        tools = ctx.tools = Session(world, "hc-tools").tools()
        results = [run_one(j, ctx, tools) for j in selected]
        runs.append({"results": results, "load": [round(x, 2) for x in load], "boot_s": round(boot, 1), "version": version})
        if not args.keep or n + 1 < args.repeat:
            world.stop()
    report(runs, tools, world, args, out)
    return runs


def run_one(j, ctx, tools):
    t0 = time.time()
    status, detail, metrics = "pass", "", None
    lacking = [t for t in j.needs if t not in tools]
    before = None
    try:
        if lacking:
            raise Missing("no %s tool" % " / ".join(lacking))
        before = ctx.user_tab_line() if j.watch_user else None
        detail = j.fn(ctx) or ""
        if isinstance(detail, dict):  # a measured job (C8): numbers, not pass/fail
            metrics, detail, status = detail, detail.pop("_note", ""), "measured"
    except Missing as e:
        status, detail = "missing", str(e)
    except NeedsSecret as e:
        status, detail = "needs-secret", str(e)
    except Skip as e:
        status, detail = "skip", str(e)
    except Hung as e:
        status, detail = "fail", "HUNG: " + str(e)
    except Fail as e:
        status, detail = "fail", str(e)
    except Exception as e:
        status, detail = "fail", "harness error: %s: %s" % (type(e).__name__, e)
        traceback.print_exc()
    for s in ctx.sessions:
        try:
            s.close_all()
        except Exception:
            pass
    ctx.sessions = []
    # Did the job leave Copper answering, and the user's tab where it was?
    alive = ctx.world.health(timeout=5)
    if not alive or not _answers(ctx):
        status = "fail"
        detail = (detail + " · " if detail else "") + "Copper stopped answering after this job; restarted the world"
        restart(ctx)
    elif before is not None and status in ("pass", "fail", "measured"):
        after = ctx.user_tab_line()
        if after != before:
            status = "fail"
            detail = (detail + " · " if detail else "") + "the user's on-screen tab changed: %s → %s" % (before[:120], after[:120])
            restart(ctx)
    ms = int((time.time() - t0) * 1000)
    print("%-28s %-12s %6d ms  %s" % (j.id, status, ms, detail[:150]), flush=True)
    ok = status in ("pass", "measured")
    row = {"id": j.id, "group": j.group, "title": j.title, "tool": j.tool, "status": status, "error": "" if ok else detail,
           "note": detail if ok else "", "ms": ms}
    if metrics is not None:
        row["metrics"] = metrics
    return row


def _answers(ctx):
    try:
        Session(ctx.world, "hc-ping").call("browser_tabs", {"action": "list"}, 8)
        return True
    except Exception:
        return False


def restart(ctx):
    pid = ctx.world.pid()
    ctx.world.stop()
    if pid:  # only this world's process: other tracks run probe worlds of the same build
        subprocess.run(["kill", "-9", str(pid)], capture_output=True)
    ctx.world.start(fresh=False)
    ctx.setup()
    ctx.state.pop("vault", None)


def score_of(results):
    runnable = [r for r in results if r["status"] in ("pass", "fail", "missing")]
    return round(100.0 * sum(r["status"] == "pass" for r in runnable) / max(1, len(runnable)), 1)


def report(runs, tools, world, args, out):
    """One row per job: the status most runs gave (ties → the worse), flaky when runs disagree."""
    import jobs
    gates = {j.id: j.gate for j in jobs.JOBS if j.gate}
    order = ["fail", "missing", "needs-secret", "skip", "measured", "pass"]
    results = []
    for i, first in enumerate(runs[0]["results"]):
        seen = [run["results"][i] for run in runs]
        statuses = [r["status"] for r in seen]
        top = max(order, key=lambda st: (statuses.count(st), -order.index(st)))
        pick = next(r for r in seen if r["status"] == top)
        row = dict(pick, runs=statuses, flaky=len(set(statuses)) > 1, ms=sorted(r["ms"] for r in seen)[len(seen) // 2])
        if row["flaky"] and not row["error"]:
            row["error"] = next((r["error"] for r in seen if r["error"]), "")
        results.append(row)
    scores = [score_of(r["results"]) for r in runs]
    load = runs[0]["load"]
    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    score = score_of(results)
    groups = {}
    for r in results:
        g = groups.setdefault(r["group"], {"pass": 0, "total": 0})
        g["total"] += 1
        g["pass"] += r["status"] == "pass"
    # C7 hard gates (SCOREBOARD): any of these failing caps C7 at 4, whatever the %.
    gate_fails = ["%s (%s)" % (r["id"], gates[r["id"]]) for r in results if r["id"] in gates and r["status"] == "fail"]
    gate_fails += ["%s (wrong-tab: moved the user's tab)" % r["id"] for r in results
                   if "user's on-screen tab changed" in r["error"] and r["id"] not in gates]
    meta = {"gate_fails": gate_fails, "label": args.label, "mode": args.mode, "app": os.path.abspath(args.app), "world": world.name, "port": world.port,
            "when": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "host": socket.gethostname(),
            "load_per_run": [r["load"] for r in runs], "boot_s": [r["boot_s"] for r in runs], "version": runs[0]["version"],
            "repeats": len(runs), "score_pct": score, "score_per_run": scores, "flaky": [r["id"] for r in results if r["flaky"]],
            "counts": counts, "groups": groups, "tools": tools}
    suffix = "" if args.mode == "headless" else "-" + args.mode
    with open(os.path.join(out, "coverage%s.json" % suffix), "w") as f:
        json.dump({"meta": meta, "jobs": {r["id"]: r for r in results}}, f, indent=1)
    names = {"C1": "Accounts + secrets", "C2": "Forms + inputs", "C3": "Files out", "C4": "Page + JS",
             "C5": "Tabs + browser state", "C6": "Hard UI", "C7": "Reliability + safety", "C8": "Ergonomics (measured)"}
    icon = {"pass": "✅", "fail": "❌", "missing": "⬜", "needs-secret": "🔑", "skip": "➖", "measured": "📏"}
    lines = ["# Coverage — %s (%s)" % (args.label, args.mode), "",
             "`%s` %s · %s · %s · load %s · %d tools listed" % (meta["app"], meta["version"] or "", meta["host"], meta["when"],
                                                            "/".join("%.2f" % r["load"][0] for r in runs), len(tools)), "",
             "**Score: %s%% pass** (%d pass · %d fail · %d missing%s of %d) · per run %s · flaky: %s" % (
                 score, counts.get("pass", 0), counts.get("fail", 0), counts.get("missing", 0),
                 "".join(" · %d %s" % (v, k) for k, v in counts.items() if k not in ("pass", "fail", "missing")), len(results),
                 " / ".join("%s%%" % x for x in scores), ", ".join(meta["flaky"]) or "none"), "",
             "**C7 safety gates failing** (each caps C7 at 4): %s" % (", ".join(gate_fails) or "none"), "",
             "Score = pass / (pass + fail + missing). ✅ pass · ❌ fail · ⬜ missing (no tool) · 🔑 needs-secret · ➖ skip · 📏 measured (C8, not in the score) · 〰 flaky", "",
             "| Group | Pass |", "|---|---|"]
    for g in sorted(groups):
        lines.append("| %s %s | %d / %d |" % (g, names.get(g, ""), groups[g]["pass"], groups[g]["total"]))
    lines += ["", "| Job | | Tool | ms | Error / note |", "|---|---|---|---|---|"]
    for r in results:
        msg = (r["error"] or r["note"]).replace("|", "\\|").replace("\n", " ")[:220]
        mark = icon.get(r["status"], r["status"]) + (" 〰 " + "/".join(r["runs"]) if r["flaky"] else "")
        lines.append("| `%s` %s | %s | `%s` | %d | %s |" % (r["id"], r["title"], mark, r["tool"], r["ms"], msg))
    measured = [r for r in results if r.get("metrics")]
    if measured:
        lines += ["", "## C8 measured (run 1)", "", "| Job | Measure | Value |", "|---|---|---|"]
        for r in measured:
            for k, v in r["metrics"].items():
                if k != "cases":
                    lines.append("| `%s` | %s | %s |" % (r["id"], k, json.dumps(v) if isinstance(v, (dict, list)) else v))
        for r in measured:
            if r["metrics"].get("cases"):
                lines += ["", "`%s` cases (✅ names the next step · ❌ doesn't · ⚠ no error at all):" % r["id"], ""]
                lines += ["- %s `%s`%s — %s" % (c["mark"], c["call"], " (\u201c%s\u201d)" % c["why"] if c.get("why") else "",
                                               c["text"].replace("\n", " ")[:160]) for c in r["metrics"]["cases"]]
    with open(os.path.join(out, "coverage%s.md" % suffix), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\nscore %s%% (runs %s) · %s → %s/coverage%s.md" % (score, scores, counts, out, suffix))


def write_matrix():
    import jobs
    path = os.path.join(HERE, "matrix.md")
    text = open(path).read()
    start, end = "<!-- jobs:begin -->", "<!-- jobs:end -->"
    rows, group = [], None
    for j in jobs.JOBS:
        if j.group != group:
            group = j.group
            rows += ["", "### %s" % jobs.GROUPS[group], "",
                     "| Job | Copper tool / CLI | Fixture | Check | Seed |", "|---|---|---|---|---|"]
        rows.append("| `%s` %s | `%s` | `%s` | %s | %s |" % (j.id, j.title, j.tool, j.fixture, j.check, j.seed or ""))
    head, _, rest = text.partition(start)
    _, _, tail = rest.partition(end)
    with open(path, "w") as f:
        f.write(head + start + "\n" + "\n".join(rows) + "\n\n" + end + tail)
    print("matrix.md: %d jobs" % len(jobs.JOBS))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app")
    ap.add_argument("--out")
    ap.add_argument("--label", default="adhoc")
    ap.add_argument("--world", default="hc-cov")
    ap.add_argument("--port", type=int, default=4150)
    ap.add_argument("--fixtures", type=int, default=8795)
    ap.add_argument("--only")
    ap.add_argument("--keep", action="store_true", help="leave the world running")
    ap.add_argument("--repeat", type=int, default=1, help="runs, for the noise band (each on a fresh world)")
    ap.add_argument("--mode", choices=["headless", "windowed"], default="headless",
                    help="windowed: a probe window on the Mac's screen (alert sheets, real focus) — not on the laptop")
    ap.add_argument("--matrix", action="store_true")
    a = ap.parse_args()
    if a.matrix:
        write_matrix()
    else:
        run(a)


if __name__ == "__main__":
    # Run as the module `run`, so jobs.py raises the same Fail/Missing classes this catches.
    sys.path.insert(0, HERE)
    import run as _run
    _run.main()
