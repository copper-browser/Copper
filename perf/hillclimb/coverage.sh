#!/bin/bash
# Track C — agent coverage. Runs every job in coverage/jobs.py against a headless
# probe world of the given build and writes coverage.json + coverage.md.
#
#   perf/hillclimb/coverage.sh LABEL /path/to/Copper.app     # on a Mac
#   perf/hillclimb/coverage.sh base '~/hc/base/Copper.app'   # from the devbox: runs on mac-mini, copies back
#
# Env: COV_ONLY=c1.,c4.eval (job ids/prefixes) · COV_PORT=4150 (4150–4159) · COV_WORLD=hc-cov · COV_HOST=mac-mini
#      COV_DIR=hc/harness (the harness copy on the Mac; give parallel runs their own)
#      COV_REPEAT=3 (fresh world per run; the .md shows the per-run band and flaky jobs)
#      COV_MODE=windowed (a probe window on the screen: alert sheets, real focus; mini only → coverage-windowed.*)
#      HC_BENCH=path/to/bench (for the passkey job; found next to the build's source otherwise)
# Out: ~/hc/out/LABEL/coverage/ on the Mac; ~/plans/copper-hillclimb-2026-11-14/out/LABEL/coverage/ on the devbox.
set -euo pipefail
label="${1:?usage: coverage.sh LABEL /path/to/Copper.app}"
app="${2:?usage: coverage.sh LABEL /path/to/Copper.app}"
here="$(cd "$(dirname "$0")" && pwd)"

if [ "$(uname)" != Darwin ]; then
  host="${COV_HOST:-mac-mini}"
  back="$HOME/plans/copper-hillclimb-2026-11-14/out/$label/coverage"
  dir="${COV_DIR:-hc/harness}"
  rsync -az --exclude __pycache__ "$here/" "$host:$dir/"
  ssh "$host" "COV_ONLY='${COV_ONLY:-}' COV_PORT='${COV_PORT:-}' COV_WORLD='${COV_WORLD:-}' COV_REPEAT='${COV_REPEAT:-}' COV_MODE='${COV_MODE:-}' HC_BENCH='${HC_BENCH:-}' $dir/coverage.sh '$label' $app" || echo "coverage run exited $?"
  mkdir -p "$back"
  rsync -az "$host:hc/out/$label/coverage/" "$back/"
  echo "→ $back/coverage.md"
  exit 0
fi

app="${app/#\~/$HOME}"
[ -x "$app/Contents/MacOS/Copper" ] || { echo "no Copper at $app" >&2; exit 2; }
mode="${COV_MODE:-headless}"
# A windowed probe puts a window on the screen: never on a laptop someone uses.
if [ "$mode" = windowed ] && pmset -g ps 2>/dev/null | grep -q InternalBattery; then
  echo "COV_MODE=windowed is for the mini only (this Mac has a battery: someone's laptop)" >&2; exit 2
fi
out="$HOME/hc/out/$label/coverage"
mkdir -p "$out"
if [ -z "${HC_BENCH:-}" ]; then
  for b in "$here/../../bench" "$app/../../bench" "$app/../src-base/bench" "$HOME/hc/src-base/bench"; do
    [ -f "$b" ] && { export HC_BENCH="$(cd "$(dirname "$b")" && pwd)/bench"; break; }
  done
fi

# Fixture server: two origins, P and P+1, inside 8795–8799 (8790/8791/8793 are taken on the mini).
fport=""
for p in 8795 8796 8797 8798; do
  if ! lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 && ! lsof -nP -iTCP:$((p + 1)) -sTCP:LISTEN >/dev/null 2>&1; then fport=$p; break; fi
done
[ -n "$fport" ] || { echo "no free fixture port pair in 8795–8799" >&2; exit 2; }
python3 "$here/coverage/serve.py" "$fport" "$((fport + 1))" >"$out/fixtures.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
for _ in $(seq 1 40); do curl -fsS -o /dev/null "http://127.0.0.1:$fport/index.html" 2>/dev/null && break; sleep 0.1; done

# One measurement batch under the mini's shared lock (no build runs beside it).
mkdir -p "$HOME/hc"
lockf "$HOME/hc/mini.lock" /usr/bin/python3 "$here/coverage/run.py" --app "$app" --out "$out" --label "$label" \
  --port "${COV_PORT:-4150}" --world "${COV_WORLD:-hc-cov}" --fixtures "$fport" --mode "$mode" --repeat "${COV_REPEAT:-1}" ${COV_ONLY:+--only "$COV_ONLY"} \
  2>&1 | tee "$out/run-$mode.log"
