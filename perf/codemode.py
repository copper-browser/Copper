#!/usr/bin/env python3
"""Code mode (copper_run) against the same work done call by call, on a
headless probe-world Copper (docs/agents.md › Code mode).

    SEARCH_PROBE=codemode SEARCH_HEADLESS=1 SEARCH_MCP_PORT=4135 build/Copper.app/Contents/MacOS/Copper --headless &
    python3 -m http.server 8798 -d /tmp/codemode-pages &      # five small pages, see pages()
    perf/codemode.py --world codemode --port 4135 check        # the correctness cases
    perf/codemode.py --world codemode --port 4135 canvas 3     # task (a): a 60-shape board, 3 rounds
    perf/codemode.py --world codemode --port 4135 pages 3      # task (b): five pages' title and h1

Two arms per task. `direct` is what an agent does today: one tools/call per
step, each a model turn. `script` is one copper_run that does the same steps.
Per round: wall ms over all the MCP round trips, the number of round trips,
and (for the harness's estimate) the model turns an agent would spend — one
per round trip. The canvas task runs on the probe world's own Personal canvas
and wipes it between rounds; never point this at a Copper somebody uses.
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

PAGES = [
    ("Quarterly plan", "Q4 priorities"),
    ("Hiring", "Open roles"),
    ("Runbook", "Deploying the canvas app"),
    ("Retro notes", "What went well"),
    ("Budget", "FY27 envelope"),
]


class Copper:
    """The loopback MCP server of a running Copper, by its world's agent.json."""

    def __init__(self, world, port=None, token=None):
        path = os.path.expanduser(f"~/Library/Application Support/Copper ({world})/agent.json")
        config = {}
        if os.path.exists(path):
            with open(path) as f:
                config = json.load(f)
        self.port = port or config.get("port", 4123)
        self.token = token or config.get("token", "")
        if not self.token:
            sys.exit(f"no token: {path} has none and --token was not given")
        self.url = f"http://127.0.0.1:{self.port}/mcp"
        self.n = 0
        self.trips = 0

    def rpc(self, method, params, timeout=330):
        self.n += 1
        self.trips += 1
        body = {"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)

    def raw(self, tool, arguments, timeout=330):
        """The whole tools/call result: {content, isError, _meta}."""
        reply = self.rpc("tools/call", {"name": tool, "arguments": arguments}, timeout)
        if "error" in reply:
            raise RuntimeError(reply["error"].get("message", str(reply["error"])))
        return reply.get("result", {})

    def call(self, tool, arguments, timeout=330):
        result = self.raw(tool, arguments, timeout)
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        if result.get("isError"):
            raise RuntimeError(text.strip() or "tool error")
        return text

    def run(self, script, **extra):
        """copper_run, parsed: (ok, answer dict)."""
        args = {"script": script, "reason": "perf/codemode.py"}
        args.update(extra)
        result = self.raw("copper_run", args)
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        try:
            answer = json.loads(text)
        except json.JSONDecodeError:
            answer = {"raw": text}
        return (not result.get("isError", False)), answer


def median(xs):
    return statistics.median(xs) if xs else None


def fmt(ms):
    return "—" if ms is None else f"{ms:.0f} ms"


# MARK: - correctness

def check(copper, bench):
    results = []

    def case(name, ok, note=""):
        results.append((name, ok, note))
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f" — {note}" if note else ""))

    print("checks")
    # The catalogue lists both tools, and the d.ts comes back from tool and resource.
    tools = copper.rpc("tools/list", {})["result"]["tools"]
    names = {t["name"] for t in tools}
    case("copper_run and copper_types listed", {"copper_run", "copper_types"} <= names)
    dts = copper.call("copper_types", {})
    case("copper_types is a declaration file", "declare const copper: Copper" in dts and "interface CopperBrowser" in dts, f"{len(dts)} chars")
    resources = copper.rpc("resources/list", {})["result"]["resources"]
    read = copper.rpc("resources/read", {"uri": "copper://types/copper.d.ts"})["result"]
    case("resource copper://types/copper.d.ts", any(r["uri"] == "copper://types/copper.d.ts" for r in resources) and read["contents"][0]["text"] == dts)
    # Every tool in the catalogue has a method on the object, and none of copper_*.
    ok, a = copper.run("return copper.tools")
    case("copper.tools is the catalogue less copper_*", ok and set(a["value"]) == names - {"copper_run", "copper_types"}, f"{len(a.get('value', []))} tools")

    # Several tools in one script, the value and logs coming back.
    ok, a = copper.run("""
        const tabs = await copper.browser.tabs({action: "list", reason: "which tabs"});
        console.log("tabs:", tabs.text.split("\\n").length, "lines");
        const canvases = await copper.canvas.list({reason: "which canvases"});
        const read = await copper.canvas.read({overview: true, reason: "how big is Personal"});
        return {tabs: tabs.text.length > 0, canvases: canvases.json.canvases.length, total: read.json.total, summary: read.summary};
    """)
    case("several tools in one script", ok and a["ok"] and a["calls"] == 3 and a["value"]["canvases"] >= 1 and len(a["logs"]) == 1,
         f"calls={a.get('calls')} value={a.get('value')} logs={a.get('logs')}")

    # An error inside a tool rejects with the tool's name, catchable.
    ok, a = copper.run("""
        try { await copper.browser.navigate({url: ""}); return "no error"; }
        catch (e) { return {name: e.name, tool: e.tool, message: e.message}; }
    """)
    v = a.get("value", {})
    case("a tool's error rejects with .tool", ok and v.get("name") == "CopperToolError" and v.get("tool") == "browser_navigate" and "url" in v.get("message", ""), str(v))
    case("…and the callLog says so", a["callLog"][0]["tool"] == "browser_navigate" and "error" in a["callLog"][0])

    # Argument validation identical to a direct call: the same handler, the same words.
    direct = copper.raw("browser_navigate", {"url": ""})
    direct_text = direct["content"][0]["text"]
    case("argument validation identical to a direct call", direct.get("isError") and v.get("message") == direct_text, f"direct={direct_text!r}")
    direct = copper.raw("browser_click", {})
    ok, a = copper.run("try { await copper.browser.click({}); } catch (e) { return e.message }")
    case("…for a missing ref too", direct.get("isError") and a.get("value") == direct["content"][0]["text"], str(a.get("value")))
    direct = copper.raw("canvas_apply", {})
    ok, a = copper.run("try { await copper.canvas.apply({}); } catch (e) { return e.message }")
    case("…and canvas_apply without ops", direct.get("isError") and a.get("value") == direct["content"][0]["text"], str(a.get("value")))

    # A thrown error: message and the script's own line.
    ok, a = copper.run("const a = 1;\nconst b = 2;\nthrow new TypeError('boom at three');\nreturn a + b;")
    e = a.get("error", {})
    case("a thrown error is a tool error with message and line", (not ok) and e.get("message") == "boom at three" and e.get("line") == 3 and e.get("name") == "TypeError", str(e))
    ok, a = copper.run("const x = 1;\nreturn x +;")
    e = a.get("error", {})
    case("a syntax error names its line", (not ok) and e.get("name") == "SyntaxError" and e.get("line") == 2, str(e))
    ok, a = copper.run("return undefined_thing.foo")
    e = a.get("error", {})
    case("a ReferenceError at line 1", (not ok) and e.get("name") == "ReferenceError" and e.get("line") == 1, str(e))

    # Nothing but copper: no network, no modules, no timers, no DOM.
    ok, a = copper.run("""
        const absent = {};
        for (const k of ["fetch", "XMLHttpRequest", "require", "WebSocket", "setTimeout", "setInterval", "document", "window", "process", "importScripts", "navigator", "indexedDB", "localStorage", "Worker", "SharedArrayBuffer", "Atomics", "queueMicrotask", "structuredClone"]) absent[k] = typeof globalThis[k];
        let dyn = "ok";
        try { await import("fs"); } catch (e) { dyn = e.name + ": " + e.message; }
        let statik = "n/a";
        try { (0, eval)("import x from 'fs'"); statik = "ran"; } catch (e) { statik = e.name; }
        return {absent, dyn, statik};
    """)
    v = a.get("value", {})
    present = {k: t for k, t in v.get("absent", {}).items() if t != "undefined" and k not in ("Atomics", "SharedArrayBuffer", "queueMicrotask", "structuredClone")}
    case("fetch, XMLHttpRequest, require, WebSocket, timers, DOM absent", ok and not present, f"present={present} import()={v.get('dyn')} static import={v.get('statik')}")
    case("import() rejects", ok and v.get("dyn") != "ok", str(v.get("dyn")))
    case("static import is a SyntaxError", ok and v.get("statik") == "SyntaxError", str(v.get("statik")))
    # The doors are gone and copper is sealed.
    ok, a = copper.run("""
        const r = {native: typeof globalThis.__copperNative, tools: typeof globalThis.__copperTools};
        try { copper.browser = null; r.reassigned = copper.browser === null; } catch (e) { r.reassigned = e.name; }
        try { copper.browser.tabs = () => 1; r.patched = copper.browser.tabs() === 1; } catch (e) { r.patched = e.name; }
        try { globalThis.copper = 1; r.global = globalThis.copper === 1; } catch (e) { r.global = e.name; }
        return r;
    """)
    v = a.get("value", {})
    case("the native doors are gone and copper is frozen", ok and v.get("native") == "undefined" and v.get("tools") == "undefined"
         and v.get("reassigned") in (False, "TypeError") and v.get("patched") in (False, "TypeError") and v.get("global") in (False, "TypeError"), str(v))
    # A script cannot reach copper_run or copper_types.
    ok, a = copper.run("try { await copper.call('copper_run', {script: 'return 1'}); return 'ran'; } catch (e) { return e.message }")
    case("copper_run is not reachable from a script", ok and "no tool named copper_run" in str(a.get("value")), str(a.get("value")))
    ok, a = copper.run("try { await copper.call('copper_types', {}); return 'ran'; } catch (e) { return e.message }")
    case("nor copper_types", ok and "no tool named copper_types" in str(a.get("value")), str(a.get("value")))

    # The timeout: a spinning script, and one waiting on calls.
    t = time.time()
    ok, a = copper.run("let n = 0; while (true) { n++; } return n;", timeout=2)
    e = a.get("error", {})
    case("timeout ends a spinning script", (not ok) and e.get("name") == "Timeout" and time.time() - t < 6, f"{time.time() - t:.1f} s {e}")
    t = time.time()
    ok, a = copper.run("for (let i = 0; i < 100; i++) { await copper.sleep(500); await copper.browser.tabs({action: 'list'}); } return 'done';", timeout=2)
    e = a.get("error", {})
    case("timeout ends a script between calls", (not ok) and e.get("name") == "Timeout" and time.time() - t < 6 and 1 <= a.get("calls", 0) <= 6, f"{time.time() - t:.1f} s calls={a.get('calls')} {e}")
    ok, a = copper.run("return 1", timeout=100000)
    case("timeout is capped (a huge one still runs)", ok and a.get("value") == 1)

    # The call cap.
    ok, a = copper.run("""
        let rejected = null, made = 0;
        for (let i = 0; i < 10; i++) { try { await copper.browser.tabs({action: "list"}); made++; } catch (e) { rejected = e.message; break; } }
        return {made, rejected};
    """, maxCalls=3)
    v = a.get("value", {})
    case("call cap rejects the call past it", ok and v.get("made") == 3 and "call cap of 3" in str(v.get("rejected")) and a.get("callCapReached") is True, str(v))

    # Output caps.
    ok, a = copper.run("for (let i = 0; i < 1000; i++) console.log('line', i); return 'x'.repeat(300000);")
    case("logs cut at 200 lines, value at 256 KB", ok and len(a["logs"]) == 200 and a.get("logsDropped") == 800 and a.get("valueTruncated") is True and len(a["value"]) <= 256000,
         f"logs={len(a.get('logs', []))} dropped={a.get('logsDropped')} truncated={a.get('valueTruncated')}")

    # The return value: JSON only; a cycle is the script's error.
    ok, a = copper.run("const o = {}; o.self = o; return o;")
    case("a cyclic return value is a TypeError", (not ok) and a.get("error", {}).get("name") == "TypeError", str(a.get("error")))
    ok, a = copper.run("return {f: () => 1, u: undefined, n: null, d: new Date(0), big: 2 ** 53}")
    case("functions and undefined drop out of the value", ok and a.get("value") == {"n": None, "d": "1970-01-01T00:00:00.000Z", "big": 2 ** 53}, str(a.get("value")))
    ok, a = copper.run("// nothing returned")
    case("no return is null", ok and a.get("value") is None)
    # Arguments must be an object.
    ok, a = copper.run("try { await copper.browser.tabs([1]); } catch (e) { return e.name + ': ' + e.message }")
    case("array arguments are a TypeError in the script", ok and str(a.get("value", "")).startswith("TypeError"), str(a.get("value")))
    ok, a = copper.run("const t = await copper.browser.tabs(); return typeof t.text")
    case("no arguments is {}", ok and a.get("value") == "string")

    # Stop: the user's Stop ends the run with the refusal, and the next direct call is refused too.
    if bench:
        box = {}

        def stop_later():
            time.sleep(2.5)
            box["stop"] = subprocess.run(bench + ["drive", "stop"], capture_output=True, text=True).stdout.strip()

        threading.Thread(target=stop_later, daemon=True).start()
        t = time.time()
        ok, a = copper.run("""
            let n = 0;
            for (let i = 0; i < 40; i++) { await copper.browser.tabs({action: "list", reason: "stop me"}); n++; await copper.sleep(300); }
            return n;
        """, timeout=30)
        e = a.get("error", {})
        case("Stop ends the run with the refusal", (not ok) and e.get("name") == "Stopped" and "Stopped by the user" in e.get("message", "") and time.time() - t < 10,
             f"{time.time() - t:.1f} s calls={a.get('calls')} bench={box.get('stop')!r} {e.get('message', '')[:60]}")
        direct = copper.raw("browser_tabs", {"action": "list"})
        case("…and the next direct call is refused the same way", direct.get("isError") and "Stopped by the user" in direct["content"][0]["text"])
        subprocess.run(bench + ["drive", "resume"], capture_output=True, text=True)
        ok, a = copper.run("return (await copper.browser.tabs({action: 'list'})).text.length > 0")
        case("after Let it back in, scripts run again", ok and a.get("value") is True, str(a.get("error")))
    else:
        print("  skip  Stop (no --bench)")

    failed = [r for r in results if not r[1]]
    print(f"{len(results) - len(failed)} of {len(results)} passed")
    return not failed


