"""One run of fastbrowse (agent-labs-dev/fastbrowse, MIT) for agentbench's `fastbrowse` arm: Jev picks each action
from the page's indexed controls, an LLM writes values and composed answers. Runs in ~/hc/fastbrowse-venv (pip
fastbrowse) on the benchmark-only Chrome (FB_CDP_PORT). Keys come from the dev world's intelligence.json, handed to
run_task(settings=...) and never printed: Jev = direct TypeSafe (fastbrowse's supported route without OpenRouter),
LLM = our router as fastbrowse's `custom` provider, model luna (= gpt-6-luna, fastbrowse's default) at reasoning low
(its default for Luna). Prints one JSON line {"run": <jev_run-shaped dict>, "page": <READ_PAGE result>}.

    ~/hc/fastbrowse-venv/bin/python fastbrowse_arm.py --url URL --goal GOAL --max-steps 20 --read '() => ({...})'

The run drives a tab we open first (attach + target_match on its title), so the page it ends on is still there for
the checker. Clock: page_ready (first page open) → run returned, as Copper's jev_run excludes the first navigation.
"""

import argparse
import asyncio
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import uuid

from fastbrowse import run_task
from fastbrowse.models import Authorization, Limits

PORT = int(os.environ.get("FB_CDP_PORT", "4292"))
CDP = f"http://127.0.0.1:{PORT}"
FILLS = {"fill", "select", "upload"}


def settings():
    d = json.load(open(os.path.expanduser("~/Library/Application Support/Copper (dev)/intelligence.json")))
    return {"TYPESAFE_API_KEY": d["jevKey"], "FASTBROWSE_DECISION_SOURCE": "typesafe",
            "FASTBROWSE_LLM_PROVIDER": "custom", "FASTBROWSE_LLM_BASE_URL": d["routerURL"].rstrip("/") + "/v1",
            "FASTBROWSE_LLM_API_KEY": d["routerKey"], "FASTBROWSE_LLM_MODEL": os.environ.get("AGENTBENCH_FB_MODEL", "luna"),
            "FASTBROWSE_LLM_REASONING": os.environ.get("AGENTBENCH_FB_REASONING", "low")}


def new_tab(title):
    url = "data:text/html," + urllib.parse.quote(f"<title>{title}</title>")
    req = urllib.request.Request(f"{CDP}/json/new?{urllib.parse.quote(url, safe='')}", method="PUT")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


async def cdp_eval(ws_url, read):
    import websockets
    async with websockets.connect(ws_url, max_size=2**25) as ws:
        async def call(i, method, **params):
            await ws.send(json.dumps({"id": i, "method": method, "params": params}))
            while True:
                m = json.loads(await asyncio.wait_for(ws.recv(), 10))
                if m.get("id") == i:
                    return m.get("result") or {}
        page = {}
        for _ in range(10):  # a page still loading is read again for up to 5 s, as play_copper does
            page = (await call(1, "Runtime.evaluate", expression=f"({read})()", returnByValue=True)).get("result", {}).get("value") or {}
            if page.get("title") or page.get("ready") == "complete":
                break
            await asyncio.sleep(0.5)
        hist = (await call(2, "Page.getNavigationHistory")).get("entries") or []
        return page, [e.get("url") for e in hist]


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--goal", required=True)
    ap.add_argument("--max-steps", type=int, default=20)
    ap.add_argument("--timeout", type=float, default=170)
    ap.add_argument("--authorize", action="store_true", help="irreversible actions allowed (local fixtures whose goal asks for a submit)")
    ap.add_argument("--read", required=True)
    a = ap.parse_args()
    title = "fb-" + uuid.uuid4().hex[:10]
    tab = new_tab(title)
    ready = {}

    async def page_ready():
        ready.setdefault("t", time.time())

    run = {"status": "error", "note": "", "elapsed_ms": None, "steps": [], "totals": {}}
    result, begun = None, time.time()
    try:
        result = await asyncio.wait_for(run_task(
            a.goal, start=a.url, cdp_port=PORT, attach=True, target_match=title, page_ready=page_ready,
            limits=Limits(max_steps=a.max_steps), authorization=Authorization(irreversible_actions=a.authorize),
            settings=settings()), a.timeout)
        status = result.status.value
        run["status"] = {"complete": "done", "budget_exceeded": "budget"}.get(status, status)
        run["fb_status"] = status
        run["answer"] = result.answer
        run["note"] = (result.answer or result.error or status)[:300]
    except asyncio.TimeoutError:
        run["note"] = f"harness timeout {a.timeout:.0f} s"
    except Exception as e:  # noqa: BLE001 — a failed run is a data point
        run["note"] = f"{type(e).__name__}: {e}"[:300]
    end = time.time()
    run["elapsed_ms"] = int((end - ready.get("t", begun)) * 1000)
    page, urls = {}, []
    try:
        page, urls = await cdp_eval(tab["webSocketDebuggerUrl"], a.read)
    except Exception as e:  # noqa: BLE001
        page = {"read_error": f"{type(e).__name__}: {e}"[:200]}
    try:
        urllib.request.urlopen(f"{CDP}/json/close/{tab['id']}", timeout=5).read()
    except Exception:  # noqa: BLE001
        pass
    steps, lines = [], []
    if result:
        for s in result.steps:
            op = s.operation.value
            steps.append({"operation": op.upper(), "kind": "fill" if op in FILLS else op, "label": (s.target or "")[:60],
                          "url": s.url, "decide_ms": s.duration_ms, "decided_by": s.decided_by.value})
        lines = list(result.cost.lines)
    steps += [{"operation": "NAV", "kind": "nav", "url": u} for u in urls]
    jev = [x for x in lines if x.component.value == "jev"]
    llm = [x for x in lines if x.component.value == "llm"]
    acted = [s for s in steps if s["operation"] not in ("NAV", "DONE", "READ")]
    run.update({
        "decisions": sum(x.physical_requests or 1 for x in jev), "actions": len(acted), "steps": steps,
        "llm_calls": sum(x.physical_requests or 1 for x in llm), "fb_dollars": sum(x.dollars or 0 for x in lines),
        "fb_unknown_lines": sum(1 for x in lines if x.dollars is None),
        "totals": {"input_tokens": sum(x.input_tokens for x in jev), "requests": sum(x.physical_requests or 1 for x in jev),
                   "jev_ms": round(sum((x.seconds or 0) * 1000 for x in jev)), "text_ms": round(sum((x.seconds or 0) * 1000 for x in llm)),
                   "llm_in_tokens": sum(x.input_tokens for x in llm), "llm_out_tokens": sum(x.output_tokens for x in llm),
                   "llm_model": settings()["FASTBROWSE_LLM_MODEL"], "model": "jev-1.14.0 (fastbrowse)",
                   "strategy": "fastbrowse", "vision": "screenshot", "text_calls": sum(x.physical_requests or 1 for x in llm),
                   "llm_purposes": sorted({x.purpose.value for x in llm if x.purpose})},
        "page": {"url": page.get("url") or (result.final_url if result else None)}, "ran_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    })
    print(json.dumps({"run": run, "page": page}, default=str))
    sys.stdout.flush()


if __name__ == "__main__":
    asyncio.run(main())
