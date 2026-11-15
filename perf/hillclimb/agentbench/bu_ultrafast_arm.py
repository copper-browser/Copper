"""One run of browser-use 1.0 mode='ultrafast' (an LLM writing code against accessibility-tree helpers), for
agentbench's `bu-ultrafast` arm. Runs in ~/src/bu's venv (browser-use e717df18) on the benchmark-only Chrome
(BU_CDP_URL). LLM: the router's model AGENTBENCH_BU_MODEL (default luna = gpt-6-luna) at reasoning low, as
upstream's bu-ultrafast alias. Prints one JSON line {"run": <jev_run-shaped dict>, "page": <READ_PAGE result>}.

    ~/src/bu/.venv/bin/python bu_ultrafast_arm.py --url URL --goal GOAL --max-steps 20 --read '() => ({...})'

Clock: browser-use's own duration_s (the agent loop; it includes opening the start URL, a few hundred ms that
Copper's and jev-ultrafast's clocks leave out). Steps = the agent's code cells; the URLs come from the tab's
navigation history (for wikigame's no-search check); a cell that types (bu.type / type_secret / insert_text) is a fill.
"""

import argparse
import asyncio
import json
import os
import re
import sys
import time
import urllib.request

os.environ.setdefault("ANONYMIZED_TELEMETRY", "false")
os.environ.setdefault("BH_TELEMETRY", "0")
os.environ.setdefault("BROWSER_USE_NO_UPDATE_CHECK", "1")
os.environ.setdefault("BH_UPDATE_CHECK", "0")

from browser_use import Agent, Browser  # noqa: E402
from browser_use.llm import ChatOpenAI  # noqa: E402

CDP = os.environ.get("BU_CDP_URL", "http://127.0.0.1:4242")
TYPES = re.compile(r"\b(type|type_secret|insert_text|insertText|fill)\s*\(")


def targets():
    with urllib.request.urlopen(f"{CDP}/json/list", timeout=5) as r:
        return [t for t in json.load(r) if t.get("type") == "page"]


async def cdp_eval(ws_url, read):
    import websockets
    async with websockets.connect(ws_url, max_size=2**25) as ws:
        async def call(i, method, **params):
            await ws.send(json.dumps({"id": i, "method": method, "params": params}))
            while True:
                m = json.loads(await asyncio.wait_for(ws.recv(), 10))
                if m.get("id") == i:
                    return m.get("result") or {}
        page = (await call(1, "Runtime.evaluate", expression=f"({read})()", returnByValue=True)).get("result", {}).get("value") or {}
        hist = (await call(2, "Page.getNavigationHistory")).get("entries") or []
        return page, [e.get("url") for e in hist]


def cells(result):
    """The agent's code cells, in order, from the transcript (tool calls with a code argument)."""
    out = []
    for m in getattr(result, "messages", None) or []:
        for p in getattr(m, "parts", None) or []:
            args = getattr(p, "args", None)
            if args is None:
                continue
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except ValueError:
                    args = {"code": args}
            code = (args or {}).get("code") if isinstance(args, dict) else None
            if code:
                out.append(code)
    return out


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--goal", required=True)
    ap.add_argument("--max-steps", type=int, default=20)
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("--read", required=True)
    a = ap.parse_args()
    model = os.environ.get("AGENTBENCH_BU_MODEL", "luna")
    llm = ChatOpenAI(model, api_key=os.environ["ROUTER_KEY"], base_url=os.environ["ROUTER_URL"].rstrip("/") + "/v1",
                     reasoning_effort=os.environ.get("AGENTBENCH_BU_REASONING", "low"))
    before = {t["id"] for t in targets()}
    browser = Browser(cdp_url=CDP, keep_alive=True)
    task = f"Open {a.url} and do this there: {a.goal}"
    run = {"status": "error", "note": "", "elapsed_ms": None, "steps": [], "totals": {}}
    page, urls, result = {}, [], None
    try:
        agent = Agent(task, llm, browser=browser, mode="ultrafast", judge=False, highlight_actions=False)
        result = await agent.run(max_steps=a.max_steps, timeout=a.timeout)
        # 0.x's default (and what a caller reads): finished and the agent did not say it failed
        ok = result.is_done() and result.success is not False
        run["status"] = "done" if ok else "blocked"
        run["note"] = (f"{result.status} success={result.success}: " + (result.final_result() or result.error or ""))[:300]
        run["elapsed_ms"] = int(result.duration_s * 1000)
    except Exception as e:  # noqa: BLE001 — a failed run is a data point
        run["note"] = f"{type(e).__name__}: {e}"[:300]
    try:
        new = [t for t in targets() if t["id"] not in before]
        mine = next((t for t in new if not t["url"].startswith(("about:", "chrome:"))), new[0] if new else None)
        if mine:
            page, urls = await cdp_eval(mine["webSocketDebuggerUrl"], a.read)
        for t in new:
            urllib.request.urlopen(f"{CDP}/json/close/{t['id']}", timeout=5).read()
    except Exception as e:  # noqa: BLE001
        page = {"read_error": f"{type(e).__name__}: {e}"[:200]}
    try:
        await browser.stop()
    except Exception:  # noqa: BLE001
        pass
    code = cells(result) if result else []
    usage = dict(getattr(result, "usage", None) or {})
    steps = [{"operation": "CODE", "kind": "fill" if TYPES.search(c) else "code", "label": c[:60]} for c in code]
    steps += [{"operation": "NAV", "kind": "nav", "url": u} for u in urls]
    run.update({
        "decisions": getattr(result, "steps", None), "actions": len(code), "steps": steps,
        "cost_usd": getattr(result, "cost_usd", None),
        "totals": {"decide_ms": run["elapsed_ms"], "requests": usage.get("requests"),
                   "llm_in_tokens": usage.get("input"), "llm_out_tokens": usage.get("output"),
                   "cache_read": usage.get("cache_read"), "llm_model": model, "model": f"bu-ultrafast/{model}",
                   "strategy": "browser-use ultrafast", "vision": "screenshots"},
        "page": {"url": page.get("url")}, "ran_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    })
    print(json.dumps({"run": run, "page": page}))
    sys.stdout.flush()


if __name__ == "__main__":
    asyncio.run(main())