# MARK: - task (a): a 60-shape board

def board_ops(n=60):
    ops = []
    for i in range(n):
        col, row = i % 10, i // 10
        kind = ["sticky", "text", "sticky", "sticky", "frame", "sticky"][row]
        shape = {"type": kind, "id": f"n{i}", "x": 40 + col * 230, "y": 40 + row * 190, "w": 200, "h": 140,
                 "color": ["yellow", "pink", "blue", "green", "purple", "gray"][col % 6]}
        if kind == "frame":
            shape["title"] = f"Frame {i}"
        else:
            shape["text"] = f"Item {i}: a short note about step {i} of the plan"
        ops.append({"op": "add", "shape": shape})
    return ops


def canvas_direct(copper):
    """What an agent does today: read first, add in calls of ≤ 40 ops, connect, focus."""
    ops = board_ops()
    copper.call("canvas_read", {"overview": True, "reason": "what is on the board"})
    ids = []
    for i in range(0, len(ops), 30):
        text = copper.call("canvas_apply", {"ops": ops[i:i + 30], "reason": "the plan, row by row"})
        ids += json.loads(text).get("ids", [])
    copper.call("canvas_apply", {"ops": [{"op": "connect", "from": f"n{i}", "to": f"n{i + 1}", "label": f"→ {i + 1}"} for i in range(0, 20, 2)], "reason": "the arrows"})
    copper.call("canvas_focus", {"shapeIds": [f"n{i}" for i in range(10)], "reason": "show the first row"})
    return len(ids)


