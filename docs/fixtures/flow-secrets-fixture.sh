#!/bin/bash
# A synthetic, encrypted Chrome profile and the move that reads it with a
# test passphrase — passwords, signed-in state and passkeys included —
# without the keychain ever being asked.
#
#   docs/fixtures/flow-secrets-fixture.sh --make DIR   only write the fixture:
#       DIR/Chrome/Default/{Preferences,Sessions/,Bookmarks,History,Login Data,Cookies}
#       DIR/passphrase   (the profile's "Safe Storage" passphrase, synthetic)
#   docs/fixtures/flow-secrets-fixture.sh [build/Copper.app]
#       write it to a private temp folder and prove, in a fresh headless world:
#       - every secret arrives in the test run's in-memory stand-in (passwords
#         decrypt to the right text, 2 passkeys, 3 cookies in the world's own
#         website store), the summary has a line per category;
#       - moving in again adds nothing (0 tabs, bookmarks, places, passwords,
#         passkeys; no new space);
#       - a broken cookie jar costs only the signed-in state (passwords still
#         arrive), and says so;
#       - without a test passphrase a test run reads no secrets, and says so.
#
# Encryption is Chromium's on macOS: "v10" + AES-128-CBC, IV of 16 spaces,
# key = PBKDF2-HMAC-SHA1(passphrase, "saltysalt", 1003 rounds, 16 bytes).
# Cookie values carry Chromium's SHA-256(host) prefix (cookie DB v24).
# Needs python3 and /usr/bin/openssl (both ship with macOS).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

make_fixture() {
  local out="$1"
  mkdir -p "$out/Chrome/Default/Sessions"
  printf 'copper-fixture-passphrase\n' > "$out/passphrase"
  printf '{"profile":{"name":"Fixture"}}\n' > "$out/Chrome/Default/Preferences"
  # One window, one tab (SNSS v1), as the other Flow fixtures write it.
  perl -e '
    use strict; use warnings;
    sub cmd { my ($id,$p) = @_; return pack("vC", length($p)+1, $id).$p }
    sub field { my ($s) = @_; my $p = pack("V",length($s)).$s; return $p.("\0" x ((4-length($s)%4)%4)) }
    sub field16 { my ($s) = @_; my $p = pack("v*", unpack("C*", $s)); return pack("V",length($s)).$p.("\0" x ((4-length($p)%4)%4)) }
    my $nav = pack("V2", 7, 0).field("https://alpha.invalid/inbox").field16("Alpha").pack("V2",0,0);
    $nav = pack("V",length($nav)).$nav;
    print "SNSS",pack("V",1),cmd(0,pack("V2",1,7)),cmd(2,pack("V2",7,0)),cmd(8,pack("V2",1,0)),cmd(6,$nav);
  ' > "$out/Chrome/Default/Sessions/Current Session"
  python3 - "$out" <<'PY'
import hashlib, json, os, sqlite3, subprocess, sys, time
out = sys.argv[1]
profile = os.path.join(out, "Chrome", "Default")
passphrase = open(os.path.join(out, "passphrase")).read().strip()
key = hashlib.pbkdf2_hmac("sha1", passphrase.encode(), b"saltysalt", 1003, 16)

def v10(plain: bytes) -> bytes:
    enc = subprocess.run(["/usr/bin/openssl", "enc", "-aes-128-cbc", "-K", key.hex(), "-iv", "20" * 16],
                         input=plain, capture_output=True, check=True).stdout
    return b"v10" + enc

def chromium_time(seconds: float) -> int:
    return int((seconds + 11644473600) * 1_000_000)

now = time.time()

# Bookmarks: two sites on the bar.
json.dump({"roots": {
    "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
        {"type": "url", "name": "Alpha", "url": "https://alpha.invalid/"},
        {"type": "url", "name": "Beta", "url": "https://beta.invalid/"}]},
    "other": {"type": "folder", "name": "Other bookmarks", "children": []},
    "synced": {"type": "folder", "name": "Mobile bookmarks", "children": []}},
    "version": 1}, open(os.path.join(profile, "Bookmarks"), "w"))

