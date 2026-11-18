"""Record each space's sidebar for the bento's "animated sidebars" tile: the backdrop moving,
the selection hopping between tabs. One frame folder per space, each a different length
so the three loops drift apart on the page.
rec_sides.py OUTDIR   (launch.sh with SIZE=640x760 first: a small window records at ~20 fps)"""
import os, sys, time, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cb import Recorder, ask
out = sys.argv[1]
def sp(i): ask({"do": "spaces", "op": "select", "arg": str(i)})
def sel(i): ask({"do": "select", "id": i})
def tabs(): return [t for t in ask({"do": "tabs"}).get("tabs", []) if not t.get("bench")]
ask({"do": "ui", "sidebar": True, "look": "dark"})
# per space: (seconds to wait, tab index to select); the last tab is the first, so the loop closes
PLANS = [
    [(1.4, 1), (1.7, 3), (1.5, 2), (1.6, 0), (1.0, None)],
    [(2.6, 2), (2.2, 1), (2.0, 0), (1.6, None)],
    [(0.8, 1), (2.0, 2), (1.5, 0), (2.3, None)],
]
for k, plan in enumerate(PLANS):
    sp(k); time.sleep(1.0)
    T = [t["id"] for t in tabs()]
    for i in T: sel(i); time.sleep(2.5)      # wake every tab once so its icon and title are real
    sel(T[0]); time.sleep(3.0)
    r = Recorder(os.path.join(out, f"s{k}")); r.start()
    for wait, tab in plan:
        time.sleep(wait)
        if tab is not None: sel(T[tab])
    fr = r.finish(); print(k, len(fr), "frames", round(fr[-1][0] - fr[0][0], 1), "s")
sp(0)
