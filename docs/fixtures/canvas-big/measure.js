() => {
  // canvas-big bench: run in the canvas tab with `copper eval "$(cat measure.js)"`.
  //
  // Two-phase, because macOS `copper eval` (WKWebView evaluateJavaScript)
  // cannot wait for a promise: the first call samples the board and starts a
  // scripted 5 s pan+zoom (synthetic wheel events on the board, ctrl = zoom),
  // answering {state:'started', before} — the path: 0–1.25 s pan 1600 px
  // right, 1.25–2.5 s back, 2.5–3.75 s zoom out ≤ 4×, 3.75–5 s back in, eased,
  // time-driven so every build travels the same path; call again after ~6.5 s for
  // {state:'done', before, run:{frames,p50,p95,max,over25,over33,...}, after}.
  // While it runs a call answers {state:'running'}. Once read, the next call
  // starts a fresh run. Reads the DOM only — works on any page build.
  const B = (window.__canvasBench = window.__canvasBench || { state: 'idle' })
  const DURATION = 5000
  const board = document.querySelector('[role="application"]') || document.body
  const layer = board.firstElementChild
  const view = () => {
    const m = layer && /translate\(([-\d.e]+)px,\s*([-\d.e]+)px\)\s*scale\(([-\d.e]+)\)/.exec(layer.style.transform || '')
    return m ? { x: +m[1], y: +m[2], z: +m[3] } : null
  }
  const sample = () => {
    const ids = new Set()
    const kinds = {}
    for (const el of board.querySelectorAll('[data-id]')) {
      const id = el.getAttribute('data-id')
      if (ids.has(id)) continue
      ids.add(id)
      const k = el.getAttribute('data-kind') || (el.querySelector('iframe') ? 'web' : el.tagName.toLowerCase() === 'g' ? 'arrow' : 'box')
      kinds[k] = (kinds[k] || 0) + 1
    }
    const iframes = [...document.querySelectorAll('iframe')]
    const live = iframes.filter(f => {
      const s = f.getAttribute('src') || ''
      return s && s !== 'about:blank'
    })
    const imgs = [...document.images]
    const r = board.getBoundingClientRect()
    const out = {
      domNodes: document.getElementsByTagName('*').length,
      mountedShapes: ids.size,
      mountedByKind: kinds,
      iframes: iframes.length,
      liveIframes: live.length,
      images: imgs.length,
      imagesLoaded: imgs.filter(i => i.complete && i.naturalWidth > 0).length,
      imagePixelsMP: Math.round(imgs.reduce((a, i) => a + (i.naturalWidth || 0) * (i.naturalHeight || 0), 0) / 1e5) / 10,
      svgPaths: document.querySelectorAll('svg path, svg line, svg polyline').length,
      viewport: { w: Math.round(r.width), h: Math.round(r.height) },
      view: view(),
      pageAgeMs: Math.round(performance.now()),
    }
    if (performance.memory) out.jsHeapMB = Math.round(performance.memory.usedJSHeapSize / 1048576)
    return out
  }

  if (B.state === 'running') return { state: 'running', elapsedMs: Math.round(performance.now() - B.t0) }
  if (B.state === 'done' && !B.read) {
    B.read = true
    return B.result
  }

  // ---- start a run -----------------------------------------------------------
  const before = sample()
  const r = board.getBoundingClientRect()
  const cx = r.left + r.width / 2
  const cy = r.top + r.height / 2
  const wheel = (dx, dy, zoom) =>
    board.dispatchEvent(
      new WheelEvent('wheel', { deltaX: dx, deltaY: dy, deltaMode: 0, ctrlKey: !!zoom, clientX: cx, clientY: cy, bubbles: true, cancelable: true }),
    )
  // The path is a function of time, not of frames: each frame sends what is
  // still owed of it, so a slow build and a fast one travel the same path and
  // end where they started. Pan 1600 px right and back, then zoom out (≤ 4×) about
  // the centre and back in (the board: ctrl-wheel factor = exp(-dy · 0.009)).
  const PAN = 1600
  // Zoom out 4×, less if that would hit the board's MIN_ZOOM (0.1) and break the round trip.
  const z0 = (before.view && before.view.z) || 0.4
  const ZOOM_OUT = Math.max(1, Math.min(4, z0 / 0.105))
  const ZOOM_DY = Math.log(ZOOM_OUT) / 0.009
  const ease = f => 0.5 - 0.5 * Math.cos(Math.PI * Math.min(1, Math.max(0, f)))
  const target = e => {
    const q = DURATION / 4
    const pan = e < q ? PAN * ease(e / q) : e < 2 * q ? PAN * (1 - ease((e - q) / q)) : 0
    const zoom = e < 2 * q ? 0 : e < 3 * q ? ZOOM_DY * ease((e - 2 * q) / q) : ZOOM_DY * (1 - ease((e - 3 * q) / q))
    return { pan, zoom }
  }
  const sent = { pan: 0, zoom: 0 }
  const drive = e => {
    const t = target(e)
    const dp = t.pan - sent.pan
    if (dp) wheel(dp, 0, false)
    sent.pan = t.pan
    let dz = t.zoom - sent.zoom
    while (Math.abs(dz) > 1e-9) {
      const s = Math.max(-60, Math.min(60, dz)) // the board clamps one event to ±60
      wheel(0, s, true)
      sent.zoom += s
      dz -= s
    }
  }
  const deltas = []
  // Frame times by phase (the first half pans, the second zooms), so a regression can be placed.
  const byPhase = { pan: [], zoom: [] }
  let peakMounted = before.mountedShapes
  let peakLive = before.liveIframes
  let peakDom = before.domNodes
  let last = 0
  let n = 0
  Object.assign(B, { state: 'running', read: false, t0: performance.now(), result: null })
  const step = t => {
    const e = t - B.t0
    if (last) {
      deltas.push(t - last)
      byPhase[e < DURATION / 2 ? 'pan' : 'zoom'].push(t - last)
    }
    last = t
    drive(Math.min(e, DURATION))
    if (++n % 15 === 0) {
      const s = board.querySelectorAll('[data-id]').length
      if (s > peakMounted) peakMounted = s
      const f = document.querySelectorAll('iframe[src]:not([src="about:blank"])').length
      if (f > peakLive) peakLive = f
      const d = document.getElementsByTagName('*').length
      if (d > peakDom) peakDom = d
    }
    if (e < DURATION) return requestAnimationFrame(step)
    const sorted = [...deltas].sort((a, b) => a - b)
    const pct = p => (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] : 0)
    const r1 = x => Math.round(x * 10) / 10
    const run = {
      durationMs: Math.round(e),
      zoomOut: Math.round(ZOOM_OUT * 100) / 100,
      frames: deltas.length,
      fps: r1((deltas.length * 1000) / e),
      p50: r1(pct(0.5)),
      p95: r1(pct(0.95)),
      p99: r1(pct(0.99)),
      max: r1(sorted[sorted.length - 1] || 0),
      over25: deltas.filter(d => d > 25).length,
      over33: deltas.filter(d => d > 33.4).length,
      over100: deltas.filter(d => d > 100).length,
      peakDomElements: peakDom,
      peakMountedElements: peakMounted,
      peakLiveIframes: peakLive,
      phases: Object.fromEntries(
        Object.entries(byPhase).map(([k, d]) => {
          const s = [...d].sort((a, b) => a - b)
          const q = p => (s.length ? s[Math.min(s.length - 1, Math.floor(s.length * p))] : 0)
          return [k, { frames: d.length, p50: r1(q(0.5)), p95: r1(q(0.95)), max: r1(s[s.length - 1] || 0), over33: d.filter(x => x > 33.4).length }]
        }),
      ),
    }
    // Let pan/zoom settle (culling, live budgets, posters) before the after-sample.
    setTimeout(() => {
      B.result = { state: 'done', before, run, after: sample() }
      B.state = 'done'
    }, 1200)
  }
  requestAnimationFrame(step)
  return { state: 'started', before }
}
