# Copper — website

The static website for [Copper](https://github.com/copper-browser/Copper), served by Exowatt AWS
(S3 + CloudFront, [`infra/site-aws.yml`](../infra/site-aws.yml)) at `https://copper.exowatt.com`
(canonical) and by GitHub Pages at `https://copper-browser.github.io/Copper/` (mirror).
[`docs/website.md`](../docs/website.md) has the rules.

- `index.html` — the home page: inline CSS and a little vanilla JS. No framework, no external
  fonts, CDNs or trackers.
- `<page>/index.html` — subpages (`privacy/`, `press/`, …), each copied from `_page-template.html`
  and sharing `assets/pages.css` + `assets/pages.js`. `404.html` is served for any missing path.
  `benchmarks/index.html` is written by `perf/xbench/page.py` from `assets/bench.json` and
  `assets/agentbench.json` (measured runs); regenerate it rather than editing it.
- `robots.txt`; `sitemap.xml` is written by `.github/scripts/site_build.py` at deploy.
- `press/copper-icon-1024.png` — the app icon at 1024 px, taken from the release's `AppIcon.icns`.
- `assets/` — real captures of Copper, the app icon, favicons and the 1200×630 `og.jpg`
  social card:
  - `copper-hero-{1280,1920}.webp` + `copper-hero-sm.webp` — the hero: the whole Copper
    window on Wikipedia's Copper article, transparent surround (`-sm`: a narrower window for phones).
  - `side-{copper,patina,ember}.mp4` + `.webp` — the bento's three sidebars, each space's
    animated theme with the selection moving between tabs (loop + poster, about 70 KB each).
  - `copper-motion.mp4` + `copper-motion.webp` — tabs, ⌘K, spaces, tabs on top (loop + poster).
  - `copper-jev.mp4` + `copper-jev.webp` — Jev running one goal, driver timeline open.
  Videos are H.264, muted, `+faststart`. Nothing of a video is fetched until it is near the
  screen; it plays only while on screen, a click (or Space/Enter) pauses it, and under
  `prefers-reduced-motion` only the poster shows.
- `.nojekyll` — serve the files as they are.

Pushing a change under `site/` to `fork` deploys it: `.github/workflows/site.yml` runs
`.github/scripts/site_build.py` (version, release notes, sitemap) and its `--check` (assets, links,
anchors, header/footer match the template), then publishes `site/` to both hosts. Pull requests
that touch `site/` run the same build and check without deploying.

Every path is relative (404.html: relative to its `<base>`, the canonical root), so the pages work from either
host and any subpath.

## Preview locally

```sh
python3 .github/scripts/site_build.py --check
python3 -m http.server -d site
```

then open <http://localhost:8000/>.
