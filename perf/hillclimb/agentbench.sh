#!/usr/bin/env bash
# Track D — agent performance (Jev). One suite, alternating arms, on a headless
# probe world of the given Copper.app. See agentbench/README.md.
#
#   perf/hillclimb/agentbench.sh <label> <path-to-Copper.app> [groups]
#       groups: comma list of ultrafast,wikigame,uibench,realweb (default all)
#       env: ARMS=shipped,turbo,classic,llm-haiku  ROUNDS_ULTRAFAST=10 ROUNDS_WIKIGAME=1
#            ROUNDS_UIBENCH=2 ROUNDS_REALWEB=2 TASKS=hotel,godel (only these task ids)
#   perf/hillclimb/agentbench.sh up|down <path-to-Copper.app>   # probe world only (debugging)
#       env (all optional): AGENTBENCH_WORLD=agentbench AGENTBENCH_PORT=4160 AGENTBENCH_FIXPORT=4161
#            AGENTBENCH_REMOTE_DIR=hc/harness   where the devbox syncs the harness on the mini
#            AGENTBENCH_VIEWPORT=1120x780       the page size of every run (default: the build's 1280×800)
#            AGENTBENCH_TEXT_MODEL=<name>|default   textModel of the probe world (default: the dev world's;
#                                               "default" leaves it unset = what a fresh install runs)
#            AGENTBENCH_JEV_ENDPOINT=<url>      jevEndpoint of the probe world (parity/parity.py's recorder)
#            AGENTBENCH_FLIGHTS_GAP=45          seconds between ultrafast rounds (Google throttles back-to-back Flights searches)
#            AGENTBENCH_PRIVATE=1               every run in a private tab (empty cookies/storage; hc/jev builds on)
#
# On the devbox (Linux) it syncs the harness to the mini, runs itself there and
# copies ~/hc/out/<label>/agentbench back to ~/plans/copper-hillclimb-2026-11-14/out/.
# On a Mac it does the work: probe world "Copper (agentbench)" on port 4160,
# fixture server on 4161, every batch under `lockf ~/hc/mini.lock`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

if [ "$(uname)" = Linux ]; then
  label="${1:?usage: $0 <label> <Copper.app on the mini> [groups]}"; app="${2:?Copper.app path on the mini}"
  host="${AGENTBENCH_HOST:-mac-mini}"
  remote="${AGENTBENCH_REMOTE_DIR:-hc/harness}"
  rsync -az --exclude __pycache__ "$here/" "$host:$remote/"
  envs=""; for v in ARMS ROUNDS_ULTRAFAST ROUNDS_WIKIGAME ROUNDS_UIBENCH ROUNDS_REALWEB TASKS ULTRAFAST_DIR AGENTBENCH_ALLOW_CHROME \
      AGENTBENCH_WORLD AGENTBENCH_PORT AGENTBENCH_FIXPORT AGENTBENCH_VIEWPORT AGENTBENCH_TEXT_MODEL AGENTBENCH_JEV_ENDPOINT AGENTBENCH_PRIVATE; do
    [ -n "${!v:-}" ] && envs+="$v=$(printf %q "${!v}") "; done
  ssh "$host" "cd $remote && $envs ./agentbench.sh $(printf %q "$label") $(printf %q "$app") ${3:-}" || echo "remote run exited $?"
  dest="$HOME/plans/copper-hillclimb-2026-11-14/out/$label/agentbench"
  mkdir -p "$dest" && rsync -az "$host:hc/out/$label/agentbench/" "$dest/"
  echo "copied to $dest"; exit 0
fi

world="${AGENTBENCH_WORLD:-agentbench}"; port="${AGENTBENCH_PORT:-4160}"; fixport="${AGENTBENCH_FIXPORT:-4161}"
support="$HOME/Library/Application Support"
folder="$support/Copper ($world)"
label_="dev.hillclimb.$world"; plist="/tmp/hc-$world.plist"
lock="$HOME/hc/mini.lock"
fixtures="$here/agentbench/fixtures"

