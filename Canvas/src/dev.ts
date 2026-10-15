/**
 * `?dev=1` outside Copper: stand in for the host. Records page → host
 * messages on `window.__copperHost`, initialises a demo canvas, seeds it
 * through the same ops an agent would use, and can simulate:
 *   `&peers=1`  a collaborator's cursor moving around (awareness); `&laser=1` she uses the laser
 *   `&agent=1`  an agent at work (presence + ops)
 *   `&online=1` the relayed sync socket, against an in-page server
 *   `&empty=1`  start from a blank board
 *   `&status=shared-offline&pending=3` what the host says via `setStatus`
 *   `&theme=dark|light`, `&readonly=1`
 *   `&frames=1` live web frames (Wikipedia, and a card beside it); `&frames=refused`
 *   also says the host reports frame loads, so frames nobody reports show the
 *   "can't be shown here" state (nobody reports outside Copper)
 */
import * as Y from 'yjs'
import { Awareness, applyAwarenessUpdate, encodeAwarenessUpdate } from 'y-protocols/awareness'
import { toBase64 } from './canvas/base64'
import { CanvasStore } from './canvas/doc'
import { controller } from './controller'
import { DevRelay } from './dev-relay'
import { hostDouble, type PageMessage } from './host-bridge'
import { createFrameSampler, counters, seedOps } from './canvas/debug'
import { LaserTrails } from './canvas/laser'
import { applyOps } from './ops'
import { setTheme } from './theme'

