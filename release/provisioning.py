#!/usr/bin/env python3
"""Copper's Developer ID provisioning profile, and the entitlements a release
claims with it (docs/releasing.md › The provisioning profile).

    release/provisioning.py fetch --key AuthKey.p8 --key-id ID --issuer UUID \\
        --bundle-id com.collinrijock.copper --team 62D5L6T44Y [--cert-sha1 HEX] --out P.provisionprofile
    release/provisioning.py check --profile P --bundle-id ID --team TEAM [--cert-sha1 HEX]
    release/provisioning.py entitlements --base Copper.entitlements --profile P \\
        --bundle-id ID --team TEAM [--cert-sha1 HEX] --out E.plist
    release/provisioning.py show --profile P        what it allows
    release/provisioning.py uuid --profile P

`fetch` asks App Store Connect for the newest active Developer ID profile of the
App ID (at release time, so a capability Apple grants later is in the next
release without anyone downloading a file) and writes the first that passes
`check`. Python's standard library and /usr/bin/openssl only: the API key signs
its token with openssl, so this runs as it is on a Mac or a CI runner.

Copper.entitlements holds what the hardened runtime would otherwise refuse
(camera, microphone, ...). The restricted entitlements, which macOS only lets
an app claim when an Apple-signed profile for its App ID allows them, come from
the profile, never from a file in the repository: a capability is claimed by
the first release whose profile has it, and never by one whose profile doesn't
(AMFI would kill the app at launch).

    com.apple.application-identifier      the profile's: <team>.<bundle id>
    com.apple.developer.team-identifier   the team
    keychain-access-groups                [<team>.<bundle id>], when the profile's groups cover it
                                          (Fork/Credentials/CopperKeychain.swift)
    com.apple.developer.web-browser.public-key-credential
                                          true, when the profile has it (Prefs.entitledToPasskeys)

Anything else the profile allows is listed and not claimed. The plist inside the
profile's CMS envelope is read without verifying Apple's signature on it: the
profile comes from Apple's API over TLS or from the signing folder, and macOS
verifies it again at every launch.
"""
import argparse
import base64
import datetime
import fnmatch
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

PASSKEYS = "com.apple.developer.web-browser.public-key-credential"
APP_ID = "com.apple.application-identifier"
TEAM_ID = "com.apple.developer.team-identifier"
GROUPS = "keychain-access-groups"
DERIVED = (APP_ID, TEAM_ID, GROUPS, PASSKEYS)
API = "https://api.appstoreconnect.apple.com"


def fail(message):
    print(f"provisioning.py: {message}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# reading and checking a profile


def parse(data):
    """The property list inside a profile's CMS envelope."""
    start, end = data.find(b"<?xml"), data.find(b"</plist>")
    if start < 0 or end < 0:
        raise ValueError("no property list inside; not a provisioning profile")
    return plistlib.loads(data[start:end + len(b"</plist>")])


def read(path):
    try:
        return parse(open(path, "rb").read())
    except (OSError, ValueError) as error:
        fail(f"{path}: {error}")


def problems(profile, bundle_id, team, cert_sha1=None, now=None):
    """Why this profile can't sign this app, or []."""
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    found = []
    teams = profile.get("TeamIdentifier") or []
    if team not in teams:
        found.append(f"it is team {teams}, not {team}")
    granted = profile.get("Entitlements") or {}
    if granted.get(APP_ID) != f"{team}.{bundle_id}":
        found.append(f"it is for {granted.get(APP_ID)}, not {team}.{bundle_id}")
    if "OSX" not in (profile.get("Platform") or []):
        found.append(f"it is for {profile.get('Platform')}, not macOS")
    if not profile.get("ProvisionsAllDevices"):
        found.append("it is not a Developer ID profile (it names devices)")
    expires = profile.get("ExpirationDate")
    if expires is None or expires <= now:
        found.append(f"it expired ({expires})")
    if cert_sha1:
        listed = [hashlib.sha1(der).hexdigest() for der in profile.get("DeveloperCertificates") or []]
        if cert_sha1.lower() not in listed:
            found.append(f"it does not list the signing certificate {cert_sha1.lower()} (it lists {listed})")
    return found


def describe(profile):
    return (f"{profile.get('Name')} ({profile.get('UUID')}), created {profile.get('CreationDate')}, "
            f"expires {profile.get('ExpirationDate')}")


def entitlements(base, profile, bundle_id, team):
    """Copper.entitlements plus what the profile allows of DERIVED; and what else it allows."""
    granted = profile.get("Entitlements") or {}
    clash = sorted(k for k in DERIVED if k in base)
    if clash:
        raise ValueError(f"Copper.entitlements claims {clash}; those come from the profile only")
    out = dict(base)
    out[APP_ID] = granted[APP_ID]
    out[TEAM_ID] = team
    group = f"{team}.{bundle_id}"
    if any(fnmatch.fnmatchcase(group, pattern) for pattern in granted.get(GROUPS) or []):
        out[GROUPS] = [group]
    if granted.get(PASSKEYS) is True:
        out[PASSKEYS] = True
    return out, sorted(k for k in granted if k not in DERIVED)


# ---------------------------------------------------------------------------
# App Store Connect


def der_to_raw(signature):
    """An ECDSA signature as openssl writes it (DER) as JWS wants it: r || s, 32 bytes each."""
    def length(at):
        first = signature[at]
        if first < 0x80:
            return first, at + 1
        count = first & 0x7F
        return int.from_bytes(signature[at + 1:at + 1 + count], "big"), at + 1 + count

    if signature[0] != 0x30:
        raise ValueError("not a DER sequence")
    _, at = length(1)
    numbers = []
    for _ in range(2):
        if signature[at] != 0x02:
            raise ValueError("not a DER integer")
        size, at = length(at + 1)
        numbers.append(int.from_bytes(signature[at:at + size], "big"))
        at += size
    return b"".join(n.to_bytes(32, "big") for n in numbers)


def token(key, key_id, issuer):
    b64 = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b"=")
    now = int(time.time())
    head = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
    signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=head + b"." + body,
                            capture_output=True, check=False)
    if signed.returncode != 0:
        raise RuntimeError("openssl could not sign the App Store Connect token with the API key")
    return (head + b"." + body + b"." + b64(der_to_raw(signed.stdout))).decode()