CANVAS_SCRIPT = """
const ops = %s;
await copper.canvas.read({overview: true, reason: "what is on the board"});
let ids = [];
for (let i = 0; i < ops.length; i += 30) {
  const a = await copper.canvas.apply({ops: ops.slice(i, i + 30), reason: "the plan, row by row"});
  ids = ids.concat(a.json.ids || []);
}
const arrows = [];
for (let i = 0; i < 20; i += 2) arrows.push({op: "connect", from: "n" + i, to: "n" + (i + 1), label: "→ " + (i + 1)});
await copper.canvas.apply({ops: arrows, reason: "the arrows"});
await copper.canvas.focus({shapeIds: ids.slice(0, 10), reason: "show the first row"});
return ids.length;
"""


def canvas_script(copper):
    ok, a = copper.run(CANVAS_SCRIPT % json.dumps(board_ops()))
    if not ok:
        raise RuntimeError(json.dumps(a.get("error")))
    return a["value"]


def canvas_clear(copper):
    copper.call("canvas_apply", {"ops": [{"op": "clear", "confirm": True}], "reason": "perf/codemode.py: wipe the probe world's Personal between rounds"})


# MARK: - task (b): five pages' title and h1

def pages(base):
    """Write the five pages for `python3 -m http.server 8798 -d DIR`."""
    os.makedirs(base, exist_ok=True)
    for i, (title, h1) in enumerate(PAGES, 1):
        with open(os.path.join(base, f"p{i}.html"), "w") as f:
            f.write(f"<!doctype html><html><head><meta charset='utf-8'><title>{title}</title></head>"
                    f"<body><h1>{h1}</h1><p>Page {i} of {len(PAGES)}.</p></body></html>")


