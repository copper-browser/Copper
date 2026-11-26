"""Copper side for Ardia's browser-agent bench (drop into plugins/cli/bench/harness/).

Claude Code / Codex reach Copper through Copper's built-in MCP server (Streamable HTTP on
http://127.0.0.1:<port>/mcp, bearer token from the world's agent.json). The browser is a headless probe world of a
copy of the release app, started as a LaunchAgent in the GUI session (as perf/hillclimb/agentbench.sh does). Jev is
off and the world has no intelligence.json, so no tool can spend tokens inside Copper; the tool list the agent saw
is checked and kept in every record.

`run_mcp_side` is shared with playwright_side.py: everything after "the browser is ready on the start page" is the
same for both MCP sides, modelled on opencode_side.run (the bench's other MCP side).
"""
import datetime
import json
import os
import plistlib
import secrets
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path

import ardia_side
import grading
import registry
import servers
from procs import http, kill_group, listener_pids, proc_info, read_json, read_jsonl, sh, spawn_agent, write_json

DEFAULTS = {
    "app": str(registry.HOME / "copper/Copper.app"),
    "world": "xbagent",
    "port": 4620,
    "reach_line": "Use the `copper` MCP server to reach this browser.",
}
SERVER = "copper"
TOKEN_ENV = "COPPER_MCP_TOKEN"
# Tools that would run a model inside Copper (and so hide tokens from the count). None may be listed.
LLM_TOOL_PREFIXES = ("jev_", "copper_research")
MCP_PROTOCOL = "2025-06-18"


def log(msg):
    ardia_side.log(f"copper: {msg}")


def options(overrides=None):
    opts = dict(DEFAULTS)
    opts.update({k: v for k, v in (overrides or {}).items() if v is not None})
    opts["port"] = int(opts["port"])
    return opts


def world_dir(opts):
    return Path.home() / "Library/Application Support" / f"Copper ({opts['world']})"


def label(opts):
    return f"dev.xbagent.copper.{opts['world']}"


def state_path(opts):
    return registry.STATE_DIR / f"copper-{opts['world']}.json"


def app_path(opts):
    real = Path(opts["app"]).expanduser().resolve()
    if str(real).startswith("/Applications/") or real == (Path.home() / ".grunts/Copper.app").resolve():
        raise SystemExit("refusing an installed Copper; copy the app into the bench home")
    if not (real / "Contents/MacOS/Copper").exists():
        raise SystemExit(f"no Copper app at {real}")
    return real


def token(opts):
    return json.loads((world_dir(opts) / "agent.json").read_text())["token"]


def write_world(opts):
    folder = world_dir(opts)
    folder.mkdir(parents=True, exist_ok=True)
    folder.chmod(0o700)
    path = folder / "agent.json"
    cur = read_json(path, {}) or {}
    cur.update({"enabled": True, "port": opts["port"], "announces": False, "jev": False})
    cur.setdefault("token", secrets.token_hex(32))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(cur, f)
    (folder / "intelligence.json").unlink(missing_ok=True)  # no model keys: nothing in Copper can call an LLM
    sh(["defaults", "write", f"com.collinrijock.copper.test.{opts['world']}", "welcomed", "-bool", "true"])


def owned_pid(opts):
    exe = str(app_path(opts) / "Contents/MacOS/Copper")
    for pid in listener_pids(opts["port"]):
        info = proc_info(pid)
        if info and info["command"].startswith(exe):
            return pid
    return None


