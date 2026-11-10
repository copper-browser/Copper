#!/usr/bin/env bash
# Start / stop a headless PROBE Copper as a launchd job in the GUI session —
# for an ssh session (e.g. a reference Mac), where `open` fails with -10810 and
# `launchctl asuser` is not permitted.
#
#   launchd-probe.sh start APP [WORLD] [PORT]   # default world cfix, port 4203
#   launchd-probe.sh stop  [WORLD]              # bootout: stops ONLY this job
#
# Writes /tmp/fixture-<world>.plist; logs to /tmp/fixture-<world>.log (a log path
# on /Volumes makes launchd fail the job with EX_CONFIG). Refuses port 4123.
set -euo pipefail
cmd="${1:-}"; shift || true
case "$cmd" in
  start)
    app="${1:?usage: $0 start APP [WORLD] [PORT]}"; world="${2:-cfix}"; port="${3:-4203}"
    [[ "$port" != 4123 ]] || { echo "refusing port 4123 (the everyday Copper's)" >&2; exit 2; }
    app="$(cd "$app" && pwd)"
    label="dev.farm.fixture.$world"; plist="/tmp/fixture-$world.plist"
    cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>$label</string>
 <key>EnvironmentVariables</key><dict>
  <key>SEARCH_PROBE</key><string>$world</string><key>SEARCH_HEADLESS</key><string>1</string>
  <key>SEARCH_MCP_PORT</key><string>$port</string><key>SEARCH_HEADLESS_SIZE</key><string>${SEARCH_HEADLESS_SIZE:-1840x1240}</string></dict>
 <key>KeepAlive</key><false/><key>RunAtLoad</key><true/>
 <key>LimitLoadToSessionType</key><string>Aqua</string>
 <key>ProgramArguments</key><array><string>$app/Contents/MacOS/Copper</string></array>
 <key>StandardErrorPath</key><string>/tmp/fixture-$world.log</string><key>StandardOutPath</key><string>/tmp/fixture-$world.out</string>
</dict></plist>
PLIST
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null && sleep 4 || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    for _ in $(seq 1 240); do
      pid="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
      [[ -n "$pid" ]] && { echo "probe $world: pid $pid on $port (log /tmp/fixture-$world.log)"; exit 0; }
      sleep 0.25
    done
    echo "probe did not come up; see /tmp/fixture-$world.log" >&2; exit 1 ;;
  stop)
    world="${1:-cfix}"
    launchctl bootout "gui/$(id -u)/dev.farm.fixture.$world" && echo "probe $world stopped" ;;
  *) echo "usage: $0 start APP [WORLD] [PORT] | stop [WORLD]" >&2; exit 2 ;;
esac
