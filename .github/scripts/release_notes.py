#!/usr/bin/env python3
"""Writes site/release-notes/index.html: CHANGELOG.md's Unreleased list on top, then every release, newest first.

Each release's words are the `notes` paragraph in its `copper-version.json` (what Settings and the updater
show). A note is carried from build to build until the next one replaces it, so builds in a row with the same
note share one entry; every version still gets its own anchor (`#1.0.20261124.117`), which the app opens
after an update. Paragraphs that name Exowatt-internal apps are left off the public page.

Only the part of the page between the release-notes markers is rewritten; the head, header and footer are
the committed file's. Stdlib only.

  python3 .github/scripts/release_notes.py            build into site/ (needs the network)
  python3 .github/scripts/release_notes.py --selftest check the parsing and the page on a fixture, offline

site_build.py calls build(site_dir) and adds the anchors it returns to sitemap.xml.
"""
import concurrent.futures
import datetime
import html
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

REPO = 'copper-browser/Copper'
BEGIN, END = '<!-- release-notes:begin -->', '<!-- release-notes:end -->'
# Exowatt's own apps and teams, named in a few notes; they mean nothing to the public (site-gap.md §2.9).
INTERNAL = re.compile(r'\b(Exowatt|RGS|Xos|FluxBots?)\b')
UNRELEASED_SHOWN = 8


def _get(url, token=None):
    req = urllib.request.Request(url, headers={'User-Agent': 'copper-site-build', 'Accept': 'application/vnd.github+json'})
    if token and url.startswith('https://api.github.com/'):
        req.add_header('Authorization', 'Bearer ' + token)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def fetch_releases():
    """[{version, tag, date, notes, url}] newest first, from the GitHub API and each release's manifest."""
    token = os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN')
    found, page = [], 1
    while True:
        batch = json.loads(_get(f'https://api.github.com/repos/{REPO}/releases?per_page=100&page={page}', token))
        found += batch
        if len(batch) < 100:
            break
        page += 1
    wanted = []
    for r in found:
        if r.get('draft') or r.get('prerelease'):
            continue
        asset = next((a for a in r.get('assets', []) if a.get('name') == 'copper-version.json'), None)
        if asset:
            wanted.append((r, asset['browser_download_url']))

    def one(item):
        r, url = item
        m = json.loads(_get(url))
        return {'version': m.get('version') or r['tag_name'].lstrip('v'), 'tag': r['tag_name'],
                'date': r.get('published_at') or m.get('publishedAt') or '', 'notes': m.get('notes') or '',
                'url': r.get('html_url') or f'https://github.com/{REPO}/releases/tag/{r["tag_name"]}'}

    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        out = list(pool.map(one, wanted))
    out.sort(key=lambda x: _vkey(x['version']), reverse=True)
    return out


def _vkey(v):
    return tuple(int(p) if p.isdigit() else 0 for p in v.split('.'))


def public(text):
    """A note's paragraphs, without the ones that name Exowatt-internal apps."""
    return [p.strip() for p in re.split(r'\n\s*\n', text or '') if p.strip() and not INTERNAL.search(p)]


def inline(md):
    """The little Markdown the notes and the changelog use: `code`, **bold**, *em*, [text](link). Escapes first."""
    codes = []

    def keep(m):
        codes.append('<code>' + html.escape(m.group(1)) + '</code>')
        return f'\x00{len(codes) - 1}\x00'
    s = html.escape(re.sub(r'`([^`]+)`', keep, md), quote=False)
    s = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', s)
    s = re.sub(r'(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])', r'<em>\1</em>', s)

    def link(m):
        text, href = m.group(1), html.unescape(m.group(2))
        if re.match(r'https?://', href):
            pass
        elif re.match(r'^[\w./-]+(#[\w-]*)?$', href) and not href.startswith('/'):
            href = f'https://github.com/{REPO}/blob/fork/{href}'  # a repo-relative doc link
        else:
            return text
        return f'<a href="{html.escape(href)}">{text}</a>'
    s = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', link, s)
    return re.sub(r'\x00(\d+)\x00', lambda m: codes[int(m.group(1))], s)


def unreleased(changelog):
    """CHANGELOG.md's Unreleased section as [(heading or None, [bullet markdown])], internal bullets left out."""
    m = re.search(r'^## Unreleased\s*$(.*?)(?=^## |\Z)', changelog, re.M | re.S)
    if not m:
        return []
    groups, heading, bullets, cur = [], None, [], None
    for line in m.group(1).splitlines():
        if line.startswith('### '):
            if cur is not None:
                bullets.append(cur)
                cur = None
            if bullets:
                groups.append((heading, bullets))
            heading, bullets = line[4:].strip(), []
        elif line.startswith('- '):
            if cur is not None:
                bullets.append(cur)
            cur = line[2:].strip()
        elif cur is not None and line.startswith('  ') and line.strip():
            cur += ' ' + line.strip()
        elif cur is not None and not line.strip():
            bullets.append(cur)
            cur = None
    if cur is not None:
        bullets.append(cur)
    if bullets:
        groups.append((heading, bullets))
    return [(h, [b for b in bs if not INTERNAL.search(b)]) for h, bs in groups]


