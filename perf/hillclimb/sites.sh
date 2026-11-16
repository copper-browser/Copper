#!/bin/bash
# Track S — site compatibility: the same logged-out pages in Safari and in each
# Copper build on one Mac (same WebKit, so a Copper-only failure is Copper's).
#
#   perf/hillclimb/sites.sh LABEL APP [APP2 …]     # on a Mac, or from the devbox (runs on the mini, copies back)
#   perf/hillclimb/sites.sh r7 '~/hc/v109/Copper.app' '~/hc/src-r7sites/build/Copper.app'
#
# Env: SITES_HOST=mac-mini · SITES_PORT=4320 (Copper N on 4320+N-1, Safari's driver on +5) · SITES_ONLY=pypi,x
#      SITES_EXTRA=FILE (host names, one per line, loaded as https://HOST/; keep it out of git: someone's history)
#      SITES_SAFARI=0 (skip Safari: a laptop, where its window would take focus)
# Out: ~/hc/out/LABEL/sites/{safari,copper-N}.json + shots, table.md (devbox: ~/plans/copper-hillclimb-2026-11-14/out/LABEL/sites/).
# Sites run under SITES_LOCK (~/hc/mini.lock; the laptop: ~/hc/laptop.lock), SITES_BATCH (5) per hold, ~1 min. Never signs in, never submits a form.
set -euo pipefail
label="${1:?usage: sites.sh LABEL APP [APP2 …]}"; shift
here="$(cd "$(dirname "$0")" && pwd)"

if [ "$(uname)" != Darwin ]; then
  host="${SITES_HOST:-mac-mini}"
  back="$HOME/plans/copper-hillclimb-2026-11-14/out/$label/sites"
  rsync -az --exclude __pycache__ "$here/sites/" "$host:hc/sites-harness/sites/"
  rsync -az "$here/sites.sh" "$host:hc/sites-harness/"
  [ -n "${SITES_EXTRA:-}" ] && { rsync -az "$SITES_EXTRA" "$host:hc/sites-harness/extra-hosts.txt"; extra=hc/sites-harness/extra-hosts.txt; }
  ssh "$host" "SITES_PORT='${SITES_PORT:-}' SITES_ONLY='${SITES_ONLY:-}' SITES_EXTRA='${extra:-}' SITES_SAFARI='${SITES_SAFARI:-1}' SITES_LOCK='${SITES_LOCK:-}' SITES_BATCH='${SITES_BATCH:-}' hc/sites-harness/sites.sh '$label' $*" || echo "sites run exited $?"
  mkdir -p "$back"
  rsync -az "$host:hc/out/$label/sites/" "$back/"
  echo "→ $back/table.md"
  exit 0
fi

out="$HOME/hc/out/$label/sites"
mkdir -p "$out"
port="${SITES_PORT:-4320}"
common=(--batch "${SITES_BATCH:-5}" ${SITES_ONLY:+--only "$SITES_ONLY"} ${SITES_EXTRA:+--extra "$HOME/${SITES_EXTRA#$HOME/}"} --lock "${SITES_LOCK:-$HOME/hc/mini.lock}")
files=()
# The browsers run side by side (each takes the lock per site), so a site is seen by all of them within minutes.
if [ "${SITES_SAFARI:-1}" != 0 ]; then
  /usr/bin/python3 "$here/sites/sites.py" safari --out "$out/safari.json" --port $((port + 5)) "${common[@]}" > "$out/safari.log" 2>&1 &
  files+=("$out/safari.json")
fi
n=0
for app in "$@"; do
  n=$((n + 1))
  /usr/bin/python3 "$here/sites/sites.py" copper --app "${app/#\~/$HOME}" --out "$out/copper-$n.json" --port $((port + n - 1)) --world "hc-sites-$n" "${common[@]}" > "$out/copper-$n.log" 2>&1 &
  files+=("$out/copper-$n.json")
done
wait
/usr/bin/python3 "$here/sites/sites.py" table "${files[@]}" > "$out/table.md"
cat "$out/table.md"