# History: three places.
db = sqlite3.connect(os.path.join(profile, "History"))
db.execute("CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER)")
for i, (url, title) in enumerate([("https://alpha.invalid/inbox", "Alpha"),
                                  ("https://beta.invalid/", "Beta"),
                                  ("https://gamma.invalid/notes", "Gamma")]):
    db.execute("INSERT INTO urls VALUES (?,?,?,?,?,?,0)", (i + 1, url, title, 3, 1, chromium_time(now - 3600 * (i + 1))))
db.commit(); db.close()

# Login Data: two logins, one "never save" site, two passkeys (one hidden).
db = sqlite3.connect(os.path.join(profile, "Login Data"))
db.execute("""CREATE TABLE logins (origin_url TEXT, action_url TEXT, username_element TEXT, username_value TEXT,
              password_element TEXT, password_value BLOB, signon_realm TEXT, date_created INTEGER,
              blacklisted_by_user INTEGER, date_last_used INTEGER)""")
rows = [("https://alpha.invalid/login", "alice", b"alpha-secret-1", 0),
        ("https://beta.invalid/", "bob", b"beta-secret-2", 0),
        ("https://never.invalid/", "", b"", 1)]
for origin, user, password, never in rows:
    db.execute("INSERT INTO logins VALUES (?,?,?,?,?,?,?,?,?,?)",
               (origin, origin, "user", user, "pass", v10(password) if password else b"", origin,
                chromium_time(now - 86400), never, chromium_time(now - 7200)))
db.execute("""CREATE TABLE webauthn_credentials (credential_id BLOB, rp_id TEXT, user_id BLOB, user_name TEXT,
              user_display_name TEXT, private_key BLOB, creation_time INTEGER, last_used_time INTEGER, hidden INTEGER)""")
for i, (rp, name, hidden) in enumerate([("alpha.invalid", "alice", 0),
                                        ("beta.invalid", "bob", 0),
                                        ("hidden.invalid", "carol", 1)]):
    sec1 = subprocess.run(["/usr/bin/openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-outform", "DER"],
                          capture_output=True, check=True).stdout
    pkcs8 = subprocess.run(["/usr/bin/openssl", "pkcs8", "-topk8", "-nocrypt", "-inform", "DER", "-outform", "DER"],
                           input=sec1, capture_output=True, check=True).stdout
    db.execute("INSERT INTO webauthn_credentials VALUES (?,?,?,?,?,?,?,?,?)",
               (hashlib.sha256(f"credential-{i}".encode()).digest()[:16], rp, f"user-{i}".encode(), name,
                name.title(), v10(pkcs8), chromium_time(now - 86400 * 3), chromium_time(now - 86400), hidden))
db.commit(); db.close()

# Cookies: three live (two sites), one expired.
db = sqlite3.connect(os.path.join(profile, "Cookies"))
db.execute("""CREATE TABLE cookies (creation_utc INTEGER, host_key TEXT, top_frame_site_key TEXT, name TEXT, value TEXT,
              encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER,
              last_access_utc INTEGER, has_expires INTEGER, is_persistent INTEGER, priority INTEGER, samesite INTEGER,
              source_scheme INTEGER, source_port INTEGER, last_update_utc INTEGER)""")
db.execute("CREATE TABLE meta (key TEXT, value TEXT)")
db.execute("INSERT INTO meta VALUES ('version', '24')")
cookies = [(".alpha.invalid", "session", "alpha-session", now + 86400 * 30),
           ("alpha.invalid", "prefs", "dark", now + 86400 * 30),
           (".beta.invalid", "sid", "beta-sid", now + 86400 * 30),
           (".beta.invalid", "old", "gone", now - 86400)]
for host, name, value, expires in cookies:
    prefixed = hashlib.sha256(host.encode()).digest() + value.encode()
    db.execute("INSERT INTO cookies VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
               (chromium_time(now - 3600), host, "", name, "", v10(prefixed), "/", chromium_time(expires), 1, 1,
                chromium_time(now - 600), 1, 1, 1, 1, 2, 443, chromium_time(now - 600)))
db.commit(); db.close()
PY
}