def grouped(releases):
    """Builds in a row (newest first) that carry the same public note, as lists."""
    out = []
    for r in releases:
        key = tuple(public(r['notes']))
        if out and tuple(public(out[-1][0]['notes'])) == key:
            out[-1].append(r)
        else:
            out.append([r])
    return out


def headline(md):
    """A changelog line's bold lead (**…**), or the whole line when it has none."""
    m = re.match(r'\*\*(.+?)\*\*', md)
    return f'**{m.group(1)}**' if m else md


def _runs(pairs):
    """[(heading, item)] -> [(heading, [items])], one entry per run of the same heading."""
    out = []
    for h, b in pairs:
        if out and out[-1][0] == h:
            out[-1][1].append(b)
        else:
            out.append((h, [b]))
    return out


def _date(iso):
    try:
        d = datetime.datetime.fromisoformat(iso.replace('Z', '+00:00'))
    except ValueError:
        return '', ''
    return d.date().isoformat(), f'{d.day} {d:%b %Y}'


def render(releases, unrel):
    e = html.escape
    out = [BEGIN]
    shown = [(h, bs) for h, bs in unrel if bs]
    if shown:
        flat = [(h, b) for h, bs in shown for b in bs]
        out.append('<section class="wrap section" aria-labelledby="unreleased">')
        out.append('  <div class="section-head"><h2 id="unreleased">Unreleased</h2>'
                   '<p>The running list in <a href="https://github.com/copper-browser/Copper/blob/fork/CHANGELOG.md">CHANGELOG.md</a> since 1.0, newest first. '
                   'Most of it is already in the builds below; the newest lines may not be in a build yet.</p></div>')

        def lis(items):
            return ''.join(f'<li>{inline(b)}</li>' for b in items)
        head = [b for h, b in flat[:UNRELEASED_SHOWN]]
        out.append(f'  <ul class="rn-list">{lis(head)}</ul>')
        rest = flat[UNRELEASED_SHOWN:]
        if rest:
            out.append(f'  <details class="rn-more"><summary>All {len(flat)} changes</summary>')
            out.append('    <p class="muted small">Headlines only; the full text of each is in CHANGELOG.md.</p>')
            for h, items in _runs(rest):
                if h:
                    out.append(f'    <h3>{e(h)}</h3>')
                out.append(f'    <ul class="rn-list">{lis(map(headline, items))}</ul>')
            out.append('  </details>')
        out.append('</section>')
    versions = []
    out.append('<section class="wrap section" aria-labelledby="builds">')
    out.append(f'  <div class="section-head"><h2 id="builds">Every build</h2><p>{len(releases)} releases, newest first. '
               'Copper updates itself; each build is also on <a href="https://github.com/copper-browser/Copper/releases">GitHub</a>.</p></div>')
    for i, grp in enumerate(grouped(releases)):
        top = grp[0]
        v = top['version']
        iso, day = _date(top['date'])
        paras = public(top['notes'])
        out.append(f'  <article class="rn" aria-labelledby="{e(v)}">')
        badge = ' <span class="rn-tag">Latest</span>' if i == 0 else ''
        out.append(f'    <h3 id="{e(v)}"><a href="#{e(v)}">{e(v)}</a>{badge}</h3>')
        out.append(f'    <p class="rn-meta"><time datetime="{iso}">{day}</time> · <a href="{e(top["url"])}">Release on GitHub</a></p>')
        out.extend(f'    <p>{inline(p)}</p>' for p in paras)
        if not paras:
            out.append('    <p class="rn-none">No notes for this build.</p>')
        versions.append(v)
        if len(grp) > 1:
            also = []
            for r in grp[1:]:
                _, d = _date(r['date'])
                also.append(f'<a id="{e(r["version"])}" href="#{e(r["version"])}">{e(r["version"])}</a> <span>({d})</span>')
                versions.append(r['version'])
            out.append(f'    <p class="rn-also">Same notes in {len(grp) - 1} earlier build{"s" if len(grp) > 2 else ""}: {", ".join(also)}</p>')
        out.append('  </article>')
    out.append('</section>')
    out.append(END)
    return '\n'.join(out), versions


def write(page_path, block):
    page = page_path.read_text()
    a, b = page.index(BEGIN), page.index(END) + len(END)
    page_path.write_text(page[:a] + block + page[b:])


def build(site_dir):
    """Rewrites site_dir/release-notes/index.html; returns the version anchors on it. Offline, keeps the committed page."""
    site_dir = pathlib.Path(site_dir)
    page = site_dir / 'release-notes' / 'index.html'
    changelog = site_dir.parent / 'CHANGELOG.md'
    try:
        releases = fetch_releases()
    except (urllib.error.URLError, OSError, ValueError, KeyError) as err:
        print(f'release_notes: could not read the releases ({err}); keeping the committed page', file=sys.stderr)
        return re.findall(r'id="(\d+(?:\.\d+)+)"', page.read_text())
    if not releases:
        print('release_notes: no releases found; keeping the committed page', file=sys.stderr)
        return re.findall(r'id="(\d+(?:\.\d+)+)"', page.read_text())
    block, versions = render(releases, unreleased(changelog.read_text() if changelog.exists() else ''))
    write(page, block)
    print(f'release_notes: {len(versions)} versions written to {page}')
    return versions


