# Copper — website

The static landing page for [Copper](https://github.com/copper-browser/Copper), meant to be
served by GitHub Pages at `https://copper-browser.github.io/Copper/` and by Exowatt AWS
(S3 + CloudFront, [`infra/site-aws.yml`](../infra/site-aws.yml)) at `https://copper.exowatt.com`.

- `index.html` — the whole page: inline CSS and a little vanilla JS. No framework, no build
  step, no external fonts, CDNs or trackers.
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

Pushing a change under `site/` to `fork` deploys it: `.github/workflows/site.yml` checks that
every `assets/` file the page references exists, then publishes `site/` with GitHub Pages
(Source: GitHub Actions). Pull requests that touch `site/` run the same check without deploying.

Every path is relative, so the page works from the Pages URL, from any subpath, and straight
from `file://`.

## Preview locally

```sh
python3 -m http.server -d site
```

then open <http://localhost:8000/>.
