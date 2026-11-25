#!/usr/bin/env python3
"""Refresh Copper's bundled block lists (Settings › Privacy › Blocking).

Fetches every list in lists.json, converts each to WebKit content-rule JSON
with AdGuard's SafariConverterLib (ConverterTool, built on this Mac from the
commit pinned in lists.json; GPL-3.0, so it stays a build tool and never
ships in Copper), and writes Sources/Search/Resources/shield/: one
<id>.json.xz (xz, read back with NSData's .lzma) per shard, and
index.json, which the app reads at launch (Fork/ShieldLists.swift). Run it on a
Mac before a release, then commit what changed:

    tools/shield/refresh.py              # everything
    tools/shield/refresh.py ads cookies  # some lists (the rest stay as they are)
    tools/shield/refresh.py --check      # the self-check, no network

What it does to the lists, beyond fetching them:
- `!#include` files are fetched beside their list, and `!#if` blocks are
  evaluated as uBlock Origin Lite on Safari would (ENV below).
- Exceptions are global in uBlock, but a WebKit list's `ignore-previous-rules`
  only reaches its own list. So the ads, trackers and cookies lists also get
  uBlock's unbreak list and every `@@` exception from every list (a regional
  list's fixes for its sites included). Regional lists keep only their own.
- A list over WebKit's 150,000-rule limit is split in halves (each with all
  the exceptions) until every shard fits: `ads.json.xz`, `ads.2.json.xz`, ...
"""
import hashlib, json, lzma, os, platform, re, subprocess, sys, tempfile, time, urllib.request
from urllib.parse import urljoin

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "Sources", "Search", "Resources", "shield")
CACHE = os.path.expanduser("~/.cache/copper-shield")
LIMIT = 150_000  # WebKit's ContentExtensionParser refuses more rules than this in one list

# uBlock's preprocessor tokens, as uBO Lite on Safari sets them.
ENV = {"env_safari", "env_mv3", "ext_ubol", "cap_user_stylesheet"}


def fetch(url, tries=3):
    for attempt in range(tries):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "Copper-shield-refresh/1"})
            with urllib.request.urlopen(request, timeout=60) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as error:
            if attempt == tries - 1:
                raise RuntimeError(f"{url}: {error}")
            time.sleep(2 * (attempt + 1))


def truth(expr):
    """An `!#if` condition: tokens, !, &&, ||, parentheses. Unknown tokens are false."""
    py = expr.replace("&&", " and ").replace("||", " or ")
    py = re.sub(r"!(?!=)", " not ", py)
    py = re.sub(r"[A-Za-z_][A-Za-z0-9_]*", lambda m: m.group(0) if m.group(0) in ("and", "or", "not") else str(m.group(0) in ENV), py)
    try:
        return bool(eval(py, {"__builtins__": {}}))
    except Exception:
        return False


def expand(text, base, seen=None):
    """A list's lines with its `!#if` blocks decided and its `!#include`s pulled in."""
    seen = seen if seen is not None else set()
    out, stack = [], []  # stack: (taking, any_branch_taken)
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("!#if "):
            parent = all(t for t, _ in stack)
            ok = parent and truth(s[5:])
            stack.append((ok, ok))
        elif s == "!#else" and stack:
            taking, taken = stack.pop()
            parent = all(t for t, _ in stack)
            stack.append((parent and not taken, True))
        elif s == "!#endif" and stack:
            stack.pop()
        elif not all(t for t, _ in stack):
            continue
        elif s.startswith("!#include "):
            url = urljoin(base, s[len("!#include "):].strip())
            if url not in seen:
                seen.add(url)
                out += expand(fetch(url), url, seen)
        elif s and not s.startswith("!") and not (s.startswith("[") and not s.startswith("[$")):
            out.append(s)
    return out


def exception(line):
    return line.startswith("@@") or "#@" in line


def converter(spec):
    """ConverterTool built from the pinned commit (the release binary lacks its public-suffix bundle)."""
    src = os.path.join(CACHE, f"SafariConverterLib-{spec['commit'][:12]}")
    tool = os.path.join(src, ".build", "release", "ConverterTool")
    if os.path.exists(tool):
        return tool
    if platform.system() != "Darwin":
        sys.exit("ConverterTool builds with the Mac's Swift: run this on a Mac")
    if not os.path.isdir(src):
        subprocess.run(["git", "clone", "--quiet", spec["repo"], src], check=True)
    subprocess.run(["git", "-C", src, "checkout", "--quiet", spec["commit"]], check=True)
    subprocess.run(["swift", "build", "-c", "release", "--product", "ConverterTool"], cwd=src, check=True)
    return tool