def launch(opts):
    if listener_pids(opts["port"]):
        raise SystemExit(f"port {opts['port']} is used by pid {listener_pids(opts['port'])}, not our Copper")
    write_world(opts)
    plist = registry.STATE_DIR / f"{label(opts)}.plist"
    plist.parent.mkdir(parents=True, exist_ok=True)
    logs = registry.HOME / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    plist.write_bytes(plistlib.dumps({
        "Label": label(opts),
        "EnvironmentVariables": {"SEARCH_PROBE": opts["world"], "SEARCH_HEADLESS": "1",
                                 "SEARCH_MCP_PORT": str(opts["port"])},
        "KeepAlive": False, "RunAtLoad": True, "LimitLoadToSessionType": "Aqua",
        "ProgramArguments": [str(app_path(opts) / "Contents/MacOS/Copper")],
        "StandardErrorPath": str(logs / f"copper-{opts['world']}.log"),
        "StandardOutPath": str(logs / f"copper-{opts['world']}.out"),
    }))
    domain = f"gui/{os.getuid()}"
    sh(["launchctl", "bootout", f"{domain}/{label(opts)}"])
    t0 = time.monotonic()
    sh(["launchctl", "bootstrap", domain, str(plist)]).check_returncode()
    end = time.monotonic() + 90
    while time.monotonic() < end and not owned_pid(opts):
        time.sleep(0.5)
    pid = owned_pid(opts)
    if not pid:
        raise RuntimeError(f"Copper probe {opts['world']} did not listen on {opts['port']}")
    info = proc_info(pid)
    state = {"pid": pid, "lstart": info["lstart"], "command": info["command"], "port": opts["port"],
             "world": opts["world"], "launch_s": round(time.monotonic() - t0, 2)}
    write_json(state_path(opts), state)
    log(f"launched probe {opts['world']} pid {pid} on {opts['port']} in {state['launch_s']} s")
    return state


def ensure_world(opts):
    state = read_json(state_path(opts))
    pid = owned_pid(opts)
    if state and pid == state.get("pid"):
        return state, True
    return launch(opts), False


def quit_world(opts=None):
    opts = options(opts)
    r = sh(["launchctl", "bootout", f"gui/{os.getuid()}/{label(opts)}"])
    state_path(opts).unlink(missing_ok=True)
    return r.returncode == 0


class MCPClient:
    """A minimal Streamable-HTTP MCP client (JSON answers), for the harness's own calls only."""

    def __init__(self, url, bearer=None):
        self.url, self.bearer, self.session, self.n = url, bearer, None, 0
        result = self.rpc("initialize", {"protocolVersion": MCP_PROTOCOL, "capabilities": {},
                                         "clientInfo": {"name": "xbench-harness", "version": "1"}})
        self.instructions = result.get("instructions")
        self.server_info = result.get("serverInfo")
        self.rpc("notifications/initialized", notify=True)

    def rpc(self, method, params=None, notify=False, timeout=60):
        body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if not notify:
            self.n += 1
            body["id"] = self.n
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.bearer:
            headers["Authorization"] = f"Bearer {self.bearer}"
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            self.session = r.headers.get("Mcp-Session-Id") or self.session
            raw = r.read().decode()
        if notify or not raw.strip():
            return None
        if raw.lstrip().startswith("event:") or raw.lstrip().startswith("data:"):
            raw = next(line[5:] for line in raw.splitlines() if line.startswith("data:"))
        msg = json.loads(raw)
        if "error" in msg:
            raise RuntimeError(f"{method}: {msg['error']}")
        return msg["result"]

    def tools(self):
        return [t["name"] for t in self.rpc("tools/list")["tools"]]

    def call(self, name, args):
        result = self.rpc("tools/call", {"name": name, "arguments": args})
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if isinstance(c, dict))
        if result.get("isError"):
            raise RuntimeError(f"{name}: {text[:400]}")
        return text


def tab_ids(listing):
    return [line.rsplit("{tab ", 1)[1].rstrip("}").strip() for line in listing.splitlines() if "{tab " in line]


def prepare_tab(opts, task):
    """Leave exactly one tab, on the task's start URL, shown in the window (the tab an agent without one of its
    own works on), like ardia_side.prepare_tab does through DevTools."""
    client = MCPClient(f"http://127.0.0.1:{opts['port']}/mcp", token(opts))
    tools = client.tools()
    banned = [t for t in tools if t.startswith(LLM_TOOL_PREFIXES)]
    if banned:
        raise RuntimeError(f"Copper lists tools that run a model inside it: {banned}; set jev false in agent.json")
    opened = client.call("browser_tabs", {"action": "new", "url": task["start_url"], "focus": True})
    keep = opened.split("{tab ", 1)[1].split("}", 1)[0].strip()
    for tid in tab_ids(client.call("browser_tabs", {"action": "list"})):
        if tid != keep:
            client.call("browser_tabs", {"action": "close", "tab": tid})
    listing = client.call("browser_tabs", {"action": "list"})
    if tab_ids(listing) != [keep] or task["start_url"] not in listing:
        raise RuntimeError(f"tab prep: {listing[:600]}")
    return {"tab": keep, "tabs_before_run": listing, "tools": tools, "server": client.server_info,
            "instructions_chars": len(client.instructions or "")}


