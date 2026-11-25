# The website — copper.exowatt.com

Copper's website is static HTML in [`site/`](../site): the landing page plus a few subpages
(`site/<page>/index.html`). It is served from two hosts, both republished automatically whenever
`site/` changes on `fork` (and once a day):

- **https://copper.exowatt.com/** — Exowatt AWS, S3 + CloudFront ([`infra/site-aws.yml`](../infra/site-aws.yml)).
  The canonical host: every page's `<link rel=canonical>`, `og:url`, `robots.txt` and `sitemap.xml` point here.
- **https://copper-browser.github.io/Copper/** — GitHub Pages, a mirror.

## How it is hosted

| Piece | Setting |
|---|---|
| Source of truth | `site/` on branch `fork` |
| AWS | S3 bucket `copper-site-340752802981` behind CloudFront `E2MR74IJVKSHAD`; a CloudFront Function serves `/x/` as `/x/index.html` and redirects `/x` to `/x/`; a missing file gets `site/404.html` with status 404 |
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

1. Runs on every push to `fork` that touches `site/**`, the workflow, `.github/scripts/site_build.py`
   or `release_notes.py`; on pull requests that touch them (build and check only, no deploy); daily
   at 09:17 UTC (so a new release's version and notes show up); and on demand
   (`gh workflow run site.yml -R copper-browser/Copper`).
2. **build:** [`.github/scripts/site_build.py`](../.github/scripts/site_build.py) (stdlib Python, no
   dependencies) writes the latest release's version (from its `copper-version.json`) into
   `index.html`'s `<span data-version>`, `<a data-version-href href="release-notes/#…">` and JSON-LD
   `"softwareVersion"`, builds `release-notes/` (`release_notes.py`, when present) and writes
   `sitemap.xml`. Then `--check` fails the build on a missing asset, a broken relative link or
   `#anchor`, or a subpage whose header or footer differs from `site/_page-template.html`. A link
   to a subpage that isn't there yet only warns. The template is removed and
   `actions/upload-pages-artifact` packs `site/`.
3. **deploy** (pushes to `fork` only): `actions/configure-pages` + `actions/deploy-pages` publish
   the artifact to the `github-pages` environment. **aws** runs the same build, syncs `site/` to S3
   and invalidates CloudFront. Both are live within a minute or two.

`concurrency` keeps one Pages deploy at a time; PR builds cancel superseded runs.

**Rollback:** revert the offending commit on `fork` (the workflow redeploys the previous
content), or re-run an earlier successful `site` run from the Actions tab
(`gh run rerun <run-id> -R copper-browser/Copper`).

**If a deploy looks stuck:** `gh run view <run-id> -R copper-browser/Copper --log-failed`; a
missing asset fails the build step with the file name.

**Setting it up from scratch** (e.g. a new repo): set Pages to GitHub Actions
(`gh api -X POST repos/<owner>/<repo>/pages -f build_type=workflow`, or `-X PUT` if Pages already
exists) and add `site.yml`.

**The CloudFront stack** (the Function, the 404 page, the deploy role) changes only when someone
with Exowatt admin SSO runs the command at the top of `infra/site-aws.yml`; merging the file does
not apply it.

## Editing the pages

- The home page is all in `site/index.html`: inline CSS and a little vanilla JS. No framework, no
  external fonts, CDNs, analytics or trackers. Assets live in `site/assets/`.
- **Subpages** are `site/<page>/index.html`, always one folder down, so `../` is the site root on
  both hosts. Make one by copying [`site/_page-template.html`](../site/_page-template.html) and filling
  its `{{…}}` slots (title with the keyword, description, the page's path for the canonical URL);
  put `aria-current="page"` on its own header link. They share `assets/pages.css` (the home page's
  tokens, header and footer, plus prose, tables and cards) and `assets/pages.js` (theme switch, copy
  buttons). Keep `<header>` and `<footer>` exactly as in the template: change the template and every
  page together, or the build fails. Link pages by folder (`../arc/`), never `index.html`.
- `site/404.html` is served for a missing path at any depth, so it has `<base href="https://copper.exowatt.com/">`
  and writes its URLs root-relative (`./assets/…`); on the Pages mirror its links lead to the canonical host.
- Every other path is relative (the mirror lives under `/Copper/`), except canonical,
  `og:image` and `og:url`, which are absolute on `https://copper.exowatt.com/` for link previews.
- `robots.txt` and `sitemap.xml` only count at a host's root, so they work on copper.exowatt.com;
  `sitemap.xml` is generated (not committed) and lists the home page and every subpage.
- Light and dark follow `prefers-color-scheme`, with a toggle stored in `localStorage`
  (`copper-theme`). Captures come in pairs (`*-dark.*`); `window.copperMedia` in the `<head>`
  picks the pair that matches.
- Videos are `<video class="loop" muted loop playsinline preload="none">` with the file and
  poster in `data-*` attributes: the script at the end of the page sets them when the video
  comes within 900 px of the screen and plays it while it is on screen. There is no pause button:
  the recording itself is the control (`role="button"`, named "Pause…" or "Play…"), so a click,
  Space or Enter toggles it. The bento's three sidebars share one control. Under
  `prefers-reduced-motion` only the poster shows until someone presses play.
- The hero screenshot loads first (the measured LCP is the art behind it, which is preloaded): `fetchpriority="high"`, never `loading="lazy"`,
  with `width`/`height` so nothing shifts. The source order in the hero is copy, window, meta,
  which is also the order on a phone; don't reorder it with CSS `order` (content that streams in
  later would push what is already on screen).
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
python3 .github/scripts/site_build.py && python3 .github/scripts/site_build.py --check
python3 -m http.server 8000 -d site      # then open http://localhost:8000/
git checkout site/index.html             # the build rewrote the version; don't commit that
```

Check every page at 1440 (light and dark), 834, 390 and 360 px: `document.documentElement.scrollWidth <=
innerWidth`, no console errors or failed requests, the copy buttons, the ⌘K palette and the
hide-banner demo in "Try it here", and the theme toggle. Playwright's bundled Chromium cannot
play H.264, so check the videos in Safari or Chrome.

## Launch graphics

The hero bento, `loop-spaces`/`loop-agents` (captioned loops), `post-*.webp` (the launch thread's
stills; the credits card is no longer used, it carried the old tagline), `tile-*.webp` (bento pieces), `art-*.webp` (copper-art backdrops) and `og.jpg` come from
the launch kit (bento source, caption renderer and raw recordings), not from `site-capture/`.
The bento itself is live HTML in `index.html`; `og.jpg` is the live hero at 1200×630 with the nav, quip, buttons and meta hidden.
`loop-agents` has four lines of its GitHub pane blurred (the fork line, the About text, the star counts and the branch banner), in the video and the poster, so the page keeps to the rule above; re-record it on another page when the launch kit is next open.

## Captures (screenshots and loops)

Every image and video of the app on the page is a real capture of Copper, made by
[`site-capture/`](../site-capture) against a separate **headless** Copper, so the browser you
are using is never touched:

| Asset | What it shows | Made with |
|---|---|---|
| `copper-hero-*.webp` | the whole window on Wikipedia's Copper article (phone: the same page in a 640×560 window), dark appearance, sidebar on | `launch.sh` with `SIZE=1280x800` (or `640x560`) → bench `window` → `convert` to WebP at 1280 and 1920 wide, alpha kept (lossless: smaller than lossy for a page of text) |
| `side-{copper,patina,ember}.mp4/.webp` | each space's sidebar: the animated theme and the selection moving between tabs | `launch.sh` with `SIZE=640x760` → `rec_sides.py` → crop the left 464 px, scale to 336×840, 24 fps, CRF 27–29, last 0.6 s dissolved into the first |
| `copper-motion(-dark).mp4/.webp` | tab switch, ⌘K filtering, a space switch, tabs on top and back | `rec_motion.py` → `compose.py video` |
| `copper-jev(-dark).mp4/.webp` | a real Jev run: "Search Wikipedia for patina and stop when the article is visible", with the driver timeline | `rec_jev.py` → `compose.py video` |

Recipe:

1. `site-capture/launch.sh` downloads the latest release into `$COPPER_SHOOT`
   (default `/tmp/copper-shoot`), builds the `hidpi.m` shim (real 2× pixels and active-looking
   window controls), and starts it headless in probe world `sitepics` on MCP port 4196.
   `./bench` needs the `bench` default on in that world's own suite
   (`defaults write com.collinrijock.copper.test.sitepics bench -bool true`; never the installed
   Copper's `com.collinrijock.copper`).
2. Set the world up with public pages only — never sign in to anything. The motion and Jev
   captures use three spaces: Personal (google.com, Wikipedia "Patina", apple.com/mac,
   news.ycombinator.com), Work (w3.org, swift.org, webkit.org) and Reading (Wikipedia: Statue of
   Liberty, Verdigris, Patina). The hero and the bento sidebars use Copper (google.com, Wikipedia
   "Copper", apple.com/mac, news.ycombinator.com), Patina (Wikipedia: Patina, Verdigris, Statue
   of Liberty) and Ember (webkit.org, swift.org, w3.org), each with an animated theme. For Jev, the world needs its own `intelligence.json` (0600) in
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
