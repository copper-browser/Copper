#!/bin/bash
# Apple's notary service, resumable. Sourced by release/package-app.sh:
#
#   . release/notary.sh
#   id="$(notary_run <file> <what> <state dir>)"     # prints the id once Apple says Accepted
#
# A submission is keyed by the SHA-256 of the bytes sent. Its id goes into
# <state dir>/<sha256>.id the moment Apple hands it out (`notarytool submit`
# without --wait returns as soon as the upload is in), so a run that stops —
# a killed pipeline, a lost connection, the deadline below — and is started
# again on the same bytes waits on that submission instead of sending them a
# second time. Nothing here ever resubmits bytes Apple already has.
#
# The caller sets notary_key (the .p8 file), notary_key_id and notary_issuer,
# and say() (one status line to stderr). How long to wait: until
# COPPER_NOTARY_DEADLINE (epoch seconds), else COPPER_NOTARY_HOURS (default 4)
# from now. A submission Apple still has "In Progress" then makes notary_run
# exit 75 (EX_TEMPFAIL): run again with the same state to keep waiting. Apple's
# queue for a team can take hours (2026-11-26: over an hour a submission, some
# far longer), so a deadline is normal, not a failure of the release.
#
# COPPER_NOTARYTOOL names a stand-in for `xcrun notarytool` (release/test-notary.sh).

# shellcheck disable=SC2154  # notary_key, notary_key_id, notary_issuer: the caller's
notary_tool() {
  if [ -n "${COPPER_NOTARYTOOL:-}" ]; then "$COPPER_NOTARYTOOL" "$@"; else xcrun notarytool "$@"; fi
}

notary_field() { # notary_field KEY JSON_FILE: a top-level string of notarytool's JSON, or nothing
  plutil -extract "$1" raw -o - "$2" 2> /dev/null || true
}

notary_run() {
  local file="$1" what="$2" state="$3"
  local sha id="" status="" tmp deadline now slice started failures=0 attempt
  local auth=(--key "$notary_key" --key-id "$notary_key_id" --issuer "$notary_issuer")
  mkdir -p "$state"
  sha="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  tmp="$(mktemp -d)"
  deadline="${COPPER_NOTARY_DEADLINE:-$(($(date +%s) + ${COPPER_NOTARY_HOURS:-4} * 3600))}"

  if [ -s "$state/$sha.id" ]; then
    id="$(tr -d '[:space:]' < "$state/$sha.id")"
    say notary "$what: these bytes were sent before; waiting on submission $id again"
  else
    for attempt in 1 2 3; do
      if notary_tool submit "$file" "${auth[@]}" --output-format json > "$tmp/submit.json" 2> "$tmp/submit.err"; then
        id="$(notary_field id "$tmp/submit.json")"
      fi
      [ -n "$id" ] && break
      sed 's/^/  notarytool: /' "$tmp/submit.err" >&2
      [ "$attempt" = 3 ] || sleep $((attempt * 30))
    done
    if [ -z "$id" ]; then
      rm -rf "$tmp"
      say notary "$what: Apple did not take the submission"
      return 1
    fi
    printf '%s\n' "$id" > "$state/$sha.id"
    say notary "$what: submitted $id ($(basename "$file"), sha256 $sha)"
  fi

  while :; do
    status=""
    if notary_tool info "$id" "${auth[@]}" --output-format json > "$tmp/info.json" 2> "$tmp/info.err"; then
      status="$(notary_field status "$tmp/info.json")"
      failures=0
    else
      failures=$((failures + 1))
      sed 's/^/  notarytool: /' "$tmp/info.err" >&2
      if [ "$failures" -ge 10 ]; then
        rm -rf "$tmp"
        say notary "$what: notarytool info $id failed 10 times in a row"
        return 1
      fi
    fi
    case "$status" in
      Accepted) break ;;
      Invalid | Rejected)
        say notary "$what: $status ($id)"
        notary_tool log "$id" "${auth[@]}" >&2 || true
        rm -rf "$tmp"
        return 1
        ;;
    esac
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      rm -rf "$tmp"
      say notary "$what: still ${status:-unanswered} at the deadline ($id). Nothing is lost: run again to keep waiting on it"
      exit 75
    fi
    slice=$(((deadline - now + 59) / 60))
    [ "$slice" -le 30 ] || slice=30
    say notary "$what: ${status:-no answer} ($id); waiting up to $slice min"
    started="$(date +%s)"
    notary_tool wait "$id" "${auth[@]}" --timeout "${slice}m" --output-format json > /dev/null 2>&1 || true
    # wait answers at once when it can't reach Apple: no busy loop.
    [ $(($(date +%s) - started)) -ge 20 ] || sleep 30
  done
  rm -rf "$tmp"
  say notary "$what: Accepted ($id)"
  printf '%s' "$id"
}
