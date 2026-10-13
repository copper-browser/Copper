# Copper — website

The static landing page for [Copper](https://github.com/copper-browser/Copper), meant to be
served by GitHub Pages at `https://copper-browser.github.io/Copper/`.

- `index.html` — the whole page: inline CSS and a little vanilla JS. No framework, no build
  step, no external fonts, CDNs or trackers.
- `assets/` — real captures of Copper, the app icon, favicons and the 1200×630 `og.png`
  social card:
  - `copper-google.webp` — the hero still (2240×1480, shown at 1120 CSS px).
  - `copper-motion.mp4` + `copper-motion.webp` — tabs, ⌘K, spaces, tabs on top (loop + poster).
  - `copper-jev.mp4` + `copper-jev.webp` — Jev running one goal, driver timeline open.
  - `copper-linux.webp` + `copper-linux-dark.webp` — Copper for Linux (WebKitGTK, GDK_SCALE=2
    on Xvfb), light and dark, on the same backdrops as `copper-motion`; 2240×1480 like it.
  Videos are H.264, muted, `+faststart`; they play only while on screen, have a Pause
  button, and show just the poster under `prefers-reduced-motion`.
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
