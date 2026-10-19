#!/usr/bin/env python3
"""Pack an unpacked addon folder into the served bundle format, for tests.

    pack.py FOLDER OUT.json            one served bundle; prints its sha256
    pack.py FOLDER OUTDIR --fake       OUTDIR/<sha256>.json plus OUTDIR/resolved.json,
                                       what `./bench agent addons fake` reads in place
                                       of a cloud (docs/addons.md, Testing)

The served format is copper-addons CONTRACT §3: one compact JSON document,
{"format":"copper-addon-bundle/1","manifest":{…},"files":[{path,size,sha256,data}]},
files sorted by path; the bundle's identity is the SHA-256 of those exact bytes.
Copper Cloud builds the real ones at upload; this is the same shape, for a
test that has no cloud. Standard library only.
"""
import base64
import hashlib
import json
import os
import sys

SKIP = {".DS_Store"}


def pack(folder):
    manifest = json.load(open(os.path.join(folder, "manifest.json"), encoding="utf-8"))
    files = []
    for root, dirs, names in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if d != "__MACOSX" and not d.startswith("."))
        for name in sorted(names):
            if name in SKIP or name.startswith("."):
                continue
            full = os.path.join(root, name)
            if os.path.islink(full):
                continue
            data = open(full, "rb").read()
            path = os.path.relpath(full, folder).replace(os.sep, "/")
            files.append({"path": path, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                          "data": base64.b64encode(data).decode("ascii")})
    files.sort(key=lambda f: f["path"])
    doc = {"format": "copper-addon-bundle/1", "manifest": manifest, "files": files}
    raw = json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return manifest, raw, hashlib.sha256(raw).hexdigest()


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__.strip())
    folder, out = argv[1], argv[2]
    manifest, raw, sha = pack(folder)
    if "--fake" in argv:
        os.makedirs(out, exist_ok=True)
        open(os.path.join(out, sha + ".json"), "wb").write(raw)
        settings = {k: v.get("default") for k, v in manifest.get("settings", {}).items() if "default" in v}
        resolved = {
            "revision": "r_" + sha[:16],
            "addons": [{
                "id": manifest["id"], "slot": manifest["slot"], "name": manifest["name"],
                "version": manifest["version"], "sha256": sha, "size": len(raw), "entry": manifest["entry"],
                "bridge": manifest.get("bridge", 1), "permissions": manifest.get("permissions", {}),
                "settings": settings, "bundle": "/v1/addons/%s/bundle/%s" % (manifest["id"], sha),
            }],
        }
        if "platforms" in manifest:
            resolved["addons"][0]["platforms"] = manifest["platforms"]
        json.dump(resolved, open(os.path.join(out, "resolved.json"), "w", encoding="utf-8"), indent=1)
        print(json.dumps({"sha256": sha, "bundle": os.path.join(out, sha + ".json"),
                          "resolved": os.path.join(out, "resolved.json")}))
    else:
        open(out, "wb").write(raw)
        print(json.dumps({"sha256": sha, "size": len(raw), "bundle": out}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
