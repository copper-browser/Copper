# The website — copper-browser.github.io/Copper

Copper's landing page is a single static page in [`site/`](../site), served by GitHub Pages at
**https://copper-browser.github.io/Copper/** and republished automatically whenever `site/`
changes on `fork`.

## How it is hosted

| Piece | Setting |
|---|---|
| Source of truth | `site/` on branch `fork` |
| Pages source | **GitHub Actions** (`build_type: workflow`) — no `gh-pages` branch; each deploy is an artifact |
| HTTPS | Enforced |
| Jekyll | Off (`site/.nojekyll`) — files are served exactly as committed |

Check the live configuration and the last deploy:

```sh
gh api repos/copper-browser/Copper/pages --jq '{status, html_url, build_type}'
gh run list -R copper-browser/Copper --workflow site.yml --limit 3
```

## How it deploys (CI/CD)

[`.github/workflows/site.yml`](../.github/workflows/site.yml):

1. Runs on every push to `fork` that touches `site/**` (or the workflow itself), on pull
   requests that touch them (build only, no deploy), and on demand
   (`gh workflow run site.yml -R copper-browser/Copper`).
2. **build:** checks that every `assets/…` file `index.html` references exists, then
   `actions/upload-pages-artifact` packs `site/`.
3. **deploy** (pushes to `fork` only): `actions/configure-pages` + `actions/deploy-pages` publish
   the artifact to the `github-pages` environment. The new page is live within a minute.

`concurrency` keeps one Pages deploy at a time; PR builds cancel superseded runs.

**Rollback:** revert the offending commit on `fork` (the workflow redeploys the previous
content), or re-run an earlier successful `site` run from the Actions tab
(`gh run rerun <run-id> -R copper-browser/Copper`).

**If a deploy looks stuck:** `gh run view <run-id> -R copper-browser/Copper --log-failed`; a
missing asset fails the build step with the file name.

**Setting it up from scratch** (e.g. a new repo): set Pages to GitHub Actions
(`gh api -X POST repos/<owner>/<repo>/pages -f build_type=workflow`, or `-X PUT` if Pages already
exists) and add `site.yml`.

## Editing the page

- Everything is in `site/index.html`: inline CSS and a little vanilla JS. No framework, no build
  step, no external fonts, CDNs, analytics or trackers. Assets live in `site/assets/`.
- Every path is relative (the site lives under `/Copper/`), except `og:image`/`og:url`, which
  must be absolute (`https://copper-browser.github.io/Copper/...`) for link previews.
- Light and dark follow `prefers-color-scheme`, with a toggle stored in `localStorage`
  (`copper-theme`). Captures come in pairs (`*-dark.*`); `window.copperMedia` in the `<head>`
  picks the pair that matches.
- Videos are `<video autoplay muted loop playsinline preload="metadata" poster=…>`; under
  `prefers-reduced-motion` only the poster shows.
- Hard rules: no horizontal scrolling at any width ≥ 360 px; AA contrast in both themes; real
  focus styles. Copper is presented on its own — the page names no other browser project as its
  origin. Facts on the page come from this repo's README and `docs/`; don't invent features.
- Install commands must match what `release.yml` publishes: the tap
  (`brew install --cask copper-browser/copper/copper`), the installer
  (`releases/latest/download/copper-install.sh`) and the zips
  (`releases/latest/download/copper-macos-arm64.zip` and `…/copper-macos-x86_64.zip`). See
  README › Installing.
- Install covers all three platforms. The first tab is this computer's: a Mac gets the Mac
  methods, a Windows PC the PowerShell line (`irm https://copper-browser.github.io/Copper/install.ps1
  | iex`, served from `site/install.ps1`: latest `CopperSetup-<x64|arm64>.exe` from
  copper-browser/copper-windows, checked against its `SHA256SUMS`, run with `--silent`, then
  Copper opened; `COPPER_NO_LAUNCH=1` skips that) and the installer for its CPU, Linux the
  copper-linux `install.sh` line and the `.deb`/Flatpak for its CPU. *All downloads* lists every
  build of all three; phones and unknown systems open on it. Windows and Linux files come from
  those repos' `releases/latest/download/`, so a release there needs no change here.
