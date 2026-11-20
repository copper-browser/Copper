#!/usr/bin/env python3
"""Google Flights "Reload" probe: what is the Reload control Jev clicks after Search?

Drives the Flights task one jev_step at a time in a probe world; right after the step
that clicked Search (or as soon as any read offers "Reload") it captures, at 0 / 0.5 /
1.5 / 3 s: every element named Reload (outerHTML, visibility, rect, the ancestors'
display/visibility/opacity/aria-hidden), the page's flight rows, and the tab's
xhr/fetch requests (browser_network_requests). Jev is not asked again after that.

    flights_probe.py --world agentbench-jev --port 4190 --out DIR [--runs 3]
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agentbench import Copper, FLIGHT_DATE  # noqa: E402

GOAL = (f"Find one-way flights from Zurich to London on {FLIGHT_DATE[1]}, for one adult in economy. "
        "Stop when matching flight options are visible. Do not select or book a flight.")

CAPTURE = r"""() => {
  const named = [...document.querySelectorAll('button,[role=button],a,[jsaction]')]
    .filter(e => /^\s*reload\s*$/i.test(e.innerText || e.getAttribute('aria-label') || ''));
  const chain = e => { const out = []; for (let n = e; n && n !== document.body && out.length < 8; n = n.parentElement) {
    const s = getComputedStyle(n), r = n.getBoundingClientRect();
    out.push({tag: n.tagName.toLowerCase(), cls: (n.className && n.className.baseVal === undefined ? n.className : '').slice(0, 60),
              role: n.getAttribute('role'), hidden: n.getAttribute('aria-hidden'), live: n.getAttribute('aria-live'),
              display: s.display, visibility: s.visibility, opacity: s.opacity,
              rect: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)]}); } return out; };
  return {
    at: Date.now(), url: location.href, title: document.title,
    reloads: named.map(e => ({html: e.outerHTML.slice(0, 600),
      visible: e.checkVisibility ? e.checkVisibility({checkOpacity: true, checkVisibilityCSS: true}) : null,
      panel: (e.closest('[role=alert],[role=status],[aria-live],[role=dialog]') || e.parentElement.parentElement || e).innerText.slice(0, 300),
      chain: chain(e)})),
    flights: [...document.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label'))
      .filter(s => /Select flight/.test(s)).length,
    busy: [...document.querySelectorAll('[aria-busy=true],[role=progressbar]')].filter(e => e.offsetParent).length,
    text: (document.body.innerText || '').slice(0, 1500),
  };
}"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--gap", type=float, default=50, help="seconds between Flights runs")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    c = Copper(a.world, a.port)
    for run in range(1, a.runs + 1):
        if run > 1:
            time.sleep(a.gap)
        c.call("browser_tabs", {"action": "new", "url": "https://www.google.com/travel/flights?hl=en"})
        time.sleep(3)
        log = {"run": run, "steps": [], "captures": []}
        try:
            for i in range(40):
                out = c.call("jev_step", {"goal": GOAL})
                log["steps"].append(out[:1500])
                first = out.split("\n", 3)[:3]
                print(f"  {run}.{i + 1}: {' | '.join(first)[:160]}", flush=True)
                low = out.lower()
                # "### Step\n12. CLICK Search (94%, …)": the read after it is the one that offered Reload
                after_search = out.startswith("### Step") and " CLICK Search " in (first[1] if len(first) > 1 else "")
                if after_search or "reload" in low or out.startswith("### Run ended"):
                    for wait in (0, 0.5, 1.0, 1.5):
                        time.sleep(wait)
                        cap = json.loads(c.call("browser_evaluate", {"function": CAPTURE}, timeout=30))
                        try:
                            cap["requests"] = c.call("browser_network_requests", {"limit": 40}, timeout=30)[-6000:]
                        except Exception as e:  # older builds: network_requests broken in the r1 merge
                            cap["requests"] = f"error: {e}"
                        log["captures"].append(cap)
                        print(f"    capture +{sum((0, 0.5, 1.0, 1.5)[:len(log['captures'])]):.1f}s: reloads {len(cap['reloads'])} "
                              f"visible {[r['visible'] for r in cap['reloads']]} flights {cap['flights']} busy {cap['busy']}", flush=True)
                    break
        finally:
            with open(os.path.join(a.out, f"flights-probe-{run}.json"), "w") as fh:
                json.dump(log, fh, indent=1)
            try:
                c.call("browser_close", {}, timeout=20)
            except Exception:
                pass


if __name__ == "__main__":
    main()