up() {
  local app; app="$(cd "$1" && pwd)"
  mkdir -p "$folder"; chmod 700 "$folder"
  # agent.json: loopback server + Jev on, our own token (kept across runs)
  python3 - "$folder" "$port" <<'PY'
import json, os, secrets, sys
folder, port = sys.argv[1], int(sys.argv[2])
p = os.path.join(folder, "agent.json")
cur = json.load(open(p)) if os.path.exists(p) else {}
cur.update({"enabled": True, "port": port, "announces": False, "jev": True})
cur.setdefault("token", secrets.token_hex(32))
with open(os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f: json.dump(cur, f)
# intelligence.json: only the Jev + text-model keys, copied from the dev world; never printed
src = os.path.expanduser("~/Library/Application Support/Copper (dev)/intelligence.json")
keep = ["jevKey", "jevEndpoint", "jevModel", "routerKey", "routerURL", "routerModel", "textModel"]
dev = json.load(open(src))
out = {k: dev[k] for k in keep if k in dev}
missing = [k for k in ("jevKey", "routerKey") if k not in out]
if missing: sys.exit("dev world intelligence.json lacks " + ",".join(missing))
text = os.environ.get("AGENTBENCH_TEXT_MODEL", "")
if text == "default": out.pop("textModel", None)
elif text: out["textModel"] = text
if os.environ.get("AGENTBENCH_JEV_ENDPOINT"): out["jevEndpoint"] = os.environ["AGENTBENCH_JEV_ENDPOINT"]
q = os.path.join(folder, "intelligence.json")
with open(os.open(q, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f: json.dump(out, f)
print("world ready: agent.json + intelligence.json (" + ",".join(sorted(out)) + ")")
PY
  local domain="com.collinrijock.copper.test.$world"
  defaults write "$domain" welcomed -bool true
  defaults write "$domain" bench -bool true
  cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>$label_</string>
 <key>EnvironmentVariables</key><dict>
  <!-- base measured a 1280×800 page at 1440x900 and at 1280x880 (runs record it); upstream used 1120×780 -->
  <key>SEARCH_PROBE</key><string>$world</string><key>SEARCH_HEADLESS</key><string>1</string>
  <key>SEARCH_MCP_PORT</key><string>$port</string><key>SEARCH_HEADLESS_SIZE</key><string>${SEARCH_HEADLESS_SIZE:-1280x880}</string>
  <!-- the page an agent's own tab gets (builds from hc/jev on; older builds ignore it and stay 1280×800) -->
  <key>SEARCH_BACKSTAGE_SIZE</key><string>${AGENTBENCH_VIEWPORT:-1280x800}</string></dict>
 <key>KeepAlive</key><false/><key>RunAtLoad</key><true/>
 <key>LimitLoadToSessionType</key><string>Aqua</string>
 <key>ProgramArguments</key><array><string>$app/Contents/MacOS/Copper</string></array>
 <key>StandardErrorPath</key><string>/tmp/hc-$world.log</string><key>StandardOutPath</key><string>/tmp/hc-$world.out</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$label_" 2>/dev/null && sleep 3 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  for _ in $(seq 1 120); do
    curl -s -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
    lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5
  done
  lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null || { echo "probe did not come up (log /tmp/hc-$world.log)" >&2; exit 1; }
  # fixture server: uibench app + ultrafast's hotel fixture
  if ! curl -s -m 2 "http://127.0.0.1:$fixport/app" >/dev/null; then
    nohup python3 "$fixtures/server.py" --port "$fixport" >/tmp/hc-$world-fixtures.log 2>&1 &
    sleep 1
  fi
  echo "probe $world up: pid $(lsof -tiTCP:$port -sTCP:LISTEN) port $port; fixtures :$fixport"
}

down() {
  launchctl bootout "gui/$(id -u)/$label_" 2>/dev/null && echo "probe $world stopped" || true
  pkill -f "$fixtures/server.py --port $fixport" 2>/dev/null || true
}

case "${1:-}" in
  up) up "${2:?Copper.app}"; exit 0 ;;
  down) down; exit 0 ;;
esac

label="${1:?usage: $0 <label> <Copper.app> [groups]}"
groups="${3:-ultrafast,wikigame,uibench,realweb}"
out="$HOME/hc/out/$label/agentbench"; mkdir -p "$out"
# run from our own copy: other tracks `pkill -f <app path>` their probes of the same build
app="$HOME/hc/agentbench-app/$label/Copper.app"
mkdir -p "$(dirname "$app")" && rsync -a --delete "${2:?Copper.app}/" "$app/"
touch "$lock"
trap down EXIT
up "$app" | tee -a "$out/run.log"
py=(python3 "$here/agentbench/agentbench.py" --port "$port" --world "$world" --fixtures "http://127.0.0.1:$fixport"
    --out "$out" --arms "${ARMS:-shipped,turbo,classic,llm-haiku}" --app "$app")
[ -n "${AGENTBENCH_VIEWPORT:-}" ] && py+=(--viewport "$AGENTBENCH_VIEWPORT")
[ -n "${TASKS:-}" ] && py+=(--tasks "$TASKS")
"${py[@]}" --meta | tee -a "$out/run.log"
for g in ${groups//,/ }; do
  var="ROUNDS_$(echo "$g" | tr a-z A-Z)"
  case "$g" in ultrafast) def=10 ;; wikigame) def=1 ;; *) def=2 ;; esac
  rounds="${!var:-$def}"
  for r in $(seq 1 "$rounds"); do
    # Google Flights answers searches made seconds apart with "Oops, something went wrong" (measured 2026-11-14:
    # rounds ~20 s apart lost 2 runs in 7 to it, rounds ≥60 s apart 0 in 20), so rounds with Flights in them are spaced, outside the lock
    [ "$g" = ultrafast ] && [ "$r" -gt 1 ] && sleep "${AGENTBENCH_FLIGHTS_GAP:-45}"
    # one locked batch = one round of one group (every task × every arm, arms alternating)
    # already-recorded (task, arm, round) runs are skipped, so a rerun resumes; exit 3 = the probe died
    for try in 1 2 3; do
      lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null || { echo "probe down — restarting" | tee -a "$out/run.log"; up "$app" >>"$out/run.log"; }
      set +e; lockf -k "$lock" "${py[@]}" --group "$g" --round "$r" 2>&1 | tee -a "$out/run.log"; rc=${PIPESTATUS[0]}; set -e
      [ "$rc" = 3 ] || break
    done
  done
done
"${py[@]}" --summary | tee "$out/summary.md"
