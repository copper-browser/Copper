#!/bin/bash
# Before/after pictures of two evidence packs, side by side, and a one-page
# index of only the pairs that differ visibly.
#
#   perf/hillclimb/ux/before-after.sh LABEL_A LABEL_B
#
# Reads $HC_OUT/LABEL_{A,B}/ux/shots/*.png (default HC_OUT =
# ~/plans/copper-hillclimb-2026-11-14/out) and writes
# $HC_OUT/LABEL_B/before-after/{<name>.jpg,INDEX.md}. A pair "differs
# visibly" when more than UX_DIFF_PCT percent (default 0.05) of its pixels
# moved by more than UX_FUZZ (default 8%) and more than twice its own noise
# (ux/noise.txt: two runs of the same build). Needs ImageMagick (devbox has it).
set -euo pipefail
A="${1:?usage: $0 LABEL_A LABEL_B}"; B="${2:?usage: $0 LABEL_A LABEL_B}"
ROOT="${HC_OUT:-$HOME/plans/copper-hillclimb-2026-11-14/out}"
SA="$ROOT/$A/ux/shots"; SB="$ROOT/$B/ux/shots"
DEST="$ROOT/$B/before-after"
PCT="${UX_DIFF_PCT:-0.05}"; FUZZ="${UX_FUZZ:-8%}"
[ -d "$SA" ] && [ -d "$SB" ] || { echo "need $SA and $SB" >&2; exit 1; }
command -v compare >/dev/null || { echo "needs ImageMagick (compare, convert)" >&2; exit 1; }
rm -rf "$DEST"; mkdir -p "$DEST"

# One line per shared picture: name, percent of pixels changed (100 if sizes differ).
measure() {
  local a="$SA/$1" b="$SB/$1" n
  if [ "$(identify -format %wx%h "$a")" != "$(identify -format %wx%h "$b")" ]; then echo "$1 100"; return; fi
  n=$(compare -metric AE -fuzz "$FUZZ" "$a" "$b" null: 2>&1 >/dev/null | awk '{print int($1)}') || :
  echo "$1 $(identify -format "%[fx:100*$n/(w*h)]" "$a")"
}
export -f measure; export SA SB FUZZ
comm -12 <(ls "$SA" | sort) <(ls "$SB" | sort) | grep '\.png$' \
  | xargs -P "${UX_JOBS:-8}" -I{} bash -c 'measure "$@"' _ {} | sort > "$DEST/diff.txt"

side() { # NAME → DEST/NAME.jpg, A on the left, B on the right, each labelled
  local name="$1" out="$DEST/${1%.png}.jpg"
  convert \( "$SA/$name" -resize 1600x -background white -gravity north -splice 0x56 -pointsize 34 -fill '#333' -annotate +0+10 "$A" \) \
          \( "$SB/$name" -resize 1600x -background white -gravity north -splice 0x56 -pointsize 34 -fill '#333' -annotate +0+10 "$B" \) \
          -background white -gravity north +append -quality 82 "$out"
}
# Per-picture noise (ux/noise.txt, two runs of one build): live page titles and
# Google's suggestions move a few rows; a pair must beat twice its noise.
NOISE="${UX_NOISE:-$(dirname "$0")/noise.txt}"
VISIBLE=$(awk -v p="$PCT" 'NR == FNR { if ($1 !~ /^#/) n[$1] = $2; next } { t = p; if (2 * n[$1] > t) t = 2 * n[$1]; if ($2 > t) print $1 }' \
  "$( [ -f "$NOISE" ] && echo "$NOISE" || echo /dev/null)" "$DEST/diff.txt")
for name in $VISIBLE; do side "$name"; done

{
  echo "# Before / after — $A → $B"
  echo
  total=$(wc -l < "$DEST/diff.txt" | tr -d ' ')
  shown=$(printf '%s\n' $VISIBLE | grep -c . || :)
  echo "$shown of $total picture pairs differ visibly (> $PCT% of pixels moved by > $FUZZ, and over twice that picture's same-build noise in ux/noise.txt). Left = $A, right = $B."
  echo
  if [ -n "$VISIBLE" ]; then
    echo "| Surface | Theme | Size | Changed | Picture |"
    echo "|---|---|---|---|---|"
    for name in $VISIBLE; do
      pct=$(awk -v n="$name" '$1 == n {printf "%.2f%%", $2}' "$DEST/diff.txt")
      base="${name%.png}"; size="${base##*-}"; rest="${base%-*}"; theme="${rest##*-}"; surface="${rest%-*}"
      echo "| $surface | $theme | $size | $pct | [${base}.jpg](${base}.jpg) |"
    done
    echo
    for name in $VISIBLE; do echo "### ${name%.png}"; echo; echo "![${name%.png}](${name%.png}.jpg)"; echo; done
  fi
  onlyA=$(comm -23 <(ls "$SA" | sort) <(ls "$SB" | sort) | tr '\n' ' ')
  onlyB=$(comm -13 <(ls "$SA" | sort) <(ls "$SB" | sort) | tr '\n' ' ')
  [ -z "$onlyA" ] || echo "Only in $A (gone in $B): $onlyA"
  [ -z "$onlyB" ] || echo "Only in $B (new): $onlyB"
} > "$DEST/INDEX.md"
echo "$DEST/INDEX.md"