if [ "${1:-}" = "--make" ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 --make DIR" >&2; exit 2; }
  make_fixture "$2"
  echo "ok: fixture in $2 (passphrase in $2/passphrase)"
  exit 0
fi

APP=${1:-"$ROOT/build/Copper.app"}
[ -x "$APP/Contents/MacOS/Copper" ] || { echo "FAIL: build Copper first (./build.sh)" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/flow-secrets.XXXXXX")
WORLD="flowsecrets$(date +%s)$$"
PORT=$((44000 + $$ % 9000))
DOMAIN="com.collinrijock.copper.test.$WORLD"
HOME_WORLD="$HOME/Library/Application Support/Copper ($WORLD)"
PID=""
cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    case "$(ps -p "$PID" -o command= 2>/dev/null || :)" in
      "$APP/Contents/MacOS/Copper"*) kill "$PID" 2>/dev/null || :; sleep 1; kill -9 "$PID" 2>/dev/null || : ;;
    esac
  fi
  defaults delete "$DOMAIN" >/dev/null 2>&1 || :
  rm -rf "$HOME_WORLD" "$TEMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$TEMP/copper.log" ] || tail -n 12 "$TEMP/copper.log" >&2; exit 1; }
ok() { echo "ok: $*"; }
B() { "$ROOT/bench" --world "$WORLD" "$@"; }
check() { printf '%s\n' "$3" | jq -e "$2" >/dev/null || fail "$1: $3"; }
digest() { python3 -c 'import sys
h = 0xcbf29ce484222325
for b in sys.argv[1].encode(): h = ((h ^ b) * 0x100000001b3) & 0xffffffffffffffff
print("%016x" % h)' "$1"; }

make_fixture "$TEMP/fixture"
ok "synthetic encrypted Chrome profile written"

[ ! -e "$HOME_WORLD" ] || fail "probe world already exists"
defaults write "$DOMAIN" bench -bool true
defaults write "$DOMAIN" welcomed -bool true
open -n -g --stderr "$TEMP/copper.log" --env SEARCH_PROBE="$WORLD" --env SEARCH_HEADLESS=1 --env SEARCH_MCP_PORT="$PORT" "$APP"
for _ in $(seq 1 120); do
  PID=$(sed -n 's/.*on — pid \([0-9][0-9]*\).*/\1/p' "$TEMP/copper.log" 2>/dev/null | head -1)
  [ -n "$PID" ] && B tabs >/dev/null 2>&1 && break
  sleep 0.5
done
[ -n "$PID" ] || fail "headless probe did not start"
case "$(ps -p "$PID" -o command= 2>/dev/null || :)" in
  "$APP/Contents/MacOS/Copper"*) ;;
  *) PID=""; fail "pid in the log is not this build" ;;
esac
ok "probe $WORLD up (pid $PID)"

B flow limit --only Chrome >/dev/null
B flow root --source Chrome --path "$TEMP/fixture/Chrome" >/dev/null

# Without a test passphrase, a test run reads no secrets — and says why.
OUT=$(B flow move --source Chrome --only passwords,cookies,passkeys 2>/dev/null)
check "no passphrase: nothing read" '.passwords == 0 and .cookies == 0 and .passkeys == 0' "$OUT"
check "no passphrase: the reason is said" '[.summary[] | select(test("test run reads no keychain"))] | length == 3' "$OUT"
check "no passphrase: nothing in the stand-in" '(.passwords | length) == 0' "$(B flow secrets)"
ok "without a test passphrase: no secrets read, three lines say why"