def selftest():
    rel = [
        {'version': '1.0.20261124.117', 'tag': 'v1.0.20261124.117', 'date': '2026-11-24T18:24:59Z', 'url': 'u117',
         'notes': 'Sharing a tab can share its sound. Use `copper shot` <now>.'},
        {'version': '1.0.20261124.116', 'tag': 'v1.0.20261124.116', 'date': '2026-11-24T17:35:45Z', 'url': 'u116',
         'notes': 'Sharing a tab can share its sound. Use `copper shot` <now>.'},
        {'version': '1.0.20261030.99', 'tag': 'v1.0.20261030.99', 'date': '2026-10-30T10:00:00Z', 'url': 'u99',
         'notes': 'Exowatt apps can use speech. RGS, inside Copper, takes words.\n\nA public **bold** line.'},
        {'version': '1.0.20261026.72', 'tag': 'v1.0.20261026.72', 'date': '2026-10-26T10:00:00Z', 'url': 'u72',
         'notes': 'Xos whiteboards can now be inserted.'},
        {'version': '1.0.20261001.8', 'tag': 'v1.0.20261001.8', 'date': '2026-10-01T10:00:00Z', 'url': 'u8', 'notes': ''},
    ]
    log = ('# Changelog\n\nIntro.\n\n## Unreleased\n\n- **One.** First [docs](docs/flow.md), and [x](javascript:alert(1)).\n'
           '- **Two.** Carries on\n  across lines.\n- **RGS gets words.** internal\n\n### Added\n\n- **Three.** <b>\n\n## 1.0 — 23 September 2026\n\n- old\n')
    u = unreleased(log)
    assert u == [(None, ['**One.** First [docs](docs/flow.md), and [x](javascript:alert(1)).', '**Two.** Carries on across lines.']),
                 ('Added', ['**Three.** <b>'])], u
    assert public(rel[2]['notes']) == ['A public **bold** line.']
    assert public(rel[3]['notes']) == []
    g = grouped(rel)
    # .99 and .72 differ in their raw notes, but .72 has no public words, same as .8, so those two group
    assert [[r['version'] for r in x] for x in g] == [['1.0.20261124.117', '1.0.20261124.116'], ['1.0.20261030.99'],
                                                      ['1.0.20261026.72', '1.0.20261001.8']], g
    block, versions = render(rel, u)
    assert versions == [r['version'] for r in rel], versions
    for v in versions:
        assert f'id="{v}"' in block, v
    assert 'Exowatt' not in block and 'RGS' not in block and 'Xos' not in block
    assert '<code>copper shot</code> &lt;now&gt;' in block
    assert '<strong>bold</strong>' in block
    assert inline('**`copper shot` takes *a* size.** `<x>` [d](docs/a.md)') == ('<strong><code>copper shot</code> takes <em>a</em> size.</strong> <code>&lt;x&gt;</code> '
                                                                          '<a href="https://github.com/copper-browser/Copper/blob/fork/docs/a.md">d</a>'), inline('**`copper shot` takes *a* size.** `<x>` [d](docs/a.md)')
    assert '<b>' not in block, block
    assert headline('**Three.** <b>') == '**Three.**' and headline('plain line') == 'plain line'
    assert 'href="https://github.com/copper-browser/Copper/blob/fork/docs/flow.md"' in block
    assert 'javascript:' not in block
    assert block.count('class="rn"') == 3 and 'Latest' in block and 'No notes for this build.' in block
    assert '<time datetime="2026-11-24">24 Nov 2026</time>' in block
    assert 'Same notes in 1 earlier build:' in block
    global UNRELEASED_SHOWN
    shown, UNRELEASED_SHOWN = UNRELEASED_SHOWN, 1
    folded, _ = render(rel, u)
    UNRELEASED_SHOWN = shown
    assert 'All 3 changes' in folded and '<h3>Added</h3>' in folded and '<li><strong>Three.</strong></li>' in folded, folded
    # write() keeps everything outside the markers
    tmp = pathlib.Path(os.environ.get('TMPDIR', '/tmp')) / 'release-notes-selftest.html'
    tmp.write_text(f'<head>H</head><main>{BEGIN}OLDSEED{END}</main><footer>F</footer>')
    write(tmp, block)
    t = tmp.read_text()
    assert t.startswith('<head>H</head><main>' + BEGIN) and t.endswith(END + '</main><footer>F</footer>') and 'OLDSEED' not in t
    tmp.unlink()
    print('release_notes selftest: ok')


if __name__ == '__main__':
    if '--selftest' in sys.argv:
        selftest()
    else:
        args = [a for a in sys.argv[1:] if not a.startswith('-')]
        build(pathlib.Path(args[0]) if args else pathlib.Path(__file__).resolve().parents[2] / 'site')
