# Canvas

The canvas page Copper shows at `copper://canvas/<id>` lives in
**[copper-browser/canvas-app](https://github.com/copper-browser/canvas-app)**, the one source for
Copper on macOS, Linux and Windows and for Canvas App in any browser. Change the page there.

Copper vendors its embed build: `Canvas/dist/canvas.html` is canvas-app's `dist/canvas.html` at
the commit in `Canvas/CANVAS_APP_REF`, and `build.sh` copies it into the app bundle. To take a new
page:

```sh
Canvas/sync.sh <canvas-app commit|tag|branch>   # pins the commit and fetches its build
Canvas/sync.sh --check                          # is the vendored file the pinned build?
Canvas/sync.sh --from ~/src/canvas-app/dist/canvas.html   # try a local build (pin before merging)
```

Nobody edits the page here. Every hour, `.github/workflows/canvas.yml` checks canvas-app `main`
and opens or updates a "Canvas: take canvas-app …" PR when it has moved; pull requests that touch
`Canvas/` must pass `Canvas/sync.sh --check`.

The host side (`Sources/Search/Fork/Canvas/`) and its contract (canvas-app's README, "Embedding")
stay here.