def get(path, bearer):
    request = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + bearer})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"App Store Connect answered {error.code} for {path.split('?')[0]}") from None


def fetch(args):
    bearer = token(args.key, args.key_id, args.issuer)
    query = urllib.parse.urlencode({"filter[identifier]": args.bundle_id, "fields[bundleIds]": "identifier"})
    ids = [b["id"] for b in get(f"/v1/bundleIds?{query}", bearer)["data"]
           if b["attributes"]["identifier"] == args.bundle_id]
    if len(ids) != 1:
        raise RuntimeError(f"want one App ID {args.bundle_id}, App Store Connect has {len(ids)}")
    query = urllib.parse.urlencode({
        "filter[profileType]": "MAC_APP_DIRECT", "filter[profileState]": "ACTIVE",
        "fields[profiles]": "name,uuid,createdDate,bundleId", "include": "bundleId",
        "fields[bundleIds]": "identifier", "limit": "200",
    })
    listed = [p for p in get(f"/v1/profiles?{query}", bearer)["data"]
              if ((p.get("relationships") or {}).get("bundleId") or {}).get("data", {}).get("id") == ids[0]]
    if not listed:
        raise RuntimeError(f"App Store Connect has no active Developer ID profile for {args.bundle_id}")
    listed.sort(key=lambda p: p["attributes"].get("createdDate") or "", reverse=True)
    for summary in listed:
        detail = get(f"/v1/profiles/{summary['id']}?fields[profiles]=profileContent", bearer)
        data = base64.b64decode(detail["data"]["attributes"]["profileContent"])
        profile = parse(data)
        wrong = problems(profile, args.bundle_id, args.team, args.cert_sha1)
        if wrong:
            print(f"profile  skipped {summary['id']} {describe(profile)}: {'; '.join(wrong)}", file=sys.stderr)
            continue
        with tempfile.NamedTemporaryFile(dir=os.path.dirname(os.path.abspath(args.out)), delete=False) as f:
            f.write(data)
        os.replace(f.name, args.out)
        print(f"profile  {summary['id']} {describe(profile)} (App Store Connect)", file=sys.stderr)
        return
    raise RuntimeError(f"none of the {len(listed)} active Developer ID profiles for {args.bundle_id} can sign it")


# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Copper's Developer ID provisioning profile")
    sub = parser.add_subparsers(dest="command", required=True)

    def app(p):
        p.add_argument("--bundle-id", required=True)
        p.add_argument("--team", required=True)
        p.add_argument("--cert-sha1")

    f = sub.add_parser("fetch")
    app(f)
    f.add_argument("--key", required=True)
    f.add_argument("--key-id", required=True)
    f.add_argument("--issuer", required=True)
    f.add_argument("--out", required=True)
    c = sub.add_parser("check")
    app(c)
    c.add_argument("--profile", required=True)
    e = sub.add_parser("entitlements")
    app(e)
    e.add_argument("--profile", required=True)
    e.add_argument("--base", required=True)
    e.add_argument("--out", required=True)
    s = sub.add_parser("show")
    s.add_argument("--profile", required=True)
    u = sub.add_parser("uuid")
    u.add_argument("--profile", required=True)
    args = parser.parse_args()

    if args.command == "fetch":
        try:
            fetch(args)
        except (RuntimeError, ValueError, OSError, KeyError) as error:
            fail(f"fetch: {error}")
        return
    profile = read(args.profile)
    if args.command == "uuid":
        print(profile.get("UUID"))
        return
    if args.command == "show":
        print(f"profile  {describe(profile)}, team {profile.get('TeamIdentifier')}")
        for key, value in sorted((profile.get("Entitlements") or {}).items()):
            print(f"  allows {key} = {value}")
        return
    wrong = problems(profile, args.bundle_id, args.team, args.cert_sha1)
    if wrong:
        fail(f"{args.profile} can't sign {args.bundle_id}: {'; '.join(wrong)}")
    if args.command == "check":
        print(f"profile  {describe(profile)}: ok", file=sys.stderr)
        return
    with open(args.base, "rb") as f:
        base = plistlib.load(f)
    try:
        out, unclaimed = entitlements(base, profile, args.bundle_id, args.team)
    except ValueError as error:
        fail(str(error))
    with open(args.out, "wb") as f:
        plistlib.dump(out, f, fmt=plistlib.FMT_XML, sort_keys=True)
    for key in DERIVED:
        if key in out:
            print(f"  claims {key} = {out[key]}", file=sys.stderr)
    if PASSKEYS not in out:
        print(f"  not claimed: {PASSKEYS} (the profile does not allow it)", file=sys.stderr)
    for key in unclaimed:
        print(f"  allowed, not claimed: {key}", file=sys.stderr)


if __name__ == "__main__":
    main()