- Install › *For this Mac* points its button at this Mac's zip: the CPU comes from
  `navigator.userAgentData`'s `architecture` (Chromium), else the WebGL renderer's name (Chrome,
  Firefox), else ASTC texture support (Safari says "Apple GPU" on every Mac; only Apple's GPUs
  take ASTC). Unsure means Apple Silicon, with the Intel link right under it. Anything that is
  not a Mac opens on *All downloads*, which lists every build.

### Preview and QA before pushing

```sh
python3 -m http.server 8000 -d site      # then open http://localhost:8000/
```

Check at 1440 (light and dark), 834, 390 and 360 px: `document.documentElement.scrollWidth <=
innerWidth`, no console errors or failed requests, the copy buttons, the ⌘K palette and the
hide-banner demo in "Try it here", and the theme toggle. Playwright's bundled Chromium cannot
play H.264, so check the videos in Safari or Chrome.

## Launch graphics

The hero bento, `loop-spaces`/`loop-agents` (captioned loops), `post-*.webp` (the launch thread's
stills), `tile-*.webp` (bento pieces), `art-*.webp` (copper-art backdrops) and `og.jpg` come from
the launch kit (bento source, caption renderer and raw recordings), not from `site-capture/`.
The bento itself is live HTML in `index.html`; `og.jpg` is a 1200×630 crop of its render.

## Captures (screenshots and loops)

Every image and video of the app on the page is a real capture of Copper, made by
[`site-capture/`](../site-capture) against a separate **headless** Copper, so the browser you
are using is never touched:

| Asset | What it shows | Made with |
|---|---|---|
| `copper-motion(-dark).mp4/.webp` | tab switch, ⌘K filtering, a space switch, tabs on top and back | `rec_motion.py` → `compose.py video` |
| `copper-jev(-dark).mp4/.webp` | a real Jev run: "Search Wikipedia for patina and stop when the article is visible", with the driver timeline | `rec_jev.py` → `compose.py video` |

Recipe:

1. `site-capture/launch.sh` downloads the latest release into `$COPPER_SHOOT`
   (default `/tmp/copper-shoot`), builds the `hidpi.m` shim (real 2× pixels and active-looking
   window controls), and starts it headless in probe world `sitepics` on MCP port 4196.
   `./bench` needs the `bench` default on in that world's own suite
   (`defaults write com.officecommun.search.test.sitepics bench -bool true`; never the installed
   Copper's `com.collinrijock.copper`).
2. Set the world up with public pages only — never sign in to anything. The current captures use
   three spaces: Personal (google.com, Wikipedia "Patina", apple.com/mac,
   news.ycombinator.com), Work (w3.org, swift.org, webkit.org) and Reading (Wikipedia: Statue of
   Liberty, Verdigris, Patina). For Jev, the world needs its own `intelligence.json` (0600) in
   `~/Library/Application Support/Copper (sitepics)/`; keep keys, settings pages and internal
   URLs out of every frame.
3. Record: `cb.py` grabs whole-window PNGs over the bench socket (the bench `window` verb — no
   window is brought forward) as fast as it can. `rec_motion.py <outdir>` scripts the tab/space
   tour; `rec_jev.py <outdir> "<goal>"` records while `site-capture/cop run "<goal>"` drives
   the page.
4. Compose: `compose.py still IN.png OUT.png --theme light|dark` or
   `compose.py video FRAMEDIR OUT.mp4 --start T --end T --fps 30 --theme … [--fade S]` puts the
   window on the warm backdrop with a macOS-style shadow at 2240×1480 and encodes H.264
   (`yuv420p`, `+faststart`, CRF 26, no audio), writing a poster PNG next to it. Convert stills
   and posters to WebP with `cwebp -q 82`. Keep each video under ~2.5 MB.
5. Stop only the capture instance: `kill "$(cat "$COPPER_SHOOT/PID")"`.
