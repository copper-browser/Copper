#!/bin/bash
# release/notary.sh against a stand-in notarytool (no Apple, no credentials):
#
#   release/test-notary.sh
#
# A first run submits once and stops at its deadline with 75 while Apple is
# "In Progress"; the next run on the same bytes submits nothing and waits on
# the same id until it is Accepted; other bytes are a new submission; Invalid
# fails. Runs anywhere bash, shasum and plutil are.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
fail() { printf 'test-notary: FAIL %s\n' "$*" >&2; exit 1; }

# The stand-in: answers from $t/status, logs every call to $t/calls.
cat > "$t/notarytool" <<'TOOL'
#!/bin/bash
t="$(dirname "$0")"
echo "$*" >> "$t/calls"
case "$1" in
  submit) n=$(($(cat "$t/n" 2> /dev/null || echo 0) + 1)); echo "$n" > "$t/n"
    printf '{"id":"sub-%s","message":"uploaded"}\n' "$n" ;;
  info) printf '{"id":"%s","status":"%s"}\n' "$2" "$(cat "$t/status")" ;;
  wait) sleep 1; exit 0 ;;
  log) echo '{"issues":[]}' ;;
esac
TOOL
chmod +x "$t/notarytool"
export COPPER_NOTARYTOOL="$t/notarytool"
say() { printf '%-8s%s\n' "$1" "$2" >&2; }
notary_key=k notary_key_id=K notary_issuer=I
# shellcheck source=release/notary.sh
. "$here/notary.sh"
echo zip-bytes > "$t/app.zip"
submits() { grep -c '^submit' "$t/calls" || true; }

echo "In Progress" > "$t/status"
code=0
(COPPER_NOTARY_DEADLINE=$(($(date +%s) + 2)) notary_run "$t/app.zip" app "$t/state" > /dev/null 2>&1) || code=$?
[ "$code" = 75 ] || fail "past the deadline: exit $code, not 75"
[ "$(submits)" = 1 ] || fail "submitted $(submits) times, not once"
[ "$(cat "$t/state"/*.id)" = sub-1 ] || fail "the id was not kept"

echo Accepted > "$t/status"
id="$(COPPER_NOTARY_HOURS=1 notary_run "$t/app.zip" app "$t/state" 2> /dev/null)"
[ "$id" = sub-1 ] || fail "again: got $id, not the kept sub-1"
[ "$(submits)" = 1 ] || fail "the same bytes were sent again"

echo other-bytes > "$t/app.zip"
id="$(COPPER_NOTARY_HOURS=1 notary_run "$t/app.zip" app "$t/state" 2> /dev/null)"
[ "$id" = sub-2 ] && [ "$(submits)" = 2 ] || fail "new bytes: $id, $(submits) submissions"

echo Invalid > "$t/status"
echo third > "$t/app.zip"
code=0
(COPPER_NOTARY_HOURS=1 notary_run "$t/app.zip" app "$t/state" > /dev/null 2>&1) || code=$?
[ "$code" = 1 ] || fail "Invalid: exit $code, not 1"
echo "test-notary: ok (one submission per set of bytes; 75 at the deadline; resumed by id)"