# ---- shared by the MCP sides (copper, playwright) -------------------------------------------------------------

def mcp_calls(agent, server, events):
    """Calls to `server`'s MCP tools, shell commands and other tools at the agent's top level."""
    calls, shell, other = [], [], []
    prefix = f"mcp__{server}__"
    for e in events:
        if agent == "claude":
            if e.get("type") != "assistant" or e.get("parent_tool_use_id"):
                continue
            for block in e.get("message", {}).get("content", []):
                if block.get("type") != "tool_use":
                    continue
                name = block.get("name") or ""
                if name.startswith(prefix):
                    calls.append(name[len(prefix):])
                elif name in ardia_side.SHELL_TOOLS:
                    shell.append((block.get("input") or {}).get("command"))
                else:
                    other.append(name)
        elif e.get("type") == "item.completed":
            item = e.get("item", {})
            kind = item.get("type")
            if kind == "mcp_tool_call" and item.get("server") == server:
                calls.append(item.get("tool"))
            elif kind == "command_execution":
                shell.append(item.get("command"))
            elif kind not in ("reasoning", "todo_list", "agent_message", "error"):
                other.append(kind if kind != "mcp_tool_call" else f"{item.get('server')}.{item.get('tool')}")
    by_tool = {}
    for c in calls:
        by_tool[c] = by_tool.get(c, 0) + 1
    return {"mcp_calls": len(calls), "mcp_by_tool": by_tool, "shell_commands": len(shell), "shell": shell,
            "other_tools": other}


def claude_command(model, effort, prompt, mcp_config):
    cmd = ardia_side.claude_command(model, effort, prompt)
    return cmd[:2] + ["--mcp-config", str(mcp_config)] + cmd[2:]


def codex_command(model, effort, workdir, prompt, flags):
    return ardia_side.codex_command(model, effort, workdir, prompt)[:-1] + flags + [prompt]


