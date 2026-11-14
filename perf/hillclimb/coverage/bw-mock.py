#!/usr/bin/python3
"""A fake Bitwarden CLI (`bw`) for the coverage probe world: a JSON file vault in
$BITWARDENCLI_APPDATA_DIR/mock-vault.json, never a real account or server.
Copper finds it through SEARCH_BW_PATH. Only the commands Copper runs
(Credentials/Bitwarden*.swift) are answered; anything else exits 1.

Seeded with an Agents folder holding one card (fake test number), and one login
outside it
(for the "not shared" refusal). The fake master password is HC_BW_MASTER
(default 'hc-fake-master'); anything else is "Invalid master password."
"""
import base64, json, os, sys, uuid

state_path = os.path.join(os.environ.get("BITWARDENCLI_APPDATA_DIR", "/tmp"), "mock-vault.json")
MASTER = os.environ.get("HC_BW_MASTER", "hc-fake-master")


def load():
    try:
        with open(state_path) as f:
            return json.load(f)
    except Exception:
        return {"status": "unauthenticated", "email": None, "server": None,
                "folders": [{"id": "folder-agents", "name": "Agents"}], "items": [
            {"id": "card-0001", "type": 3, "name": "HC Test Visa", "folderId": "folder-agents", "notes": None, "fields": [],
             "card": {"cardholderName": "Hill Climb", "brand": "Visa", "number": "4242424242424242",
                      "expMonth": "12", "expYear": "2030", "code": "123"}},
            {"id": "login-hidden", "type": 1, "name": "hidden.example", "folderId": None, "notes": None, "fields": [],
             "login": {"username": "hidden@example.invalid", "password": "not-shared-pw-1",
                       "totp": None, "uris": [{"uri": "http://127.0.0.1/c1/hidden", "match": None}]}},
        ]}


def save(s):
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    with open(state_path, "w") as f:
        json.dump(s, f)


def out(obj):
    sys.stdout.write(obj if isinstance(obj, str) else json.dumps(obj))
    sys.exit(0)


def err(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


def need_unlocked(s):
    if s["status"] != "unlocked" or not os.environ.get("BW_SESSION"):
        err("You are not logged in." if s["status"] == "unauthenticated" else "Vault is locked.")


def totp_code(seed):
    import hashlib, hmac, struct, time, urllib.parse
    if seed.startswith("otpauth://"):
        seed = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(seed).query)).get("secret", "")
    key = base64.b32decode(seed.upper() + "=" * (-len(seed) % 8))
    mac = hmac.new(key, struct.pack(">Q", int(time.time() // 30)), hashlib.sha1).digest()
    o = mac[-1] & 15
    return "%06d" % ((struct.unpack(">I", mac[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


def main(a):
    s = load()
    if not a:
        err("usage")
    if a[0] == "--version":
        out("2026.10.0-hc-mock\n")
    if a[0] == "status":
        out({"serverUrl": s["server"], "lastSync": None, "userEmail": s["email"], "status": s["status"]})
    if a[:2] == ["config", "server"]:
        s["server"] = a[2] if len(a) > 2 else None
        save(s)
        out("Saved setting `config`.\n")
    if a[0] == "login" and "--apikey" in a:
        if not os.environ.get("BW_CLIENTID") or not os.environ.get("BW_CLIENTSECRET"):
            err("client_id or client_secret is missing")
        s["status"], s["email"] = "locked", "hc-fake@example.invalid"
        save(s)
        out("You are logged in!\n")
    if a[0] == "unlock":
        if s["status"] == "unauthenticated":
            err("You are not logged in.")
        if os.environ.get("BW_PASSWORD") != MASTER:
            err("Invalid master password.")
        s["status"] = "unlocked"
        save(s)
        out("hcFakeSessionKey==")
    if a[0] == "lock":
        if s["status"] == "unlocked":
            s["status"] = "locked"
        save(s)
        out("Your vault is locked.\n")
    if a[0] == "logout":
        s["status"], s["email"] = "unauthenticated", None
        save(s)
        out("You have logged out.\n")
    if a[0] == "sync":
        need_unlocked(s)
        out("Syncing complete.\n")
    if a[0] == "generate":
        out(base64.b32encode(os.urandom(15)).decode()[:20])
    need_unlocked(s)
    if a[:2] == ["list", "items"]:
        out(s["items"])
    if a[:2] == ["list", "folders"]:
        out([{"id": None, "name": "No Folder"}] + s["folders"])
    if a[:3] == ["get", "template", "item"]:
        out({"organizationId": None, "collectionIds": None, "folderId": None, "type": 1, "name": "Item name",
             "notes": "Some notes about this item.", "favorite": False, "fields": [], "login": None,
             "secureNote": None, "card": None, "identity": None, "reprompt": 0})
    if a[0] == "get" and len(a) == 3:
        item = next((i for i in s["items"] if i["id"] == a[2]), None)
        if not item:
            err("Not found.")
        if a[1] == "item":
            out(item)
        if a[1] == "password":
            out((item.get("login") or {}).get("password") or "")
        if a[1] == "totp":
            seed = (item.get("login") or {}).get("totp")
            out(totp_code(seed) if seed else err("No TOTP available for this login."))
    if a[0] in ("create", "edit") and len(a) >= 2:
        obj = json.loads(base64.b64decode(sys.stdin.read().strip()))
        coll = s["folders"] if a[1] == "folder" else s["items"]
        if a[0] == "create":
            obj["id"] = str(uuid.uuid4())
            coll.append(obj)
        else:
            idx = next((n for n, i in enumerate(coll) if i["id"] == a[2]), None)
            if idx is None:
                err("Not found.")
            obj["id"] = a[2]
            coll[idx] = obj
        save(s)
        out(obj)
    err("hc bw mock: unsupported command: " + " ".join(a[:2]))


main(sys.argv[1:])
