#!/usr/bin/env python3
"""Build and check site/ (stdlib only). site.yml runs it before both deploys.

  python3 .github/scripts/site_build.py           # build: version slots, release notes, sitemap.xml
  python3 .github/scripts/site_build.py --check   # check: header/footer match the template, no broken links
  python3 .github/scripts/site_build.py --test    # self-test of the helpers

Build writes into site/ in place (CI only publishes the result; nothing is committed back):
- the latest release's version (releases/latest/download/copper-version.json) into index.html's
  <span data-version>X</span>, <a data-version-href href="release-notes/#X"> and "softwareVersion": "X";
- release-notes/ via .github/scripts/release_notes.py's build(site_dir), when that module exists;
- sitemap.xml: the home page and every site/<page>/index.html, on the canonical host.
"""
import pathlib
import re
import sys
import urllib.request
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[2]
SITE = ROOT / "site"
CANONICAL = "https://copper.exowatt.com/"
VERSION_URL = "https://github.com/copper-browser/Copper/releases/latest/download/copper-version.json"
V = r"\d+\.\d+\.\d{8}\.\d+"


def pages(site=SITE):
    """Every deployed page: index.html, 404.html and site/<page>/index.html (one folder down, by rule)."""
    out = [p for p in (site / "index.html", site / "404.html") if p.exists()]
    return out + sorted(site.glob("*/index.html"))


# ---------- build ----------

def latest_version():
    import json
    with urllib.request.urlopen(VERSION_URL, timeout=20) as r:
        v = json.load(r)["version"]
    if not re.fullmatch(V, v):
        raise ValueError(f"odd version {v!r}")
    return v


def set_version(html, v):
    html = re.sub(r"(<[^>]*\bdata-version\b[^>]*>)" + V + "(<)", lambda m: m.group(1) + v + m.group(2), html)
    html = re.sub(r'(\bdata-version-href\s+href="[^"#]*#)' + V + '"', lambda m: m.group(1) + v + '"', html)
    return re.sub(r'("softwareVersion": ")' + V + '"', lambda m: m.group(1) + v + '"', html)


def sitemap(site=SITE):
    urls = [CANONICAL] + [CANONICAL + p.parent.name + "/" for p in sorted(site.glob("*/index.html"))]
    body = "".join(f"  <url><loc>{u}</loc></url>\n" for u in urls)
    return f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n{body}</urlset>\n'


def build():
    try:
        v = latest_version()
    except Exception as e:  # a failed fetch keeps the committed version rather than failing the deploy
        print(f"::warning::version fetch failed ({e}); keeping the committed version")
        v = None
    if v:
        index = SITE / "index.html"
        index.write_text(set_version(index.read_text(), v))
        print(f"version {v}")
    sys.path.insert(0, str(pathlib.Path(__file__).parent))
    try:
        import release_notes
    except ImportError:
        release_notes = None
    if release_notes:
        release_notes.build(SITE)
        print("release notes built")
    (SITE / "sitemap.xml").write_text(sitemap())
    print(f"sitemap.xml: {1 + len(list(SITE.glob('*/index.html')))} pages")


# ---------- check ----------

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "a" and a.get("name"):
            self.ids.add(a["name"])
        for k in ("href", "src", "poster", "data-src", "data-poster", "data-light", "data-dark"):
            if a.get(k):
                self.urls.append(a[k])
        for k in ("srcset", "imagesrcset"):
            if a.get(k):
                self.urls += [c.strip().split(" ")[0] for c in a[k].split(",") if c.strip()]


def parse(path):
    p = Links()
    p.feed(path.read_text())
    return p


def local_target(page, url, site=SITE):
    """The file a relative URL on `page` points at (None for external URLs), and its #fragment."""
    s = urlsplit(url)
    if s.scheme or url.startswith(("//", "#", "{{")):
        return None, None
    # 404.html is served at any depth and its <base> is the canonical root, so its URLs are root-relative.
    base = "/" if page.name == "404.html" else "/" + page.relative_to(site).as_posix()
    target = urlsplit(urljoin(base, s.path)).path
    if target.endswith("/"):
        target += "index.html"
    return site / target.lstrip("/"), s.fragment


