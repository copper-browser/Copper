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
[ -n "${UX_ONLY:-}" ] || rm -rf "$OUT/shots"

# The fixture site: fixed pages + a file to download, served from a copy
# (the harness folder is re-synced with --delete while runs go on).
SITE="$HOME/hc/ux-site"
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
python3 "$HERE/ux/drive.py" "$LABEL" "$APP" "$OUT"

# The audit: OCR every picture (Vision), then contrast / sizes / truncation + the checks.
if [ -z "${UX_ONLY:-}" ]; then
  BIN="$HOME/hc/bin/ux-ocr"
  mkdir -p "$(dirname "$BIN")"
  if [ ! -x "$BIN" ] || [ "$HERE/ux/ocr.swift" -nt "$BIN" ]; then swiftc -O "$HERE/ux/ocr.swift" -o "$BIN"; fi
  "$BIN" "$OUT/shots"/*.png > "$OUT/ocr.jsonl"
  python3 "$HERE/ux/audit.py" "$OUT" "$HERE/ux/site"
fi
echo "load after: $(sysctl -n vm.loadavg)"
echo "done: $OUT"