B flow passphrase --source Chrome --path "$TEMP/fixture/passphrase" >/dev/null
SPACES0=$(B flow spaces | jq '.spaces | length')
FIRST=$(B flow move --source Chrome --only tabs,bookmarks,history,passwords,cookies,passkeys 2>/dev/null)
check "first move: tabs" '.tabs == 1 and .spacesMade == 1' "$FIRST"
check "first move: bookmarks and history" '.bookmarks == 2 and .bookmarksNew == 2 and .places == 3 and .placesNew == 3' "$FIRST"
check "first move: passwords" '.passwords == 2 and .passwordsNew == 2' "$FIRST"
check "first move: passkeys" '.passkeys == 2' "$FIRST"
check "first move: cookies set == read, all in the store" '.cookies == 3 and .cookieSites == 2 and .cookiesInStore >= 3' "$FIRST"
check "first move: every line is a ✓" '[.summary[] | startswith("✓")] | all and length == 6' "$FIRST"
SECRETS=$(B flow secrets)
check "stand-in is the sink" '.sink == "probe"' "$SECRETS"
A=$(digest alpha-secret-1); BB=$(digest beta-secret-2)
check "passwords decrypted right" "[.passwords[] | .digest] | sort == ([\"$A\", \"$BB\"] | sort)" "$SECRETS"
check "never-save site kept apart" '.never == ["never.invalid"]' "$SECRETS"
check "passkeys: two, 32-byte keys, hidden one left out" '(.passkeys | length) == 2 and all(.passkeys[]; .keyBytes == 32) and ([.passkeys[].rpId] | index("hidden.invalid") | not)' "$SECRETS"
printf '%s\n' "$FIRST" | jq -r '.summary[]' | sed 's/^/     /'
ok "first move: 2 passwords, 2 passkeys, 3 cookies (2 sites) arrived in the stand-in and the world's store"

SECOND=$(B flow move --source Chrome --only tabs,bookmarks,history,passwords,cookies,passkeys 2>/dev/null)
check "second move adds no tab or space" '.tabs == 0 and .tabsSkipped == 1 and .spacesMade == 0' "$SECOND"
check "second move adds no bookmark or place" '.bookmarksNew == 0 and .placesNew == 0' "$SECOND"
check "second move adds no password or passkey" '.passwordsNew == 0 and .passkeys == 0' "$SECOND"
check "second move: no line is a ✓" '[.summary[] | startswith("—")] | all' "$SECOND"
[ "$(B flow spaces | jq '.spaces | length')" = $((SPACES0 + 1)) ] || fail "second move changed the number of spaces"
[ "$(B flow secrets | jq '(.passwords | length) + (.passkeys | length)')" = 4 ] || fail "second move added to the stand-in"
printf '%s\n' "$SECOND" | jq -r '.summary[]' | sed 's/^/     /'
ok "second move: nothing new, and the summary says so"

# The first profile's spaces wear the shared jar, where the sign-ins land;
# another profile's spaces wear a jar of their own, and its sign-ins go there
# too — or its tabs would open signed out.
check "first profile's space wears the shared jar" '[.spaces[] | select(.name == "Chrome") | .profile] == ["shared"]' "$(B flow spaces)"
cp -R "$TEMP/fixture/Chrome/Default" "$TEMP/fixture/Chrome/Profile 1"
printf '{"profile":{"name":"Work"}}\n' > "$TEMP/fixture/Chrome/Profile 1/Preferences"
B flow root --source Chrome --path "$TEMP/fixture/Chrome" >/dev/null
FOURTH=$(B flow move --source Chrome --only tabs,cookies 2>/dev/null)
check "second profile: its space is made" '.spacesMade == 1' "$FOURTH"
check "second profile: its space wears its own jar" '[.spaces[] | select(.name == "Chrome · Work") | .profile] == ["Profile 1"]' "$(B flow spaces)"
check "second profile: its sign-ins are in its jar" '.profileCookies["Profile 1"] == 3 and (.profileCookies | has("Default") | not)' "$FOURTH"
rm -rf "$TEMP/fixture/Chrome/Profile 1"
B flow root --source Chrome --path "$TEMP/fixture/Chrome" >/dev/null
ok "the first profile's space wears the shared jar; another profile's space and its sign-ins share a jar of its own"

# A broken cookie jar costs only the signed-in state.
B flow secrets --clear >/dev/null
printf 'not a database' > "$TEMP/fixture/Chrome/Default/Cookies"
THIRD=$(B flow move --source Chrome --only passwords,cookies 2>/dev/null)
check "broken jar: passwords still arrive" '.passwords == 2' "$THIRD"
check "broken jar: the cookie line says why" '[.summary[] | select(. == "— Sign-ins: couldn'"'"'t read Chrome'"'"'s cookies")] | length == 1' "$THIRD"
ok "broken cookie jar: passwords still came, the sign-ins line says they couldn't be read"

B windows quit >/dev/null || :
for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$PID" 2>/dev/null && fail "probe did not quit"
PID=""
echo "ok: flow secrets fixture end to end"