const svgImage = (dark: boolean) => {
  const bg = dark ? '#2a2a2e' : '#ffffff'
  const ink = dark ? '#e8e8ea' : '#1d1d1f'
  const bars = [42, 64, 51, 88, 73, 112, 96]
    .map(
      (h, i) =>
        `<rect x="${36 + i * 46}" y="${170 - h}" width="28" height="${h}" rx="5" fill="${i === 5 ? '#c8743c' : '#d9c3b0'}"/>`
    )
    .join('')
  return `data:image/svg+xml;utf8,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="220" viewBox="0 0 400 220"><rect width="400" height="220" rx="14" fill="${bg}"/><text x="24" y="34" font-family="-apple-system,system-ui" font-size="15" font-weight="600" fill="${ink}">Weekly active canvases</text>${bars}<line x1="24" y1="171" x2="376" y2="171" stroke="${ink}" stroke-opacity=".15"/></svg>`
  )}`
}

const DEMO_OPS = (dark: boolean) => [
  {
    op: 'add',
    shape: { type: 'text', id: 'title', x: -560, y: -380, w: 560, h: 52, text: '# Q4 launch plan', fontSize: 34 },
  },
  {
    op: 'add',
    shape: { type: 'frame', id: 'f-ideas', x: -560, y: -280, w: 700, h: 520, title: 'Ideas', color: 'gray' },
  },
  {
    op: 'add',
    shape: {
      type: 'sticky',
      id: 's1',
      x: -520,
      y: -240,
      color: 'yellow',
      text: '### Onboarding\n- Import from Arc\n- **One-click** sync\n- [ ] Write the welcome note',
    },
  },
  {
    op: 'add',
    shape: { type: 'sticky', id: 's2', x: -290, y: -240, color: 'pink', text: 'Shared canvases with *live* cursors' },
  },
  {
    op: 'add',
    shape: {
      type: 'sticky',
      id: 's3',
      x: -60,
      y: -240,
      color: 'blue',
      text: 'Agents draw on the board too — read the [spec](https://example.com/spec)',
    },
  },
  {
    op: 'add',
    shape: {
      type: 'sticky',
      id: 's4',
      x: -520,
      y: 10,
      color: 'green',
      text: '- [x] Offline first\n- [x] Personal canvas\n- [ ] Invites',
    },
  },
  {
    op: 'add',
    shape: { type: 'sticky', id: 's5', x: -290, y: 10, color: 'purple', text: 'Search with ⌘F, fly to any note' },
  },
  { op: 'add', shape: { type: 'frame', id: 'f-chart', x: 260, y: -280, w: 420, h: 240, title: 'Metrics', image: { src: svgImage(dark), naturalW: 400, naturalH: 220 } } },
  {
    op: 'add',
    shape: { type: 'link', id: 'l1', x: 260, y: 10, w: 320, h: 84, url: 'https://developer.apple.com/documentation/webkit/wkwebview', title: 'WKWebView | Apple Developer Documentation' },
  },
  {
    op: 'add',
    shape: { type: 'sticky', id: 's6', x: 260, y: 140, color: 'white', text: '**Risks**\nSync conflicts on big boards' },
  },
  { op: 'connect', id: 'a1', from: 's1', to: 's2', fromSide: 'right', toSide: 'left' },
  { op: 'connect', id: 'a2', from: 's2', to: 's3', label: 'then' },
  { op: 'connect', id: 'a3', from: 's5', to: 'l1', fromSide: 'right', toSide: 'left', color: 'blue' },
  { op: 'connect', id: 'a4', from: 'f-chart', to: 'l1', fromSide: 'bottom', toSide: 'top' },
]

/** `&frames=1`: a live frame beside the demo, as an agent would add one. */
const FRAME_OPS = [
  { op: 'add', shape: { type: 'web', id: 'web1', x: 760, y: -280, w: 900, h: 620, url: 'https://en.wikipedia.org/wiki/Monkey', title: 'Monkey - Wikipedia' } },
]

/** `&timeline=1`: a timeline card, as an agent would add one (with `&empty=1`, alone). */
const TIMELINE_OPS = (alone: boolean) => [
  {
    op: 'add',
    shape: {
      type: 'timeline',
      id: 'tl1',
      x: -440,
      y: alone ? -190 : 380,
      w: 880,
      title: 'Q4 launch',
      start: '2026-10-01',
      end: '2026-12-31',
      step: 'week',
      items: [
        { date: '2026-10-05', end: '2026-10-23', label: 'Discovery', color: 'yellow' },
        { date: '2026-10-06', label: 'Kickoff' },
        { date: '2026-10-19', end: '2026-11-13', label: 'Build sprint', color: 'blue' },
        { date: '2026-10-28', label: 'Design review', color: 'purple', text: 'Walk through the **new onboarding** with Ann and the support team.' },
        { date: '2026-11-09', end: '2026-11-27', label: 'Beta', color: 'green' },
        { date: '2026-11-12', label: 'API freeze', color: 'pink' },
        { date: '2026-11-24', label: 'Pricing call' },
        { date: '2026-12-01', end: '2026-12-18', label: 'Launch prep', color: 'purple' },
        { date: '2026-12-08', label: 'Launch', color: 'green', text: 'Press embargo lifts 9:00 PT.\n- blog post\n- changelog' },
        { date: '2026-12-17', label: 'Retro' },
      ],
    },
  },
]

export function startDev(params: URLSearchParams) {
  const host = hostDouble()
  const theme = params.get('theme')
  if (theme === 'dark' || theme === 'light') setTheme(theme)
  const online = params.get('online') === '1'
  let relay: DevRelay | null = null
  let route: ((msg: PageMessage) => void) | null = null
  if (online) {
    relay = new DevRelay(30)
    const client = relay.connect({
      wsMessage: b64 => window.copperCanvas?.wsMessage(b64),
      wsState: s => window.copperCanvas?.wsState(s),
    })
    route = msg => client.receive(msg)
  }
  host.onMessage = msg => {
    route?.(msg)
    if (msg.type === 'openUrl') console.info('[host] openUrl', msg.url)
    if (msg.type === 'log' && msg.level !== 'debug') console.info(`[host] ${msg.level}: ${msg.msg}`)
  }
  const dark = document.documentElement.classList.contains('dark')
  // The demo arrives the way a stored canvas does: as init.state, built
  // with the same ops an agent would send.
  let state: string | null = null
  if (params.get('empty') !== '1' || params.get('timeline') === '1') {
    const store = new CanvasStore(new Y.Doc())
    const demo = params.get('empty') === '1' ? [] : params.get('frames') ? [...DEMO_OPS(dark), ...FRAME_OPS] : DEMO_OPS(dark)
    const ops = params.get('timeline') === '1' ? [...demo, ...TIMELINE_OPS(!demo.length)] : demo
    const seeded = applyOps({ store, viewportCenter: () => ({ x: 0, y: 0 }) }, { ops, as: { id: 'seed', name: 'Demo' } })
    if (seeded.errors.length) console.warn('[dev] seed errors', JSON.stringify(seeded.errors))
    state = toBase64(Y.encodeStateAsUpdate(store.doc))
  }
  window.copperCanvas!.init({
    docId: 'dev-canvas',
    name: params.get('name') ?? 'Personal',
    kind: params.get('kind') ?? 'personal',
    me: { id: 'dev-user', name: 'Felipe', color: '#c8743c' },
    state,
    online,
    readOnly: params.get('readonly') === '1',
  })
  if (params.get('frames') === 'refused') window.copperCanvas!.frameHost({ reports: true })
  const status = params.get('status')
  if (status) window.copperCanvas!.setStatus({ mode: status, pending: Number(params.get('pending') ?? 0) })
  if (params.get('peers') === '1') simulatePeer(params.get('laser') === '1', params.get('frames') ? 'web1' : null)
  if (params.get('agent') === '1') simulateAgent()
  ;(window as unknown as { __dev: unknown }).__dev = { relay, controller }
  ;(window as unknown as { __canvasDebug: unknown }).__canvasDebug = {
    counters,
    perf: createFrameSampler(),
    seed: (opts?: Parameters<typeof seedOps>[0]) => window.copperCanvas!.apply({ ops: seedOps(opts), as: { id: 'seed', name: 'Seed' } }),
  }
}

/**
 * A collaborator wandering the board (awareness only). With `&laser=1` she
 * circles things with the laser pointer every few seconds.
 */
function simulatePeer(laser = false, frame: string | null = null) {
  const session = controller.session
  if (!session) return
  const ghost = new Awareness(new Y.Doc())
  const trails = new LaserTrails()
  let t = 0
  let beam = 0
  const tick = () => {
    t += 0.03
    const cursor = { x: Math.round(-200 + Math.cos(t) * 260), y: Math.round(-40 + Math.sin(t * 1.3) * 160) }
    if (laser) {
      // Every ~4 s: a 1.2 s loop around the "Ideas" frame's first note.
      beam = (beam + 1) % 66
      const a = (beam / 20) * Math.PI * 2
      const at = { x: -420 + Math.cos(a) * 150, y: -150 + Math.sin(a) * 110 }
      if (beam === 0) trails.begin(at, '#2f6fdf')
      else if (beam < 20) trails.move(at)
      else if (beam === 20) trails.end()
      cursor.x = Math.round(beam <= 20 ? at.x : cursor.x)
      cursor.y = Math.round(beam <= 20 ? at.y : cursor.y)
    }
    ghost.setLocalState({
      user: { id: 'ada', name: 'Ada', color: '#2f6fdf' },
      name: 'Ada',
      color: '#2f6fdf',
      cursor,
      selection: frame ? [frame] : ['s5'],
      laser: laser ? trails.localWire() : null,
      frame,
    })
    applyAwarenessUpdate(session.awareness, encodeAwarenessUpdate(ghost, [ghost.clientID]), 'dev')
  }
  tick()
  setInterval(tick, 60)
}

/** An agent that thinks, then writes a note now and then. */
function simulateAgent() {
  const api = window.copperCanvas!
  const agent = { id: 'agent:helper', name: 'Claude', color: '#7048e8' }
  api.setAgent({ ...agent, cursor: { x: 120, y: 60 }, status: 'thinking' })
  let n = 0
  setInterval(() => {
    n++
    api.setAgent({ ...agent, cursor: { x: 120 + (n % 3) * 60, y: 60 + (n % 2) * 40 }, status: 'thinking' })
    setTimeout(() => {
      api.apply(JSON.stringify({ ops: [{ op: 'add', shape: { type: 'sticky', color: 'purple', text: `Agent note ${n}` } }], as: agent }))
    }, 1200)
  }, 6000)
}