def run_mcp_side(side, task_id, agent, run_id, results_dir, opts, contender, prepare, finish, server,
                 on_agent_start=None):
    """prepare(task) -> (instance dict, claude server config, codex -c flags, extra env); finish() -> stopped list.
    Runs one cold agent run and writes runs/<run_id>.json with the bench's record fields."""
    if agent not in ardia_side.MODELS:
        raise SystemExit("agent must be claude or codex")
    task = registry.task(task_id, int(opts.get("port_offset") or 0))
    model = opts.get("model") or ardia_side.MODELS[agent][0]
    effort = opts.get("effort") or ardia_side.MODELS[agent][1]
    deadline = int(opts.get("deadline_s") or task["deadline_s"])
    runs_dir = Path(results_dir) / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)
    out_json = runs_dir / f"{run_id}.json"
    events = runs_dir / f"{run_id}.events.jsonl"
    stderr = runs_dir / f"{run_id}.stderr.log"
    servers.start(task)
    try:
        baseline = ardia_side.reset_task(task)
        instance, claude_server, codex_flags, extra_env = prepare(task)
        workdir = ardia_side.WORK / run_id
        if workdir.exists():
            shutil.rmtree(workdir)
        workdir.mkdir(parents=True)
        prompt = f"{task['prompt']}\n\n{opts['reach_line']}"
        if agent == "codex":
            env = ardia_side.agent_env({"cli": "installed", **ardia_side.route_opts(opts)},
                                       dict(extra_env, **ardia_side.codex_env(registry.HOME / f"codex-home-{side}")))
            cmd = codex_command(model, effort, workdir, prompt, codex_flags)
            mcp_config = None
        else:
            mcp_config = workdir / f"{server}-mcp.json"
            write_json(mcp_config, {"mcpServers": {server: claude_server}})
            env = ardia_side.agent_env({"cli": "installed", **ardia_side.route_opts(opts)}, extra_env)
            cmd = claude_command(model, effort, prompt, mcp_config)
        started_at = datetime.datetime.now().astimezone()
        log(f"{run_id}: {agent} on {task_id} ({side})")
        with open(events, "wb") as fo, open(stderr, "wb") as fe:
            if on_agent_start:
                on_agent_start()
            start_epoch = time.time()
            t0 = time.monotonic()
            proc = spawn_agent(cmd, cwd=workdir, env=env, stdin=subprocess.DEVNULL, stdout=fo, stderr=fe)
            timed_out = False
            try:
                code = proc.wait(timeout=deadline)
            except subprocess.TimeoutExpired:
                timed_out = True
                kill_group(proc)
                code = proc.returncode
            wall = time.monotonic() - t0
        kill_group(proc, grace=2)
        try:
            check = http(task["check"]["method"], task["check"]["url"])
        except Exception as e:
            check = {"pass": False, "error": str(e)}
    finally:
        stopped = finish()
    passed, reset_by_agent = grading.grade(check, timed_out, baseline_reset_at_ms=baseline.get("reset_at_ms"))
    completed = check.get("completed_at_ms")
    lines = read_jsonl(events)
    parsed = (ardia_side.parse_claude if agent == "claude" else ardia_side.parse_codex)(lines)
    used = mcp_calls(agent, server, lines)
    init = next((e for e in lines if e.get("type") == "system" and e.get("subtype") == "init"), None)
    record = {
        "run_id": run_id, "side": side, "contender": contender or f"{side}-{agent}", "agent": agent,
        "task": task_id, "started_at": started_at.isoformat(timespec="milliseconds"),
        "model": model, "effort": effort,
        "claude_route": ardia_side.claude_route_label(opts) if agent == "claude" else None,
        "port_offset": task["port_offset"], "wall_s": round(wall, 3), "timed_out": timed_out, "deadline_s": deadline,
        "exit_code": code, "pass": passed, "reset_by_agent": reset_by_agent,
        "time_to_correct_s": round(completed / 1000 - start_epoch, 3) if passed and completed else None,
        "commands": used["mcp_calls"] + used["shell_commands"], **used,
        "matched": check.get("matched"), "total": check.get("total"), "extra": check.get("extra"),
        "method": check.get("method"), "invariants": check.get("invariants"),
        "check": check, "check_details": check.get("details"), **parsed,
        "agent_saw": {"tools": init.get("tools"), "mcp_servers": init.get("mcp_servers")} if init else None,
        "prompt": prompt, "command": cmd, "workdir": str(workdir),
        "mcp_config": str(mcp_config) if mcp_config else None, "instance": instance,
        "stopped_after": stopped, "events_file": str(events), "stderr_file": str(stderr),
    }
    write_json(out_json, record)
    log(f"{run_id}: pass={passed} wall={record['wall_s']} s tokens={(record['tokens'] or {}).get('total')} "
        f"commands={record['commands']} (mcp {used['mcp_calls']}, shell {used['shell_commands']}) -> {out_json}")
    return record


def run(task_id, agent, run_id, results_dir, overrides=None, contender=None, on_agent_start=None):
    opts = options(overrides)
    url = f"http://127.0.0.1:{opts['port']}/mcp"
    # The token stays in the agent's environment; neither the command nor the config file holds it.
    claude_server = {"type": "http", "url": url, "headers": {"Authorization": f"Bearer ${{{TOKEN_ENV}}}"}}
    codex_flags = ["-c", f"mcp_servers.{SERVER}.url={json.dumps(url)}",
                   "-c", f"mcp_servers.{SERVER}.bearer_token_env_var={json.dumps(TOKEN_ENV)}"]

    def prepare(task):
        state, reused = ensure_world(opts)
        tab = prepare_tab(opts, task)
        instance = {"pid": state["pid"], "port": opts["port"], "world": opts["world"], "app": str(app_path(opts)),
                    "reused": reused, "launch_s": state.get("launch_s"), **tab}
        return instance, claude_server, codex_flags, {TOKEN_ENV: token(opts)}

    return run_mcp_side("copper", task_id, agent, run_id, results_dir, opts, contender, prepare, lambda: [],
                        SERVER, on_agent_start)
