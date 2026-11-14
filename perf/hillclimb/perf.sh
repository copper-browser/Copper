#!/bin/bash
# perf/hillclimb/perf.sh LABEL APP [BASELABEL BASEAPP] — Track A (Mac performance), on the Mac.
#
# One build: its numbers. Two builds: both, alternated launch by launch (ABBA), plus Δ vs the base
# with the base's spread as the noise band. Writes ~/hc/out/LABEL/perf/<host>/{machine.json,raw/,perf.json,perf.md}.
#   mini   (default there): A1 warm + cold launch (foreground), A2/A4/A6/A7 sessions, A3 page loads vs
#          bare WebKit, hooks (A7 keylat, A5 wheel); every batch under `flock ~/hc/mini.lock` (lockf(1)'s lock).
#   laptop (MacBook*):      A1 + sessions headless (never steals focus), A5 scroll + canvas at Retina 2×, hooks
#          (the 120 Hz wheel); laptop samples count only at 1-min load < 3 (waits up to HC_LOAD_WAIT=60 s for it).
# Knobs (env): HC_PHASES, HC_LAUNCHES=8, HC_COLD=6, HC_ROUNDS=5, HC_SETTLE=30, HC_IDLE=60, HC_LOADS=21 (A3: paired, run 0 dropped),
#   HC_SMOOTH_RUNS=5, HC_PRESSES=20, HC_WHEEL_RUNS=5, HC_MODE=fg|headless, HC_SEED=~/hc/seed, HC_WORLD=hcperf,
#   HC_PORT/HC_SITE_PORT/HC_FIXTURE_PORT/HC_CANVAS_PORT (any of 4130–4239, never 4123), HC_CANVAS_OUT=~/hc/canvas-out,
#   HC_TOOLS=~/hc/tools (perf/ + docs/fixtures/canvas-*).
# From the devbox, perf/hillclimb/perf/remote.sh does push → run on both Macs → pull → merged perf.json.
set -euo pipefail
[ $# -eq 2 ] || [ $# -eq 4 ] || { sed -n 2,15p "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=$1
ARMS=("$1=$2"); [ $# -eq 4 ] && ARMS+=("$3=$4")
for a in "${ARMS[@]}"; do [ -x "${a#*=}/Contents/MacOS/Copper" ] || { echo "no Copper at ${a#*=}" >&2; exit 2; }; done
if [[ $(sysctl -n hw.model) == MacBook* ]]; then
  export HC_HOST=${HC_HOST:-laptop} HC_MODE=${HC_MODE:-headless} HC_LOCK=${HC_LOCK:-}
  export HC_PHASES=${HC_PHASES:-launch cold session smooth hooks}
else
  export HC_HOST=${HC_HOST:-mini} HC_MODE=${HC_MODE:-fg} HC_LOCK=${HC_LOCK-$HOME/hc/mini.lock}
  export HC_PHASES=${HC_PHASES:-launch cold session load hooks}
fi
[ -n "$HC_LOCK" ] && touch "$HC_LOCK"
OUT=$HOME/hc/out/$LABEL/perf/$HC_HOST
rm -rf "$OUT/raw"; mkdir -p "$OUT"
RUN="python3 $HERE/perf/run.py"
exec > >(tee "$OUT/run.log") 2>&1
echo "perf.sh $LABEL on $HC_HOST: phases [$HC_PHASES] mode $HC_MODE arms ${ARMS[*]}"
$RUN setup "$OUT" "${ARMS[@]}"
for phase in $HC_PHASES; do
  echo "== $phase $(date +%T) load $(sysctl -n vm.loadavg)"
  $RUN "$phase" "$OUT" "${ARMS[@]}"
done
$RUN summary "$OUT" "$OUT"
echo "done $OUT"
