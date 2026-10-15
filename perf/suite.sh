#!/bin/bash
# suite.sh LABEL APP — the whole set against one build, into perf/results/LABEL/:
# launch ×5, every space ×2, a fresh tab ×6 (lightspeed) and ×4 (GitHub), ⌘R ×5 and ×4.
set -u
LABEL=$1
APP=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")   # absolute: the suite runs from perf/
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/results/$LABEL; mkdir -p "$OUT"
cd "$HERE"
[ -f site/index.html ] || python3 site.py
pgrep -f "http.server 8799" >/dev/null || (nohup python3 -m http.server 8799 -d "$HERE/site" >/dev/null 2>&1 &)
python3 perf.py quit perf
python3 perf.py seed perf >/dev/null
python3 perf.py launch "$APP" perf 5 > "$OUT/launch.jsonl"
open -n -g -a "$APP" --env SEARCH_PROBE=perf --env SEARCH_MEASURE=1
until python3 perf.py ask perf '{"do":"probe"}' >/dev/null 2>&1; do sleep 0.2; done
sleep 20   # the other spaces' pages warm (SpaceWarm) — what a person switching after a launch meets
python3 perf.py spaces perf 2 > "$OUT/spaces.jsonl"
python3 perf.py load perf https://lightspeed.exowatt.com/ 6 --user > "$OUT/load-lightspeed.jsonl"
python3 perf.py reload perf https://lightspeed.exowatt.com/ 5 > "$OUT/reload-lightspeed.jsonl"
python3 perf.py load perf https://github.com/copper-browser/Copper 4 --user > "$OUT/load-github.jsonl"
python3 perf.py reload perf https://github.com/copper-browser/Copper 4 > "$OUT/reload-github.jsonl"
python3 perf.py quit perf
echo "done $OUT"
