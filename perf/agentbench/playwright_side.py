"""Playwright MCP side for Ardia's browser-agent bench (drop into plugins/cli/bench/harness/ beside copper_side.py).

Every run gets a fresh headless Google Chrome (a copy, never /Applications) with a throwaway profile and DevTools on
`cdp_port`, opened on the task's start URL, as opencode_side does with Chrome for Testing. The agent starts
Playwright MCP (`@playwright/mcp`, installed once in `pw_dir`, version recorded) over stdio with `--cdp-endpoint`,
so it attaches to that browser and finds the start page as its current tab. Chrome is stopped after the run.
"""
import json
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path

import ardia_side
import registry
from copper_side import log as _log, run_mcp_side
from procs import kill_group, listener_pids, proc_info, wait_until

DEFAULTS = {
    "chrome": str(registry.HOME / "chrome/Google Chrome.app"),
    "pw_dir": str(registry.HOME.parent / "pw"),
    "node": "/opt/homebrew/bin/node",
    "cdp_port": 4623,
    "window_size": "1280,800",
    "reach_line": "Use the `playwright` MCP server to reach this browser.",
}
SERVER = "playwright"


def log(msg):
    _log(f"(playwright) {msg}")


def options(overrides=None):
    opts = dict(DEFAULTS)
    opts.update({k: v for k, v in (overrides or {}).items() if v is not None})
    opts["cdp_port"] = int(opts["cdp_port"])
    return opts


def chrome_binary(opts):
    real = Path(opts["chrome"]).expanduser().resolve()
    if str(real).startswith("/Applications/"):
        raise SystemExit("refusing an installed Chrome; copy it into the bench home")
    exe = real / "Contents/MacOS/Google Chrome"
    if not exe.exists():
        raise SystemExit(f"no Google Chrome at {real}")
    return exe


def pw_cli(opts):
    cli = Path(opts["pw_dir"]).expanduser() / "node_modules/@playwright/mcp/cli.js"
    if not cli.exists():
        raise SystemExit(f"no @playwright/mcp in {opts['pw_dir']}; run: npm i @playwright/mcp@latest there")
    return cli


def pw_version(opts):
    pkg = Path(opts["pw_dir"]).expanduser() / "node_modules/@playwright/mcp/package.json"
    return json.loads(pkg.read_text())["version"]


def devtools(opts, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{opts['cdp_port']}{path}", timeout=10) as r:
        return json.loads(r.read())


def launch_chrome(opts, task):
    if listener_pids(opts["cdp_port"]):
        raise SystemExit(f"CDP port {opts['cdp_port']} is used by pid {listener_pids(opts['cdp_port'])}")
    home = registry.HOME / "playwright-lane"
    shutil.rmtree(home, ignore_errors=True)
    (home / "profile").mkdir(parents=True)
    exe = chrome_binary(opts)
    t0 = time.monotonic()
    log_file = open(home / "chrome.log", "wb")
    proc = subprocess.Popen([str(exe), "--headless=new", f"--remote-debugging-port={opts['cdp_port']}",
                             f"--user-data-dir={home / 'profile'}", f"--window-size={opts['window_size']}",
                             "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
                             task["start_url"]],
                            stdin=subprocess.DEVNULL, stdout=log_file, stderr=log_file, start_new_session=True)
    try:
        version = wait_until(lambda: devtools(opts, "/json/version"), 60, "Chrome DevTools", pid=proc.pid)

        def one_tab():
            pages = [t for t in devtools(opts, "/json/list") if t.get("type") == "page"]
            return pages if len(pages) == 1 and pages[0].get("url") == task["start_url"] and pages[0].get("title") else None

        pages = wait_until(one_tab, 30, f"one tab on {task['start_url']}", pid=proc.pid)
    except BaseException:
        kill_group(proc, grace=3)
        raise
    info = proc_info(proc.pid) or {}
    return proc, {"pid": proc.pid, "lstart": info.get("lstart"), "browser": version.get("Browser"),
                  "user_agent": version.get("User-Agent"), "tab_before_run": [[p["url"], p["title"]] for p in pages],
                  "setup_s": round(time.monotonic() - t0, 2), "profile": str(home / "profile")}


def run(task_id, agent, run_id, results_dir, overrides=None, contender=None, on_agent_start=None):
    opts = options(overrides)
    server = {"command": opts["node"],
              "args": [str(pw_cli(opts)), "--cdp-endpoint", f"http://127.0.0.1:{opts['cdp_port']}"],
              "env": {}}
    claude_server = {"type": "stdio", **server}
    codex_flags = ["-c", f"mcp_servers.{SERVER}.command={json.dumps(server['command'])}",
                   "-c", f"mcp_servers.{SERVER}.args={json.dumps(server['args'])}"]
    held = {}

    def prepare(task):
        proc, instance = launch_chrome(opts, task)
        held["proc"] = proc
        instance.update(playwright_mcp=pw_version(opts), cdp_port=opts["cdp_port"], mcp_server=server)
        return instance, claude_server, codex_flags, {}

    def finish():
        proc = held.get("proc")
        if not proc:
            return []
        kill_group(proc, grace=5)
        return [f"chrome {proc.pid}"]

    return run_mcp_side("playwright", task_id, agent, run_id, results_dir, opts, contender, prepare, finish,
                        SERVER, on_agent_start)
