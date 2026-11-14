(() => {
  // A5 scroll bench, two-phase like canvas-big/measure.js (bench eval can't await):
  // the first call starts a time-driven scroll (down 2 s, back up 2 s, eased, same
  // path on every build) and answers {state:'started'}; a call after ~4.5 s answers
  // {state:'done', run:{...}}. rAF-to-rAF frame times; `dropped` counts the frames
  // missed against the page's own refresh (median interval), janky the frames over
  // 1.5× that interval (over16 is kept raw: at 60 Hz rAF jitters around 16.7 ms).
  const B = (window.__hcScroll = window.__hcScroll || { state: 'idle' })
  if (B.state === 'running') return JSON.stringify({ state: 'running' })
  if (B.state === 'done') { const r = B.result; B.state = 'idle'; return JSON.stringify(r) }
  const el = document.scrollingElement || document.documentElement
  const travel = Math.min(6000, el.scrollHeight - innerHeight)
  if (travel < 500) return JSON.stringify({ state: 'error', error: 'page too short', scrollHeight: el.scrollHeight })
  const DURATION = 4000
  const ease = t => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2)
  const times = []
  el.scrollTop = 0
  B.state = 'running'
  let start = null, last = null
  const step = now => {
    if (start === null) { start = now; last = now }
    else { times.push(now - last); last = now }
    const t = (now - start) / DURATION
    if (t >= 1) {
      el.scrollTop = 0
      const s = [...times].sort((a, b) => a - b)
      const q = p => Math.round(s[Math.min(s.length - 1, Math.floor(p * s.length))] * 10) / 10
      const base = s[Math.floor(s.length / 2)]
      const dropped = times.reduce((a, d) => a + Math.max(0, Math.round(d / base) - 1), 0)
      B.result = { state: 'done', run: {
        frames: times.length, fps: Math.round(times.length / (DURATION / 1000) * 10) / 10,
        refreshMs: Math.round(base * 10) / 10, p50: q(0.5), p95: q(0.95), p99: q(0.99), max: q(1),
        janky: times.filter(d => d > 1.5 * base).length, over16: times.filter(d => d > 16.7).length,
        over33: times.filter(d => d > 33.4).length,
        dropped, travel, dpr: devicePixelRatio, nodes: document.getElementsByTagName('*').length } }
      B.state = 'done'
      return
    }
    el.scrollTop = travel * ease(t < 0.5 ? t * 2 : 2 - t * 2)
    requestAnimationFrame(step)
  }
  requestAnimationFrame(step)
  return JSON.stringify({ state: 'started', travel, dpr: devicePixelRatio })
})()
