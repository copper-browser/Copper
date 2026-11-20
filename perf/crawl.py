#!/usr/bin/env python3
"""Page states for training a small decision model (mini-Jev): visit each URL
with Copper's `jev_dump` (a fresh background tab, the state Jev would get on a
run's first decision, no Jev call) and keep the ones worth learning from.

    perf/crawl.py --world "Copper (crawl)" --port 4262 --out ~/hc/dumps [--urls ~/hc/urls.txt]

Writes <out>/<hash>.json (jev_dump's file) and appends one line per URL to
<out>/index.jsonl: {hash, url, host, family, structural_hash, ok, elements,
chars, ts} (+ ms, why when not ok). URLs already in the index are skipped, so a
stopped crawl picks up where it was. Polite: robots.txt-disallowed paths and
PDFs are skipped, one request per host every 2 s, 25 s per page at most.
Pages with <5 or >250 elements are dropped (no file kept). Probe worlds only:
the everyday Copper (port 4123) is refused.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import urllib.robotparser
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wikigame import Copper  # noqa: E402  (agent.json → token, tools/call)

HOST_GAP = 2.0
PAGE_CAP = 25
MIN_ELEMENTS, MAX_ELEMENTS = 5, 250
AGENT = "Copper"
# shortcut: a few two-part suffixes instead of the Public Suffix List; use `tldextract` if families matter for the split.
TWO_PART = {"co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "co.nz", "co.in", "com.br",
            "com.mx", "co.za", "com.cn", "com.tr", "co.kr", "com.sg", "com.hk", "com.tw", "com.ar", "gov.au"}


def url_hash(url):
    return hashlib.sha1(url.encode()).hexdigest()[:16]


def family(host):
    """The registrable domain: shop.example.co.uk → example.co.uk."""
    parts = host.lower().strip(".").split(".")
    n = 3 if ".".join(parts[-2:]) in TWO_PART else 2
    return ".".join(parts[-n:])


def shape(label):
    """A label with its words and numbers folded: "Buy Pixel 9 — $799" → "w 9 — $9"."""
    s = re.sub(r"\d+([.,]\d+)*", "9", label.strip().lower())
    s = re.sub(r"[^\W\d_]+", "w", s)
    s = re.sub(r"\s+", " ", s)
    return re.sub(r"(w )+w", "w", s)[:40]


def structural_hash(elements):
    """Template siblings (two product pages of one shop) hash alike."""
    keys = sorted({f"{e.get('role', '')}|{shape(e.get('label', ''))}" for e in elements})
    return hashlib.sha1("\n".join(keys).encode()).hexdigest()[:16]


class Robots:
    def __init__(self):
        self.cache = {}

    def allowed(self, url):
        p = urllib.parse.urlsplit(url)
        base = f"{p.scheme}://{p.netloc}"
        if base not in self.cache:
            rp = urllib.robotparser.RobotFileParser()
            try:
                req = urllib.request.Request(base + "/robots.txt", headers={"User-Agent": AGENT})
                with urllib.request.urlopen(req, timeout=5) as r:
                    rp.parse(r.read().decode("utf-8", "replace").splitlines())
            except Exception as e:  # 404 or unreachable: allowed, as robotparser treats a 404
                code = getattr(e, "code", None)
                rp.parse(["User-agent: *", "Disallow: /"] if code in (401, 403) else [])
            self.cache[base] = rp
        return self.cache[base].can_fetch(AGENT, url)


def by_host(urls):
    """Round-robin over hosts, so the 2 s gap is rarely waited for."""
    groups = OrderedDict()
    for u in urls:
        groups.setdefault(urllib.parse.urlsplit(u).hostname or "", []).append(u)
    out = []
    while groups:
        for h in list(groups):
            out.append(groups[h].pop(0))
            if not groups[h]:
                del groups[h]
    return out


def read_urls(path):
    out = []
    with open(os.path.expanduser(path)) as f:
        for line in f:
            u = line.strip()
            if u and not u.startswith("#"):
                out.append(u if "://" in u else "https://" + u)
    return list(dict.fromkeys(out))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--urls", default="~/hc/urls.txt")
    ap.add_argument("--out", required=True)
    ap.add_argument("--world", required=True, help='the probe world folder, e.g. "Copper (crawl)"')
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--wait-ms", type=int, default=0)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    if a.port == 4123 or a.world.strip() == "Copper":
        sys.exit("refusing the everyday Copper (port 4123 / world Copper): use a probe world")
    out = os.path.expanduser(a.out)
    os.makedirs(out, exist_ok=True)
    index = os.path.join(out, "index.jsonl")
    done = set()
    if os.path.exists(index):
        with open(index) as f:
            done = {json.loads(line)["hash"] for line in f if line.strip()}
    urls = [u for u in by_host(read_urls(a.urls)) if url_hash(u) not in done]
    if a.limit:
        urls = urls[:a.limit]
    copper, robots, last = Copper(a.world, a.port), Robots(), {}
    kept = took = 0
    started = time.time()
    for n, url in enumerate(urls, 1):
        host = urllib.parse.urlsplit(url).hostname or ""
        h = url_hash(url)
        row = {"hash": h, "url": url, "host": host, "family": family(host), "structural_hash": None,
               "ok": False, "elements": 0, "chars": 0}
        path = os.path.join(out, h + ".json")
        t0 = time.time()
        if urllib.parse.urlsplit(url).path.lower().endswith(".pdf"):
            row["why"] = "pdf"
        elif not robots.allowed(url):
            row["why"] = "robots"
        else:
            wait = last.get(host, 0) + HOST_GAP - time.time()
            if wait > 0:
                time.sleep(wait)
            t0 = time.time()
            last[host] = t0
            try:
                reply = json.loads(copper.call("jev_dump", {"url": url, "out": path, "wait_ms": a.wait_ms}, timeout=PAGE_CAP))
                row["elements"], row["chars"] = reply["elements"], reply["chars"]
                with open(path) as f:
                    dump = json.load(f)
                row["structural_hash"] = structural_hash(dump["state"]["elements"])
                if (dump["state"]["page"]["url"] or "").lower().split("?")[0].endswith(".pdf"):
                    row["why"] = "pdf"
                elif not MIN_ELEMENTS <= row["elements"] <= MAX_ELEMENTS:
                    row["why"] = "elements"
                else:
                    row["ok"] = True
            except Exception as e:  # timeout, load failure: noted, the crawl goes on
                row["why"] = f"error: {str(e)[:160]}"
            if not row["ok"] and os.path.exists(path):
                os.remove(path)
            took += 1
        row["ms"] = int((time.time() - t0) * 1000)
        row["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        kept += row["ok"]
        with open(index, "a") as f:
            f.write(json.dumps(row) + "\n")
        print(f"{n:>5}/{len(urls)} {'ok ' if row['ok'] else 'no '} {row['elements']:>4} el {row['chars']:>6} ch "
              f"{row['ms']:>6} ms  {url[:80]}  {row.get('why', '')}", flush=True)
    wall = time.time() - started
    print(f"\n{kept}/{len(urls)} kept · {took} visited · {wall:.1f} s · {wall / max(len(urls), 1):.2f} s/site")


if __name__ == "__main__":
    main()
