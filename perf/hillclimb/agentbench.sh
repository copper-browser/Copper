#!/usr/bin/env bash
# Track D — agent performance (Jev). One suite, alternating arms, on a headless
# probe world of the given Copper.app. See agentbench/README.md.
#
#   perf/hillclimb/agentbench.sh <label> <path-to-Copper.app> [groups]
#       groups: comma list of ultrafast,wikigame,uibench,realweb,paraphrase,probes (default: the first four)
#       env: ARMS=shipped,turbo,classic,llm-haiku  ROUNDS_ULTRAFAST=10 ROUNDS_WIKIGAME=3
#            ROUNDS_UIBENCH=2 ROUNDS_REALWEB=2 ROUNDS_PARAPHRASE=2 ROUNDS_PROBES=2 TASKS=hotel,godel (only these task ids)
#   perf/hillclimb/agentbench.sh up|down <path-to-Copper.app>   # probe world only (debugging)
#       env (all optional): AGENTBENCH_WORLD=agentbench AGENTBENCH_PORT=4160 AGENTBENCH_FIXPORT=4161
#            AGENTBENCH_REMOTE_DIR=hc/harness   where the devbox syncs the harness on the mini
#            AGENTBENCH_VIEWPORT=1120x780       the page size of every run (default: the build's 1280×800)
#            AGENTBENCH_TEXT_MODEL=<name>|default   textModel of the probe world (default: the dev world's;
#                                               "default" leaves it unset = what a fresh install runs)
#            The `same` arm runs in a second probe world, <world>-same on AGENTBENCH_SAME_PORT (port+2), at
#            upstream's conditions: AGENTBENCH_SAME_VIEWPORT (1120x780) and the build's default text model.
#            AGENTBENCH_JEV_ENDPOINT=<url>      jevEndpoint of the probe world (parity/parity.py's recorder)
#            AGENTBENCH_FLIGHTS_GAP=45          seconds between Google Flights runs (Google throttles back-to-back searches)
#            AGENTBENCH_CHUNK=300               seconds of runs per hold of the shared lock
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
  envs=""; for v in ARMS ROUNDS_ULTRAFAST ROUNDS_WIKIGAME ROUNDS_UIBENCH ROUNDS_REALWEB ROUNDS_PARAPHRASE ROUNDS_PROBES TASKS ULTRAFAST_DIR AGENTBENCH_ALLOW_CHROME \
      AGENTBENCH_WORLD AGENTBENCH_PORT AGENTBENCH_FIXPORT AGENTBENCH_VIEWPORT AGENTBENCH_TEXT_MODEL AGENTBENCH_JEV_ENDPOINT AGENTBENCH_PRIVATE \
      AGENTBENCH_SAME_PORT AGENTBENCH_SAME_VIEWPORT AGENTBENCH_FLIGHTS_GAP AGENTBENCH_CHUNK; do
    [ -n "${!v:-}" ] && envs+="$v=$(printf %q "${!v}") "; done
  ssh "$host" "cd $remote && $envs ./agentbench.sh $(printf %q "$label") $(printf %q "$app") ${3:-}" || echo "remote run exited $?"
  dest="$HOME/plans/copper-hillclimb-2026-11-14/out/$label/agentbench"
  mkdir -p "$dest" && rsync -az "$host:hc/out/$label/agentbench/" "$dest/"
  echo "copied to $dest"; exit 0
fi

world="${AGENTBENCH_WORLD:-agentbench}"; port="${AGENTBENCH_PORT:-4160}"; fixport="${AGENTBENCH_FIXPORT:-4161}"
same_world="$world-same"; same_port="${AGENTBENCH_SAME_PORT:-$((port + 2))}"; same_viewport="${AGENTBENCH_SAME_VIEWPORT:-1120x780}"
support="$HOME/Library/Application Support"
lock="$HOME/hc/mini.lock"
fixtures="$here/agentbench/fixtures"

