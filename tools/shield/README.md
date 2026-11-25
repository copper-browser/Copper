# tools/shield — the ad blocker's lists

`refresh.py` (on a Mac, once a release) fetches the lists in `lists.json`, converts each to
WebKit content-rule JSON with AdGuard's [SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib)
(its `ConverterTool`, built from the commit pinned in `lists.json`), and writes
`Sources/Search/Resources/shield/`: one `<id>.json.xz` per list (more if a list is over
WebKit's 150,000 rules) and `index.json`. Copper reads the index at launch
(`Fork/ShieldLists.swift`), compiles each file once per version into the world's own
`Shield/` store and puts the lists on every page (`Shield.swift`).

```sh
tools/shield/refresh.py              # every list
tools/shield/refresh.py ads cookies  # some; the rest stay as committed
tools/shield/refresh.py --check      # the script's self-check (no network)
```

- **Kinds** (Settings › Privacy › Blocking): `ads` (EasyList, uBlock filters, badware, quick
  fixes), `trackers` (EasyPrivacy, uBlock privacy), `cookies` (EasyList Cookie, uBlock and
  AdGuard cookie notices), `regional` (uBlock Origin's regional lists, picked by the Mac's
  languages). Lists, URLs and languages follow uBlock Origin's `assets.json`.
- **Exceptions** are global in uBlock but a WebKit list's `ignore-previous-rules` reaches only
  its own list, so ads, trackers and cookies each also carry uBlock's unbreak list and every
  `@@` exception from every list.
- **Can't be done in a rule list:** scriptlets (`##+js(...)`), `:style()`, HTML filtering and
  redirects. The converter counts them as `errors` in `index.json`.
- **Licences:** the lists keep their own (EasyList, EasyPrivacy, EasyList Cookie: GPLv3 or
  CC BY-SA 3.0; uBlock Origin's filters and AdGuard's: GPLv3; regional lists: see each list's
  header, URLs in `lists.json`). SafariConverterLib is GPLv3 and stays a build tool: nothing of
  it ships in Copper.