def broken_links(site=SITE, warns=None):
    errs, cache = [], {}
    warns = [] if warns is None else warns
    for page in pages(site):
        # any assets/… path, also inside scripts, styles and data-* (what site.yml checked before)
        for a in sorted(set(re.findall(r"assets/[A-Za-z0-9._/-]+", page.read_text()))):
            if not (site / a).is_file():
                errs.append(f"{page.relative_to(site)}: missing {a}")
        for url in parse(page).urls:
            f, frag = local_target(page, url, site)
            if f is None:
                continue
            if not f.is_file():
                msg = f"{page.relative_to(site)}: {url} -> missing {f.relative_to(site)}"
                # shortcut: a page another PR adds (benchmarks/, arc/…) only warns; make it an error once all have landed
                (warns if f.name == "index.html" and f.parent != site else errs).append(msg)
            elif frag and f.suffix == ".html":
                ids = cache.setdefault(f, parse(f).ids)
                if frag not in ids:
                    errs.append(f"{page.relative_to(site)}: {url} -> no id {frag!r} in {f.relative_to(site)}")
    return errs


def chrome(html, depth):
    """A page's <header class="nav"> and <footer>, normalised: aria-current dropped, paths made root-relative."""
    out, html = [], re.sub(r"<!--.*?-->", "", html, flags=re.S)
    for pat in (r'<header class="nav">.*?</header>', r"<footer>.*?</footer>"):
        m = re.search(pat, html, re.S)
        block = m.group(0) if m else ""
        block = block.replace(' aria-current="page"', "")
        if depth:
            block = block.replace('"../', '"./')
        out.append(block)
    return out


def drifted(site=SITE):
    want = chrome((site / "_page-template.html").read_text(), 1)
    errs = []
    for page in pages(site):
        if page.name == "index.html" and page.parent == site:
            continue  # the home page has its own header with in-page anchors
        got = chrome(page.read_text(), page.parent != site)
        for name, w, g in zip(("header", "footer"), want, got):
            if w != g:
                errs.append(f"{page.relative_to(site)}: {name} differs from site/_page-template.html")
    return errs


def check():
    warns = []
    errs = drifted() + broken_links(warns=warns)
    for w in sorted(set(warns)):
        print(f"::warning::{w}")
    for e in errs:
        print(f"::error::{e}")
    print(f"checked {len(pages())} pages: {len(errs)} problems")
    return 1 if errs else 0


# ---------- self-test ----------

def test():
    import tempfile
    h = '<span data-version>1.0.20261001.1</span> <a data-version-href href="release-notes/#1.0.20261001.1">new</a> "softwareVersion": "1.0.20261001.1"'
    assert set_version(h, "1.0.20261124.117").count("1.0.20261124.117") == 3
    assert "1.0.20261001.1" in set_version("v1.0.20261001.1 elsewhere", "1.0.20261124.117")
    with tempfile.TemporaryDirectory() as d:
        s = pathlib.Path(d)
        (s / "assets").mkdir()
        (s / "assets/a.css").write_text("")
        (s / "arc").mkdir()
        tpl = '<header class="nav"><a href="../">C</a><a href="../arc/">Arc</a></header><main></main><footer><a href="../privacy/">P</a></footer>'
        (s / "_page-template.html").write_text(tpl)
        (s / "index.html").write_text('<header class="nav"><a href="#x">x</a></header><p id="install"></p><a href="arc/">a</a>')
        (s / "arc/index.html").write_text(tpl.replace('href="../arc/"', 'href="../arc/" aria-current="page"')
                                          + '<link href="../assets/a.css"><a href="../#install">i</a><a href="../#nope">n</a>')
        (s / "404.html").write_text(tpl.replace('"../', '"./') + '<link href="assets/a.css"><img src="./assets/gone.png"><script>x("assets/js-only.png")</script>')
        assert drifted(s) == [], drifted(s)
        warns = []
        errs = broken_links(s, warns)
        assert any("privacy/index.html" in w for w in warns) and not any("privacy" in e for e in errs)  # page not added yet
        assert any("'nope'" in e for e in errs) and any("gone.png" in e for e in errs) and any("js-only.png" in e for e in errs)
        assert not any("a.css" in e or "#install" in e for e in errs), errs
        (s / "arc/index.html").write_text(tpl.replace("Arc<", "Arc!<"))
        assert drifted(s) == ["arc/index.html: header differs from site/_page-template.html"]
        assert "<loc>https://copper.exowatt.com/arc/</loc>" in sitemap(s)
    print("site_build self-test ok")


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--check":
        sys.exit(check())
    if arg == "--test":
        sys.exit(test())
    build()