def convert(tool, safari, lines):
    """[(json, rules)], split until WebKit takes every shard."""
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(lines) + "\n")
    run = subprocess.run([tool, "convert", "--safari-version", str(safari), "--input-path", f.name],
                         capture_output=True, text=True)
    if run.returncode != 0:
        os.replace(f.name, os.path.join(CACHE, "failed.txt"))
        sys.exit(f"ConverterTool failed ({run.returncode}) on {len(lines)} rules, kept in {CACHE}/failed.txt:\n{run.stderr[-2000:]}")
    os.unlink(f.name)
    result = json.loads(run.stdout)
    if result["discardedSafariRules"] == 0:
        return [(result["safariRulesJSON"], result["safariRulesCount"])], result
    plain = [l for l in lines if not exception(l)]
    keep = [l for l in lines if exception(l)]
    half = len(plain) // 2
    a, _ = convert(tool, safari, plain[:half] + keep)
    b, _ = convert(tool, safari, plain[half:] + keep)
    return a + b, result


def main(argv):
    if "--check" in argv:
        return check()
    spec = json.load(open(os.path.join(HERE, "lists.json")))
    wanted = [a for a in argv if not a.startswith("-")]
    tool = converter(spec["converter"])
    os.makedirs(OUT, exist_ok=True)
    index_path = os.path.join(OUT, "index.json")
    old = {l["id"]: l for l in json.load(open(index_path))["lists"]} if os.path.exists(index_path) else {}

    print("fetching…", file=sys.stderr)
    unbreak = expand(fetch(spec["unbreak"]), spec["unbreak"])
    sources = {}
    for entry in spec["lists"]:
        try:
            sources[entry["id"]] = [(url, expand(fetch(url), url)) for url in entry["urls"]]
        except RuntimeError as error:
            if entry["group"] != "regional":
                raise
            print(f"skip {entry['id']}: {error} (keeps its last build)", file=sys.stderr)
    every_allow = [l for parts in sources.values() for _, lines in parts for l in lines if l.startswith("@@")]

    lists = []
    for entry in spec["lists"]:
        lid = entry["id"]
        if lid not in sources or (wanted and lid not in wanted):
            if lid in old:
                lists.append(old[lid])
            continue
        own = [l for _, lines in sources[lid] for l in lines]
        shared = [] if entry["group"] == "regional" else unbreak + every_allow
        rules = list(dict.fromkeys(own + shared))  # dedupe, order kept
        started = time.time()
        shards, result = convert(tool, spec["safari"], rules)
        files = []
        for n, (text, count) in enumerate(shards):
            name = f"{lid}.json.xz" if n == 0 else f"{lid}.{n + 1}.json.xz"
            raw = text.encode()
            # xz with a CRC32 check: what NSData's .lzma reads; a third smaller than DEFLATE here
            packed = lzma.compress(raw, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32, preset=9 | lzma.PRESET_EXTREME)
            with open(os.path.join(OUT, name), "wb") as f:
                f.write(packed)
            files.append({"file": name, "rules": count, "sha": hashlib.sha256(raw).hexdigest()[:16],
                          "bytes": len(raw), "packed": len(packed)})
        for stale in old.get(lid, {}).get("files", [])[len(files):]:
            path = os.path.join(OUT, stale["file"])
            if os.path.exists(path):
                os.unlink(path)
        lists.append({"id": lid, "group": entry["group"], "title": entry["title"], "lang": entry.get("lang", []),
                      "files": files, "source": len(own),
                      "errors": result["errorsCount"],  # lines WebKit can't do (scriptlets, :style, ...)
                      "fetched": time.strftime("%Y-%m-%d", time.gmtime())})
        print(f"{lid:10} {len(own):7} lines → {sum(f['rules'] for f in files):7} rules in {len(files)} shard(s), "
              f"{sum(f['packed'] for f in files) / 1e6:.2f} MB packed, {time.time() - started:.1f} s", file=sys.stderr)

    with open(index_path, "w") as f:
        json.dump({"converter": spec["converter"]["version"], "safari": spec["safari"], "lists": lists}, f, indent=1, ensure_ascii=False)
        f.write("\n")
    total = sum(f["packed"] for l in lists for f in l["files"])
    print(f"{len(lists)} lists, {sum(f['rules'] for l in lists for f in l['files'])} rules, {total / 1e6:.1f} MB packed", file=sys.stderr)


def check():
    global fetch
    assert truth("env_safari") and not truth("env_firefox") and truth("!env_mobile")
    assert truth("env_safari && !cap_html_filtering") and not truth("env_chromium || env_firefox")
    assert truth("(env_mv3 || env_firefox) && !env_mobile")
    files = {"https://x.test/a.txt": "!#if env_firefox\nff\n!#else\nnot-ff\n!#endif\n!#include b.txt\n! c\n[Adblock]\n||ad.test^",
             "https://x.test/b.txt": "!#if env_safari\n!#if env_mobile\nmob\n!#endif\nsafari\n!#endif\n@@||ok.test^"}
    real, fetch = fetch, lambda url, tries=3: files[url]
    try:
        assert expand(files["https://x.test/a.txt"], "https://x.test/a.txt") == ["not-ff", "safari", "@@||ok.test^", "||ad.test^"]
    finally:
        fetch = real
    assert exception("@@||ok.test^") and exception("example.com#@#.ad") and not exception("##.ad")
    print("refresh.py self-check: ok")


if __name__ == "__main__":
    main(sys.argv[1:])
