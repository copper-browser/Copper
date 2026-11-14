#!/bin/bash
# Track B (UI/UX) evidence pack for one Copper build — see ux/README.md.
#
#   perf/hillclimb/ux.sh LABEL /path/to/Copper.app
#
# On the Retina laptop (or any Mac with a GUI login): two headless probe worlds
# of APP on ports 4140–4148 (never the installed Copper, never 4123, nothing
# brought forward), every surface pictured light + dark at 1440×900 and
# 1728×1117, scripted keyboard/findability checks, and an OCR audit.
# Writes ~/hc/out/LABEL/ux/{shots/,shots.json,keys.json,audit.md,audit.json,run.json}.
# UX_ONLY=surface,surface reruns just those pictures (no checks).
# UX_MODE=keywin (mini only): the key-window run instead — B13 keyboard/VoiceOver checks and B14
#   motion recordings in one windowed probe world, under lockf ~/hc/mini.lock → keywin.json, motion/.
# UX_PORTS=4231-4232 / UX_SITE_PORT=4233 / UX_BIN=dir: a worker's own ports and tool folder.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:?usage: $0 LABEL /path/to/Copper.app}"
APP="$(cd "${2:?usage: $0 LABEL /path/to/Copper.app}" && pwd)"
OUT="${UX_OUT:-$HOME/hc/out/$LABEL/ux}"
PORT="${UX_SITE_PORT:-4149}"
[ -x "$APP/Contents/MacOS/Copper" ] || { echo "no Copper at $APP" >&2; exit 1; }
case "$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)" in
  com.collinrijock.copper.dev) ;;
  *) echo "refusing: $APP is not a dev build (com.collinrijock.copper.dev)" >&2; exit 1 ;;
esac
mkdir -p "$OUT"
# Small Swift tools (Vision OCR, picture sums), built once per harness copy.
BIN="${UX_BIN:-$HOME/hc/bin}"
mkdir -p "$BIN"
for t in ocr pix; do
  if [ ! -x "$BIN/ux-$t" ] || [ "$HERE/ux/$t.swift" -nt "$BIN/ux-$t" ]; then swiftc -O "$HERE/ux/$t.swift" -o "$BIN/ux-$t"; fi
done
export UX_PIX="$BIN/ux-pix"
[ -n "${UX_ONLY:-}" ] || [ "${UX_MODE:-}" = keywin ] || rm -rf "$OUT/shots"

# The fixture site: fixed pages + a file to download, served from a copy
# (the harness folder is re-synced with --delete while runs go on).
SITE="$HOME/hc/ux-site-$PORT"  # per port: two workers never share one
rm -rf "$SITE"; mkdir -p "$SITE/files"; cp -R "$HERE/ux/site/." "$SITE/"
dd if=/dev/zero of="$SITE/files/report-2026.zip" bs=1024 count=2048 2>/dev/null
SERVER=""
if ! curl -fsS -o /dev/null "http://127.0.0.1:$PORT/article.html" 2>/dev/null; then
  python3 -m http.server --bind 127.0.0.1 "$PORT" --directory "$SITE" >"$OUT/site.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 20); do curl -fsS -o /dev/null "http://127.0.0.1:$PORT/article.html" 2>/dev/null && break; sleep 0.25; done
fi
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || :' EXIT

echo "load before: $(sysctl -n vm.loadavg)"
if [ "${UX_MODE:-}" = keywin ]; then
  rm -rf "$OUT/keywin" "$OUT/motion"
  lockf "$HOME/hc/mini.lock" python3 "$HERE/ux/keywin.py" "$LABEL" "$APP" "$OUT"
  python3 "$HERE/ux/audit.py" "$OUT" "$HERE/ux/site"
  echo "done: $OUT"; exit 0
fi
python3 "$HERE/ux/drive.py" "$LABEL" "$APP" "$OUT"

# The audit: OCR every picture (Vision), then contrast / sizes / truncation + the checks.
if [ -z "${UX_ONLY:-}" ]; then
  "$BIN/ux-ocr" "$OUT/shots"/*.png > "$OUT/ocr.jsonl"
  python3 "$HERE/ux/audit.py" "$OUT" "$HERE/ux/site"
fi
echo "load after: $(sysctl -n vm.loadavg)"
echo "done: $OUT"