# up <app> <world> <port> <viewport or ""> <text model or "">
up() {
  local app w="$2" p="$3" vp="$4" text="$5"; app="$(cd "$1" && pwd)"
  local folder="$support/Copper ($w)" label_="dev.hillclimb.$w" plist="/tmp/hc-$w.plist"
  mkdir -p "$folder"; chmod 700 "$folder"
  # agent.json: loopback server + Jev on, our own token (kept across runs)
  AGENTBENCH_TEXT_MODEL="$text" python3 - "$folder" "$p" <<'PY'
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
print("world ready: agent.json + intelligence.json (" + ",".join(sorted(out)) + "), textModel " + str(out.get("textModel", "(build default)")))
PY
  local domain="com.collinrijock.copper.test.$w"
  defaults write "$domain" welcomed -bool true
  defaults write "$domain" bench -bool true
  # The agent's page takes the size of the page in front (the headless window's), else
  # SEARCH_BACKSTAGE_SIZE: with a viewport asked for, both are that size.
  cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>$label_</string>
 <key>EnvironmentVariables</key><dict>
  <key>SEARCH_PROBE</key><string>$w</string><key>SEARCH_HEADLESS</key><string>1</string>
  <key>SEARCH_MCP_PORT</key><string>$p</string><key>SEARCH_HEADLESS_SIZE</key><string>${vp:-${SEARCH_HEADLESS_SIZE:-1280x880}}</string>
  <key>SEARCH_BACKSTAGE_SIZE</key><string>${vp:-1280x800}</string></dict>
 <key>KeepAlive</key><false/><key>RunAtLoad</key><true/>
 <key>LimitLoadToSessionType</key><string>Aqua</string>
 <key>ProgramArguments</key><array><string>$app/Contents/MacOS/Copper</string></array>
 <key>StandardErrorPath</key><string>/tmp/hc-$w.log</string><key>StandardOutPath</key><string>/tmp/hc-$w.out</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$label_" 2>/dev/null && sleep 3 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  for _ in $(seq 1 120); do
    curl -s -m 2 "http://127.0.0.1:$p/health" >/dev/null 2>&1 && break
    lsof -tiTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5
  done
  lsof -tiTCP:"$p" -sTCP:LISTEN >/dev/null || { echo "probe did not come up (log /tmp/hc-$w.log)" >&2; exit 1; }
  # fixture server: uibench app + ultrafast's hotel fixture
  if ! curl -s -m 2 "http://127.0.0.1:$fixport/app" >/dev/null; then
    nohup python3 "$fixtures/server.py" --port "$fixport" >/tmp/hc-$world-fixtures.log 2>&1 &
    sleep 1
  fi
  echo "probe $w up: pid $(lsof -tiTCP:$p -sTCP:LISTEN) port $p, viewport ${vp:-build default}; fixtures :$fixport"
}

up_all() {
  up "$1" "$world" "$port" "${AGENTBENCH_VIEWPORT:-}" "${AGENTBENCH_TEXT_MODEL:-}"
  case ",${ARMS:-}," in *,same,*) up "$1" "$same_world" "$same_port" "$same_viewport" default ;; esac
}

down() {
  for w in "$world" "$same_world"; do launchctl bootout "gui/$(id -u)/dev.hillclimb.$w" 2>/dev/null && echo "probe $w stopped" || true; done
  pkill -f "$fixtures/server.py --port $fixport" 2>/dev/null || true
}

case "${1:-}" in
  up) up_all "${2:?Copper.app}"; exit 0 ;;
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
up_all "$app" | tee -a "$out/run.log"
py=(python3 "$here/agentbench/agentbench.py" --port "$port" --world "$world" --fixtures "http://127.0.0.1:$fixport"
    --out "$out" --arms "${ARMS:-shipped,turbo,classic,llm-haiku}" --app "$app" --same-world "$same_world" --same-port "$same_port")
[ -n "${AGENTBENCH_VIEWPORT:-}" ] && py+=(--viewport "$AGENTBENCH_VIEWPORT")
case ",${ARMS:-}," in *,same,*) py+=(--same-viewport "$same_viewport") ;; esac
[ -n "${TASKS:-}" ] && py+=(--tasks "$TASKS")
"${py[@]}" --meta | tee -a "$out/run.log"
# The whole suite is one plan; each locked batch runs AGENTBENCH_CHUNK seconds of it (default 300): the lock is
# shared and every wait for it is long, so few long holds beat a hold per round. agentbench.py exits 4 when its
# chunk is used up, 5 when only Google Flights runs are left and the next must wait (outside the lock), 3 when a
# probe died; already-recorded (task, arm, round) runs are skipped, so a rerun resumes.
rounds="ultrafast=${ROUNDS_ULTRAFAST:-10},wikigame=${ROUNDS_WIKIGAME:-3},uibench=${ROUNDS_UIBENCH:-2},realweb=${ROUNDS_REALWEB:-2}"
rounds+=",paraphrase=${ROUNDS_PARAPHRASE:-2},probes=${ROUNDS_PROBES:-2}"
restarts=0
while :; do
  { lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null && case ",${ARMS:-}," in *,same,*) lsof -tiTCP:"$same_port" -sTCP:LISTEN >/dev/null ;; esac; } \
    || { echo "probe down — restarting" | tee -a "$out/run.log"; up_all "$app" >>"$out/run.log"; }
  set +e
  lockf -k "$lock" "${py[@]}" --groups "$groups" --rounds "$rounds" --chunk "${AGENTBENCH_CHUNK:-300}" </dev/null 2>&1 | tee -a "$out/run.log"
  rc=${PIPESTATUS[0]}; set -e
  case "$rc" in
    0) break ;;
    4) ;;
    5) sleep "${AGENTBENCH_FLIGHTS_GAP:-45}" ;;
    3) restarts=$((restarts + 1)); [ "$restarts" -le 3 ] || { echo "probe keeps dying — stopping" | tee -a "$out/run.log"; break; } ;;
    *) echo "agentbench.py exited $rc — stopping" | tee -a "$out/run.log"; break ;;
  esac
done
"${py[@]}" --summary | tee "$out/summary.md"
