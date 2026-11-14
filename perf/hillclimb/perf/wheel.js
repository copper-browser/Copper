(() => {
  // A5 wheel bench: a rAF frame recorder the harness runs around `bench wheel` (the hook replays
  // a real trackpad gesture through the window; bench eval can't await, so two calls).
  // 'start' records [t, scrollY] each frame; 'stop' answers the frames between the first and the
  // last scroll movement: intervals, dropped against 120 Hz (8.33 ms) and against the page's own
  // refresh (median interval).
  const MODE = '__MODE__'
  const el = document.scrollingElement || document.documentElement
  if (MODE === 'start') {
    if (window.__hcWheel) window.__hcWheel.on = false
    const W = (window.__hcWheel = { on: true, f: [] })
    const t0 = performance.now()
    const step = now => {
      if (!W.on || now - t0 > 20000) return
      W.f.push([now, el.scrollTop])
      requestAnimationFrame(step)
    }
    requestAnimationFrame(step)
    return JSON.stringify({ state: 'recording', y: el.scrollTop, height: el.scrollHeight, dpr: devicePixelRatio })
  }
  const W = window.__hcWheel
  if (!W) return JSON.stringify({ error: 'not recording' })
  W.on = false
  const f = W.f
  let a = f.findIndex((x, i) => i > 0 && x[1] !== f[i - 1][1])
  let b = f.length - 1
  while (b > 0 && f[b][1] === f[b - 1][1]) b--
  if (a < 1 || b <= a) return JSON.stringify({ moved: 0, frames: 0, recorded: f.length })
  a -= 1 // the frame before the first movement: its interval counts
  const d = []
  for (let i = a + 1; i <= b; i++) d.push(Math.round((f[i][0] - f[i - 1][0]) * 100) / 100)
  const s = [...d].sort((x, y) => x - y)
  const q = p => s[Math.min(s.length - 1, Math.ceil(p * s.length) - 1)]
  const refresh = s[Math.floor(s.length / 2)]
  const drop = per => d.reduce((n, x) => n + Math.max(0, Math.round(x / per) - 1), 0)
  const d120 = drop(1000 / 120)
  return JSON.stringify({
    moved: Math.round(f[b][1] - f[a][1]), frames: d.length, duration_ms: Math.round(f[b][0] - f[a][0]),
    refreshMs: refresh, p50: q(0.5), p90: q(0.9), max: s[s.length - 1],
    dropped120: d120, dropped120_pct: Math.round(1000 * d120 / (d.length + d120)) / 10,
    droppedOwn: drop(refresh), d, dpr: devicePixelRatio,
  })
})()
