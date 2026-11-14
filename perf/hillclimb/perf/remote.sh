#!/bin/bash
# perf/hillclimb/perf/remote.sh LABEL APP [BASELABEL BASEAPP] — from the devbox: push the harness and
# its tools to both Macs, run perf.sh on each (in parallel: separate machines), pull the results to
# ~/plans/copper-hillclimb-2026-11-14/out/LABEL/perf/<host>/ and merge them into perf.json + perf.md.
# APP paths are as seen on the Macs (e.g. ~/hc/base/Copper.app); copy new builds to both first.
# HOSTS="mac-mini personal-laptop" by default; HC_* knobs are passed through. HC_HARNESS_DIR / HC_TOOLS_DIR
# (default hc/harness, hc/tools, under ~ on the Macs) give a worker its own copies: those dirs get rsync --delete.
set -euo pipefail
[ $# -eq 2 ] || [ $# -eq 4 ] || { sed -n 2,8p "$0"; exit 2; }
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
DEST=${HC_DEST:-$HOME/plans/copper-hillclimb-2026-11-14/out}/$1/perf
HOSTS=${HOSTS:-mac-mini personal-laptop}
HD=${HC_HARNESS_DIR:-hc/harness} TD=${HC_TOOLS_DIR:-hc/tools}
KNOBS=$(env | grep -E '^HC_[A-Z_]+=' | sed "s/=\(.*\)/='\1'/" | tr '\n' ' ' || true)
mkdir -p "$DEST"
for h in $HOSTS; do
  ssh "$h" "mkdir -p ~/$TD/docs/fixtures ~/$HD ~/hc/out"
  rsync -az --delete --exclude results --exclude site "$REPO/perf/" "$h:$TD/perf/"
  rsync -az --delete --exclude out "$REPO/docs/fixtures/canvas-big" "$REPO/docs/fixtures/canvas-easel" "$h:$TD/docs/fixtures/"
  rsync -az --delete "$REPO/perf/hillclimb/" "$h:$HD/"
done
pids=()
for h in $HOSTS; do
  ssh -o ServerAliveInterval=30 "$h" "$KNOBS HC_TOOLS=~/$TD ~/$HD/perf.sh $*" > "$DEST/$h.log" 2>&1 & pids+=($!)
done
rc=0; for p in "${pids[@]}"; do wait "$p" || rc=1; done
dirs=()
for h in $HOSTS; do
  host=$(ssh "$h" '[[ $(sysctl -n hw.model) == MacBook* ]] && echo laptop || echo mini')
  rsync -az "$h:hc/out/$1/perf/$host" "$DEST/" && dirs+=("$DEST/$host")
done
HC_TOOLS=$REPO python3 "$REPO/perf/hillclimb/perf/run.py" summary "$DEST" "${dirs[@]}"
echo "rc=$rc → $DEST/perf.md"; exit $rc