def pages_direct(copper, base):
    rows = []
    for i in range(1, len(PAGES) + 1):
        opened = copper.call("browser_tabs", {"action": "new", "url": f"{base}/p{i}.html", "reason": f"open page {i}"})
        got = copper.call("browser_evaluate", {"function": "() => JSON.stringify([document.title, document.querySelector('h1')?.innerText])", "reason": "its title and h1"})
        v = json.loads(got)
        if isinstance(v, str):
            v = json.loads(v)
        rows.append(v)
        copper.call("browser_close", {"reason": "done with it"})
    return rows


PAGES_SCRIPT = """
const rows = [];
for (let i = 1; i <= %d; i++) {
  await copper.browser.tabs({action: "new", url: "%s/p" + i + ".html", reason: "open page " + i});
  const got = await copper.browser.evaluate({function: "() => JSON.stringify([document.title, document.querySelector('h1')?.innerText])", reason: "its title and h1"});
  let v = got.json !== undefined ? got.json : got.text;
  if (typeof v === "string") v = JSON.parse(v);
  rows.push(v);
  await copper.browser.close({reason: "done with it"});
}
return rows;
"""


def pages_script(copper, base):
    ok, a = copper.run(PAGES_SCRIPT % (len(PAGES), base))
    if not ok:
        raise RuntimeError(json.dumps(a.get("error")))
    return a["value"]


