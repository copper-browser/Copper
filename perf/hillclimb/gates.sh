#!/bin/bash
# perf/hillclimb/gates.sh APP [SRC] — every PR's e2e fixture as a gate on an integration branch, on the Mac.
#
# Runs each SRC/docs/fixtures/*-e2e.sh and *-e2e.py against APP, one after another, each in its own
# `lockf -k ~/hc/mini.lock` (when that lock exists) with a timeout, and writes a pass/fail/skip table.
#   APP  the dev build to gate (never the installed Copper); SRC  the checkout its fixtures + bench come from
#        (default: APP's own checkout when APP is SRC/build/Copper.app). Otherwise a scratch root of symlinks
#        to SRC with build/Copper.app = a clone of APP, so fixtures that hard-code $root/build/Copper.app test APP.
#   GATES_PORTS=4230-4239  every fixture's port knob points at its first two free ports (fixtures without one take
#                          free ports from the OS); one fixture runs at a time, so they share them.
#   GATES_ONLY=a,b / GATES_SKIP=a,b  fixture names without -e2e.*; GATES_TIMEOUT=900 s each;
#   GATES_OUT=~/hc/out/gates-<label>  → <name>.log per fixture, gates.md, gates.json. Exit 1 if any fails.
# Skipped by default, with the reason in the table: fixtures that need an argument (cloud link codes), a tool
# this Mac lacks (uvx), or the installed Copper's own folder (onepassword: its 1Password extension).
set -uo pipefail
APP="$(cd "${1:?usage: $0 APP [SRC]}" && pwd)"
SRC="${2:-}"
[ -n "$SRC" ] || { [ "$(basename "$(dirname "$APP")")" = build ] && SRC="$(dirname "$(dirname "$APP")")"; }
[ -n "$SRC" ] && [ -d "$SRC/docs/fixtures" ] || { echo "no fixtures: pass SRC (the checkout APP was built from)" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"
[ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = com.collinrijock.copper.dev ] \
  || { echo "refusing: $APP is not a dev build (com.collinrijock.copper.dev)" >&2; exit 2; }
IFS=- read -r LO HI <<<"${GATES_PORTS:-4230-4239}"
[ "$LO" -ge 4130 ] && [ "$HI" -le 4239 ] || { echo "GATES_PORTS: within 4130–4239" >&2; exit 2; }
# The range's free ports (a leftover server from another run may hold one): the knobs use the first two.
FREE=($(python3 -c 'import socket, sys
for p in range(int(sys.argv[1]), int(sys.argv[2]) + 1):
    with socket.socket() as s:
        if s.connect_ex(("127.0.0.1", p)): print(p)' "$LO" "$HI"))
[ ${#FREE[@]} -ge 2 ] || { echo "GATES_PORTS: fewer than 2 free ports in ${LO}–${HI}" >&2; exit 2; }
P0=${FREE[0]} P1=${FREE[1]}
LABEL="${GATES_LABEL:-$(basename "$(dirname "$APP")")}"
OUT="${GATES_OUT:-$HOME/hc/out/gates-$LABEL}"
LOCK="${GATES_LOCK-$HOME/hc/mini.lock}"; [ -f "$LOCK" ] || LOCK=""
mkdir -p "$OUT"; rm -f "$OUT"/*.log "$OUT/gates.json"

ROOT="$SRC"
if [ "$APP" != "$SRC/build/Copper.app" ]; then
  ROOT="$(mktemp -d /tmp/hc-gates.XXXXXX)"
  for e in "$SRC"/* "$SRC"/.[!.]*; do [ -e "$e" ] && [ "$(basename "$e")" != build ] && ln -s "$e" "$ROOT/"; done
  # An APFS clone, not a symlink: `open` resolves links, and fixtures check the running pid's path against it.
  mkdir "$ROOT/build"; cp -cR "$APP" "$ROOT/build/Copper.app"
  trap '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$ROOT/build/Copper.app" 2>/dev/null; rm -rf "$ROOT"' EXIT
fi

# Every port knob the fixtures read (one fixture at a time, so all share the range's first ports).
export COPPER_SKIP_BUILD=1 COPPER_APP="$APP" COPPER_KEEP_GOING=1 \
  COPPER_MCP_PORT=$P0 COPPER_PORT=$P0 MCP_PORT=$P0 E2E_PORT=$P0 CHAT_PORT=$P0 CKL_PORT=$P0 ASG_PORT=$P0 \
  COPPER_SHARE_MCP_PORT=$P0 FIXTURE_PORT=$P1 PAGE_PORT=$P1

# A timeout that ends the fixture's whole process group (its EXIT trap cleans its world up).
limit() { python3 -c '
import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    sys.exit(p.wait(timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGTERM)
    try:
        p.wait(30)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
    sys.exit(124)' "${GATES_TIMEOUT:-900}" "$@"; }

want() { local n=$1
  [ -z "${GATES_ONLY:-}" ] || [[ ",$GATES_ONLY," == *",$n,"* ]] || return 1
  [[ ",${GATES_SKIP:-}," != *",$n,"* ]]; }
why_skip() { local f=$1
  grep -q '\${1:?' "$f" && { echo "needs an argument: $(grep -m1 -o '\${1:?[^}]*}' "$f")"; return; }
  grep -qw uvx "$f" && ! command -v uvx >/dev/null && { echo "needs uvx (not on this Mac)"; return; }
  grep -q 'Application Support/Copper/Extensions' "$f" && { echo "reads the installed Copper's own folder"; return; }
}

pass=0 fail=0 skip=0
echo "gates: $APP (fixtures from $SRC), ports $P0 + $P1 (free in ${LO}–${HI}) → $OUT"
for f in "$ROOT"/docs/fixtures/*-e2e.sh "$ROOT"/docs/fixtures/*-e2e.py; do
  n="$(basename "$f")"; n="${n%-e2e.*}"
  want "$n" || continue
  reason="$(why_skip "$f")"
  if [ -n "$reason" ]; then
    skip=$((skip + 1)); rc=skip; secs=0; last="$reason"
  else
    if [[ $f == *.py ]]; then cmd=(python3 "$f" --app "$APP"); [ "$n" = page-tools ] && cmd+=(--port "$P0" --keep-going)
    else cmd=(bash "$f"); fi
    s=$(date +%s)
    (cd "$ROOT" && if [ -n "$LOCK" ]; then lockf -k "$LOCK" bash -c "$(declare -f limit); limit \"\$@\"" _ "${cmd[@]}"
                   else limit "${cmd[@]}"; fi) >"$OUT/$n.log" 2>&1
    rc=$?; secs=$(( $(date +%s) - s ))
    last="$( (grep -E 'PASS|FAIL|not ok|passed|failed|ok [0-9]' "$OUT/$n.log" || tail -1 "$OUT/$n.log") | tail -1 | cut -c1-200)"
    [ -n "$last" ] || last="(no output)"
    [ $rc = 124 ] && last="timed out after ${GATES_TIMEOUT:-900} s; $last"
    if [ $rc = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
  fi
  printf '%-28s %-5s %4ss  %s\n' "$n" "$rc" "$secs" "$last"
  python3 -c 'import json,sys; print(json.dumps(dict(zip(["name","rc","seconds","last"], sys.argv[1:]))))' "$n" "$rc" "$secs" "$last" >>"$OUT/gates.json"
done
python3 - "$OUT" "$APP" "$pass" "$fail" "$skip" <<'PY'
import json, os, sys, time
out, app, p, f, s = sys.argv[1:]
rows = [json.loads(l) for l in open(os.path.join(out, "gates.json"))] if os.path.exists(os.path.join(out, "gates.json")) else []
L = [f"# Gates — {app}", "", f"{time.strftime('%Y-%m-%d %H:%M')} · **{p} pass · {f} fail · {s} skipped** · logs: `<name>.log`", "",
     "| | Fixture | rc | s (incl. lock wait) | Last line / why skipped |", "|---|---|---|---|---|"]
for r in rows:
    mark = "✅" if r["rc"] == "0" else "➖" if r["rc"] == "skip" else "❌"
    L.append(f"| {mark} | {r['name']} | {r['rc']} | {r['seconds']} | {r['last'].replace('|', '/')} |")
open(os.path.join(out, "gates.md"), "w").write("\n".join(L) + "\n")
PY
echo "$pass pass · $fail fail · $skip skipped → $OUT/gates.md"
[ "$fail" = 0 ]