# MARK: - the comparison

def compare(copper, task, rounds, base):
    expected_pages = [list(p) for p in PAGES]
    arms = {"direct": [], "script": []}
    trips = {"direct": [], "script": []}
    for r in range(rounds):
        for arm in (("direct", "script") if r % 2 == 0 else ("script", "direct")):
            if task == "canvas":
                canvas_clear(copper)
                time.sleep(0.5)
            copper.trips = 0
            t = time.time()
            if task == "canvas":
                out = canvas_direct(copper) if arm == "direct" else canvas_script(copper)
                good = out == 60
            else:
                out = pages_direct(copper, base) if arm == "direct" else pages_script(copper, base)
                good = out == expected_pages
            ms = (time.time() - t) * 1000
            arms[arm].append(ms)
            trips[arm].append(copper.trips)
            print(f"  round {r + 1} {arm:6s} {ms:7.0f} ms  {copper.trips:2d} round trips  {'ok' if good else 'WRONG: ' + str(out)[:80]}")
    if task == "canvas":
        canvas_clear(copper)
    d, s = median(arms["direct"]), median(arms["script"])
    print(f"\n{task}: direct median {fmt(d)} over {int(median(trips['direct']))} round trips (n={rounds}); "
          f"copper_run median {fmt(s)} over {int(median(trips['script']))} round trip (n={rounds}); "
          f"wall {d / s:.2f}× ; model turns {int(median(trips['direct']))} → 1")
    return {"task": task, "direct_ms": arms["direct"], "script_ms": arms["script"], "direct_trips": trips["direct"], "script_trips": trips["script"]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", default="codemode")
    ap.add_argument("--port", type=int)
    ap.add_argument("--token")
    ap.add_argument("--pages", default="http://127.0.0.1:8798", help="where the five pages are served from")
    ap.add_argument("--write-pages", metavar="DIR", help="write the five pages into DIR and exit")
    ap.add_argument("--bench", help="the bench command for Stop, e.g. './bench --world codemode'")
    ap.add_argument("--out", help="append the rounds as JSON lines here")
    ap.add_argument("what", nargs="?", default="check", choices=["check", "canvas", "pages", "all"])
    ap.add_argument("rounds", nargs="?", type=int, default=3)
    a = ap.parse_args()
    if a.write_pages:
        pages(a.write_pages)
        print(f"wrote {len(PAGES)} pages to {a.write_pages}")
        return 0
    copper = Copper(a.world, a.port, a.token)
    bench = a.bench.split() if a.bench else None
    ok = True
    results = []
    if a.what in ("check",):
        ok = check(copper, bench)
    if a.what in ("canvas", "all"):
        results.append(compare(copper, "canvas", a.rounds, a.pages))
    if a.what in ("pages", "all"):
        results.append(compare(copper, "pages", a.rounds, a.pages))
    if a.out and results:
        with open(a.out, "a") as f:
            for r in results:
                r["at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
                f.write(json.dumps(r) + "\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
