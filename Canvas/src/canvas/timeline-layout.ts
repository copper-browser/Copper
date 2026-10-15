/**
 * Where everything on a timeline card goes (pure; no DOM, no Yjs).
 *
 * World px, relative to the card's top-left. The axis is one horizontal line;
 * the range's days are equal cells along it (a pin sits in its day's middle,
 * a section covers its days' cells), so resizing the card only rescales x.
 *
 * Top to bottom: the header, the tiers of notes and bubbles above the axis
 * (each on a vertical stem down to its dot), the axis and its step ticks, the
 * tick labels (with a context row — month or year — where it helps), the
 * section lanes, then the tiers that did not fit above (stems down past the
 * labels). Tiers are packed greedily, left to right: no two boxes overlap,
 * and a stem never runs behind another box when nudging that box sideways
 * can avoid it. Which tiers go above depends only on the content and the
 * width, never the height, so growing a card to fit never reshuffles it; a
 * taller card only adds room around the content.
 */
import { DEFAULT_STEP, dayOf, isoOf, type ItemColor, type ItemKind, type Step } from './timeline-text'

/** Layout numbers shared with the card's CSS (world px). */
export const TL = {
  /** The header band: title row and summary row. */
  head: 62,
  padX: 24,
  /** Room between the header and the highest tier (Today's label sits in it). */
  padTop: 22,
  /** The least room above the axis: the hover tip and Today's label. */
  minAbove: 30,
  /** Tiers above the axis stop at this height; the rest go below. */
  aboveMax: 216,
  /** Shortest stem: axis → a tier's baseline. */
  stem: 16,
  tierGap: 8,
  /** Tiers that did not fit above: lanes (or labels) → the first, besides the stem. */
  belowGap: 4,
  /** Between boxes in one tier. */
  boxGap: 8,
  /** Boxes keep this far inside the card. */
  edge: 8,
  /** A stem keeps this far inside its own box, and clear of others. */
  stemInset: 9,
  stemClear: 5,
  labelGap: 9,
  labelH: 14,
  subH: 13,
  lanesGap: 10,
  lane: 24,
  laneGap: 4,
  padBottom: 16,
  chipH: 24,
  chipPadX: 10,
  chipMax: 184,
  bubbleMin: 132,
  bubbleMax: 240,
  bubblePadX: 11,
  bubblePadY: 8,
  bubbleTitle: 18,
  bubbleLine: 17,
  bubbleLines: 4,
} as const

export type Font = 'tick' | 'tickStrong' | 'chip' | 'bubbleTitle' | 'bubbleBody'
/** Width of one line of text in world px, in the card's font. */
export type Measure = (text: string, font: Font) => number

const FONT_PX: Record<Font, number> = { tick: 11, tickStrong: 11, chip: 12, bubbleTitle: 12.5, bubbleBody: 12.5 }
const BOLD: Record<Font, number> = { tick: 1, tickStrong: 1.05, chip: 1, bubbleTitle: 1.06, bubbleBody: 1 }

/** A measurer without a browser: per-character widths of a system sans, on the generous side. */
export const estimateWidth: Measure = (text, font) => {
  let em = 0
  for (const c of text) {
    if (c === ' ') em += 0.28
    else if (/[il.,:;'|!·]/.test(c)) em += 0.28
    else if (/[frtjI()[\]-]/.test(c)) em += 0.38
    else if (/[mwMW@]/.test(c)) em += 0.86
    else if (/[0-9]/.test(c)) em += 0.6
    else if (/[A-Z]/.test(c)) em += 0.68
    else if (c.charCodeAt(0) > 0x2e80) em += 1
    else em += 0.55
  }
  return em * FONT_PX[font] * BOLD[font]
}

// ---- calendar -----------------------------------------------------------------------

export const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'] as const
export const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'] as const
const DAY_MS = 86_400_000

const parts = (day: number) => {
  const d = new Date(day * DAY_MS)
  return { y: d.getUTCFullYear(), m: d.getUTCMonth(), d: d.getUTCDate(), wd: d.getUTCDay() }
}
const dayFrom = (y: number, m: number, d: number) => Math.round(Date.UTC(y, m, d) / DAY_MS)

/** "Oct 14". */
export const shortDate = (day: number) => {
  const p = parts(day)
  return `${MONTHS[p.m]} ${p.d}`
}
/** "Tue, Oct 14". */
export const dayName = (day: number) => {
  const p = parts(day)
  return `${WEEKDAYS[p.wd]}, ${MONTHS[p.m]} ${p.d}`
}
/** "Oct 1 – Dec 31, 2026"; "Dec 1, 2026 – Jan 31, 2027"; "Oct 14, 2026" for one day. */
export function spanText(a: number, b: number): string {
  const p = parts(a)
  const q = parts(b)
  if (a === b) return `${MONTHS[p.m]} ${p.d}, ${p.y}`
  if (p.y === q.y) return `${MONTHS[p.m]} ${p.d} – ${MONTHS[q.m]} ${q.d}, ${q.y}`
  return `${MONTHS[p.m]} ${p.d}, ${p.y} – ${MONTHS[q.m]} ${q.d}, ${q.y}`
}
/** "Oct 20 – Nov 3 · 15 days". */
export const sectionReadout = (a: number, b: number) => {
  const n = Math.abs(b - a) + 1
  return `${a === b ? shortDate(a) : `${shortDate(Math.min(a, b))} – ${shortDate(Math.max(a, b))}`} · ${n} ${n === 1 ? 'day' : 'days'}`
}

const STEP_DAYS: Record<Step, number> = { day: 1, week: 7, month: 30.4, quarter: 91.3, year: 365.25 }
const COARSER: Partial<Record<Step, Step>> = { day: 'week', week: 'month', month: 'quarter', quarter: 'year' }
const MAX_TICKS = 1200

/** Step ticks: every day or week from the start; the first of each month, quarter or year. */
export function stepTicks(start: number, end: number, step: Step): number[] {
  const out: number[] = []
  if (step === 'day' || step === 'week') {
    const by = step === 'day' ? 1 : 7
    for (let d = start; d <= end && out.length < MAX_TICKS * 4; d += by) out.push(d)
    return out
  }
  const months = step === 'month' ? 1 : step === 'quarter' ? 3 : 12
  const p = parts(start)
  let y = p.y
  let m = p.m
  if (p.d !== 1 || m % months !== 0) {
    m = Math.floor(m / months) * months + months
    y += Math.floor(m / 12)
    m %= 12
  }
  for (let d = dayFrom(y, m, 1); d <= end && out.length < MAX_TICKS * 4; ) {
    out.push(d)
    m += months
    y += Math.floor(m / 12)
    m %= 12
    d = dayFrom(y, m, 1)
  }
  return out
}

// ---- the layout -------------------------------------------------------------------------

export interface LayoutItem {
  index: number
  date: string
  end: string | null
  label: string
  color: ItemColor | null
  body: string | null
  kind: ItemKind
}

export interface LayoutInput {
  start: string
  end: string
  step: Step
  items: readonly LayoutItem[]
  /** The card's box. */
  w: number
  h: number
  /** Today (ISO) for its marker; none when absent. */
  today?: string | null
  measure?: Measure
}

export interface Tick {
  day: number
  x: number
  /** A labelled or boundary tick (drawn a little stronger). */
  major: boolean
  /** The step's own tick (not the range's ragged start or end). */
  step: boolean
  dot: boolean
  label: string | null
  /** Where the label's middle sits (kept inside the card). */
  labelX: number
  /** The context under the label: a month or a year. */
  sub: string | null
  subX: number
}

export interface SectionBox {
  item: LayoutItem
  lane: number
  x: number
  w: number
  y: number
  h: number
  /** The section runs on past the range's start / end. */
  openLeft: boolean
  openRight: boolean
}

export interface Box {
  x: number
  y: number
  w: number
  h: number
}

export interface PinBox {
  item: LayoutItem
  /** The stem's x: the day's middle. */
  x: number
  side: 'above' | 'below'
  tier: number
  box: Box
  /** A bubble's body lines shown, and whether it was cut. */
  lines: number
  clamped: boolean
}

export interface TimelineLayout {
  w: number
  /** The height the card is drawn at: its own, or what its content needs if more. */
  h: number
  /** The least height this content needs at this width (the card is never drawn shorter). */
  needed: number
  startDay: number
  endDay: number
  step: Step
  x0: number
  x1: number
  cellW: number
  axisY: number
  labelsY: number
  /** The tick labels have a context row under them. */
  subRow: boolean
  lanesY: number
  lanes: number
  ticks: Tick[]
  sections: SectionBox[]
  pins: PinBox[]
  /** Today's x, when it falls in the range. */
  today: number | null
  /** Items wholly outside the range (kept, not drawn). */
  outside: number
}

/** The x of a day's middle. */
export const dayX = (l: Pick<TimelineLayout, 'x0' | 'cellW' | 'startDay'>, day: number) => l.x0 + (day - l.startDay + 0.5) * l.cellW

/** The day under an x (clamped to the range). */
export function dayAtX(l: Pick<TimelineLayout, 'x0' | 'cellW' | 'startDay' | 'endDay'>, x: number): number {
  const i = Math.floor((x - l.x0) / l.cellW)
  return Math.min(l.endDay, Math.max(l.startDay, l.startDay + i))
}

interface Sized {
  item: LayoutItem
  x: number
  w: number
  h: number
  lines: number
  clamped: boolean
}

/** A pin's box size: a chip for a note, a card for a bubble. */
function sizeOf(item: LayoutItem, x: number, cardW: number, measure: Measure): Sized {
  const room = Math.max(40, cardW - TL.edge * 2)
  if (item.kind !== 'bubble') {
    const label = item.label.trim()
    const w = label ? Math.min(TL.chipMax, room, Math.ceil(measure(label, 'chip') + TL.chipPadX * 2 + 2)) : 0
    return { item, x, w, h: label ? TL.chipH : 0, lines: 0, clamped: false }
  }
  const label = item.label.trim()
  // What a line shows: its words, without the markup around them (a list item keeps room for its bullet).
  const raw = (item.body ?? '').split('\n')
  const body = raw.map(plainLine)
  let widest = label ? measure(label, 'bubbleTitle') : 0
  for (const line of body) widest = Math.max(widest, measure(line, 'bubbleBody'))
  const w = Math.min(room, Math.max(TL.bubbleMin, Math.min(TL.bubbleMax, Math.ceil(widest + TL.bubblePadX * 2 + 6))))
  const inner = w - TL.bubblePadX * 2 - 2
  let lines = 0
  for (const line of raw) {
    // Blank lines between paragraphs take no row (the body is drawn without gaps).
    if (!plainLine(line).trim()) continue
    lines += wrappedLines(line, Math.max(20, inner), measure)
  }
  const shown = Math.min(lines, TL.bubbleLines)
  const h = TL.bubblePadY * 2 + (label || !shown ? TL.bubbleTitle : 0) + shown * TL.bubbleLine
  return { item, x, w, h, lines: shown, clamped: lines > TL.bubbleLines }
}

/** A body line as it reads: no emphasis marks or link targets; a bullet's indent kept. */
function plainLine(line: string): string {
  return line
    .replace(/^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/, '    ')
    .replace(/^\s*#{1,3}\s+/, '')
    .replace(/^\s*>\s?/, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/(\*\*|__|\*|_|~~|`)/g, '')
}

/**
 * Rows a body line takes at `width`, wrapped word by word the way the page
 * wraps it (bold words measured bold), so a bubble is never cut short.
 */
function wrappedLines(line: string, width: number, measure: Measure): number {
  const lead = /^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/.exec(line)
  const indent = lead ? measure('    ', 'bubbleBody') : 0
  const words = line.slice(lead ? lead[0].length : 0).replace(/^\s*(?:#{1,3}|>)\s?/, '').split(/\s+/).filter(Boolean)
  const space = measure(' ', 'bubbleBody')
  let rows = 1
  let at = indent
  let bold = false
  for (const word of words) {
    const marks = (word.match(/\*\*|__/g) ?? []).length
    const shown = word.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/(\*\*|__|\*|_|~~|`)/g, '')
    const w = measure(shown, bold || marks > 0 ? 'bubbleTitle' : 'bubbleBody')
    if (marks % 2) bold = !bold
    const next = at > indent ? at + space + w : at + w
    if (next > width && at > indent) {
      rows++
      // A word wider than the row breaks where it must.
      at = indent + w
      while (at > width) {
        rows++
        at -= width - indent
      }
    } else at = next
  }
  return rows
}

interface Placed extends Sized {
  tier: number
  bx: number
}

/** Allowed positions minus forbidden open intervals → the point nearest `ideal`. */
function nearestFree(lo: number, hi: number, forbidden: [number, number][], ideal: number): number | null {
  if (hi < lo) return null
  let free: [number, number][] = [[lo, hi]]
  for (const [a, b] of forbidden) {
    const next: [number, number][] = []
    for (const [p, q] of free) {
      if (b <= p || a >= q) {
        next.push([p, q])
        continue
      }
      if (a > p) next.push([p, a])
      if (b < q) next.push([b, q])
    }
    free = next
    if (!free.length) return null
  }
  let best: number | null = null
  for (const [p, q] of free) {
    const c = Math.min(q, Math.max(p, ideal))
    if (best === null || Math.abs(c - ideal) < Math.abs(best - ideal)) best = c
  }
  return best
}

/**
 * Pack pins into tiers, nearest the axis first. A pin takes the lowest tier
 * where its box fits beside the others there and its stem clears the boxes
 * of the tiers it passes; a box in the way is nudged aside when it can be.
 * Should a stem find no clear way at all (two pins on one day), it runs
 * behind the box below it, which then reads as a stack on that day.
 */
function pack(list: Sized[], cardW: number): Placed[] {
  const placed: Placed[] = []
  const inset = (s: Sized) => Math.min(TL.stemInset, s.w / 2)
  const lo = (s: Sized) => Math.max(TL.edge, s.x - s.w + inset(s))
  const hi = (s: Sized) => Math.min(cardW - TL.edge - s.w, s.x - inset(s))
  /** Where `p` can sit in `tier`, keeping clear of everyone but `skip`. */
  const spot = (p: Sized, tier: number, skip: Placed | null, extraStems: number[] = []): number | null => {
    const forbidden: [number, number][] = []
    for (const q of placed) {
      if (q === skip) continue
      if (q.tier === tier && q.w > 0) forbidden.push([q.bx - TL.boxGap - p.w, q.bx + q.w + TL.boxGap])
      if (q.tier > tier) forbidden.push([q.x - p.w - TL.stemClear, q.x + TL.stemClear])
    }
    for (const s of extraStems) forbidden.push([s - p.w - TL.stemClear, s + TL.stemClear])
    return nearestFree(lo(p), hi(p), forbidden, p.x - p.w / 2)
  }
  const blocks = (q: Placed, x: number) => q.w > 0 && x > q.bx - TL.stemClear && x < q.bx + q.w + TL.stemClear
  /** The lowest tier where `p` fits and its stem runs clear (nudging boxes in its way); false when none. */
  const tryPlace = (p: Sized): boolean => {
    const top = placed.reduce((t, q) => Math.max(t, q.tier), -1) + 1
    for (let tier = 0; tier <= top; tier++) {
      const bx = spot(p, tier, null)
      if (bx === null) continue
      // The stem passes the tiers below: each box in its way must step aside.
      const inWay = placed.filter(q => q.tier >= 0 && q.tier < tier && blocks(q, p.x))
      const moves: [Placed, number][] = []
      let clear = true
      for (const q of inWay) {
        const nx = spot(q, q.tier, q, [p.x])
        if (nx === null) {
          clear = false
          break
        }
        moves.push([q, nx])
      }
      if (!clear) continue
      for (const [q, nx] of moves) q.bx = nx
      placed.push({ ...p, tier, bx })
      return true
    }
    return false
  }
  const sorted = [...list].sort((a, b) => a.x - b.x || a.item.index - b.item.index)
  for (const p of sorted) {
    if (p.w === 0) {
      // A bare dot (no label): nothing to place above the axis.
      placed.push({ ...p, tier: -1, bx: p.x })
      continue
    }
    if (tryPlace(p)) continue
    // A box in the way could not step aside (the card's edge): let it go up
    // instead, over this one, if both then run clear.
    let done = false
    const inWay = placed.filter(q => q.tier >= 0 && blocks(q, p.x)).sort((a, b) => a.tier - b.tier)
    for (const q of inWay) {
      const saved = placed.map(o => [o, o.tier, o.bx] as const)
      placed.splice(placed.indexOf(q), 1)
      const { tier: _t, bx: _b, ...lifted } = q
      if (tryPlace(p) && tryPlace(lifted)) {
        done = true
        break
      }
      placed.length = 0
      for (const [o, tier, bx] of saved) {
        o.tier = tier
        o.bx = bx
        placed.push(o)
      }
    }
    if (done) continue
    // No clear way up (two pins on one day): the lowest tier with room, the stem behind the box below.
    for (let tier = 0; ; tier++) {
      const forbidden: [number, number][] = placed.filter(q => q.tier === tier && q.w > 0).map(q => [q.bx - TL.boxGap - p.w, q.bx + q.w + TL.boxGap])
      const bx = nearestFree(lo(p), hi(p), forbidden, p.x - p.w / 2)
      if (bx === null) continue
      placed.push({ ...p, tier, bx })
      break
    }
  }
  return placed
}

/** Each tier's height (its tallest box). */
function tierHeights(placed: readonly Placed[]): number[] {
  const out: number[] = []
  for (const p of placed) if (p.tier >= 0) out[p.tier] = Math.max(out[p.tier] ?? 0, p.h)
  for (let i = 0; i < out.length; i++) out[i] ??= 0
  return out
}

const stackH = (heights: readonly number[], gap: number) => heights.reduce((s, h) => s + h, 0) + gap * Math.max(0, heights.length - 1)

const STRIDES = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256]

/** Lay a timeline card out. */
export function layoutTimeline(input: LayoutInput): TimelineLayout {
  const measure = input.measure ?? estimateWidth
  const w = Math.max(1, input.w)
  let startDay = dayOf(input.start) ?? 0
  let endDay = dayOf(input.end) ?? startDay
  if (endDay < startDay) [startDay, endDay] = [endDay, startDay]
  const cells = endDay - startDay + 1
  const x0 = TL.padX
  const x1 = Math.max(x0 + 1, w - TL.padX)
  const cellW = (x1 - x0) / cells
  const geo = { x0, cellW, startDay, endDay }
  const xOf = (day: number) => dayX(geo, day)

  // ---- ticks and their labels ----
  let step = input.step ?? DEFAULT_STEP
  let days = stepTicks(startDay, endDay, step)
  // Far too many for the width: a coarser step draws them (the text keeps its own).
  while (days.length > Math.max(8, (x1 - x0) / 3) && COARSER[step]) {
    step = COARSER[step]!
    days = stepTicks(startDay, endDay, step)
  }
  const stepLen = STEP_DAYS[step]
  const ticks: Tick[] = days.map(day => ({ day, x: xOf(day), major: false, step: true, dot: true, label: null, labelX: xOf(day), sub: null, subX: xOf(day) }))
  // The range's own ends, where the step's ticks leave them bare.
  const edges: Tick[] = []
  const near = (day: number) => ticks.some(t => Math.abs(t.day - day) < Math.max(1, stepLen * 0.4))
  if (!ticks.some(t => t.day === startDay) && !near(startDay)) edges.push({ day: startDay, x: xOf(startDay), major: false, step: false, dot: true, label: null, labelX: xOf(startDay), sub: null, subX: xOf(startDay) })
  if (endDay !== startDay && !ticks.some(t => t.day === endDay) && !near(endDay)) edges.push({ day: endDay, x: xOf(endDay), major: false, step: false, dot: true, label: null, labelX: xOf(endDay), sub: null, subX: xOf(endDay) })
  const primary = (t: Tick) => {
    const p = parts(t.day)
    if (!t.step) return `${MONTHS[p.m]} ${p.d}`
    switch (step) {
      case 'day':
        return String(p.d)
      case 'week':
        return `${MONTHS[p.m]} ${p.d}`
      case 'month':
        return MONTHS[p.m]!
      case 'quarter':
        return `Q${Math.floor(p.m / 3) + 1}`
      case 'year':
        return String(p.y)
    }
  }
  const half = (s: string, font: Font) => measure(s, font) / 2
  const clampLabel = (x: number, hw: number) => Math.min(w - 6 - hw, Math.max(6 + hw, x))
  const fits = (list: { x: number; hw: number }[]) => {
    const sorted = [...list].sort((a, b) => a.x - b.x)
    for (let i = 1; i < sorted.length; i++) if (sorted[i]!.x - sorted[i]!.hw - (sorted[i - 1]!.x + sorted[i - 1]!.hw) < 10) return false
    return true
  }
  const texts = ticks.map(primary)
  let stride = STRIDES[STRIDES.length - 1]!
  for (const s of STRIDES) {
    const list = ticks.filter((_, i) => i % s === 0).map(t => {
      const hw = half(texts[ticks.indexOf(t)]!, 'tick')
      return { x: clampLabel(t.x, hw), hw }
    })
    if (fits(list)) {
      stride = s
      break
    }
  }
  const labelled: { x: number; hw: number }[] = []
  ticks.forEach((t, i) => {
    if (i % stride !== 0) return
    const hw = half(texts[i]!, 'tick')
    t.label = texts[i]!
    t.labelX = clampLabel(t.x, hw)
    t.major = true
    labelled.push({ x: t.labelX, hw })
  })
  for (const e of edges) {
    const text = primary(e)
    const hw = half(text, 'tick')
    const at = clampLabel(e.x, hw)
    if (fits([...labelled, { x: at, hw }])) {
      e.label = text
      e.labelX = at
      e.major = true
      labelled.push({ x: at, hw })
    }
  }
  const all = [...ticks, ...edges].sort((a, b) => a.day - b.day)
  // Dots: every step's, unless they would crowd into a smear; then the labelled ones.
  const minGap = ticks.length > 1 ? (ticks[1]!.x - ticks[0]!.x) : Infinity
  if (minGap < 6) for (const t of all) t.dot = !!t.label
  // The context row: the month (daily) or the year (weekly … quarterly) where it starts or changes.
  const crosses = parts(startDay).y !== parts(endDay).y
  const subOf = (t: Tick, prev: Tick | null): string | null => {
    const p = parts(t.day)
    const q = prev ? parts(prev.day) : null
    if (step === 'day') {
      if (!q) return MONTHS[p.m]!
      if (q.y !== p.y) return `${MONTHS[p.m]} ${p.y}`
      return q.m !== p.m ? MONTHS[p.m]! : null
    }
    if (step === 'year' || !crosses) return null
    return !q || q.y !== p.y ? String(p.y) : null
  }
  let prev: Tick | null = null
  const subs: { x: number; hw: number }[] = []
  for (const t of all) {
    if (!t.label) continue
    const sub = subOf(t, prev)
    prev = t
    if (!sub) continue
    const hw = half(sub, 'tickStrong')
    const at = clampLabel(t.x, hw)
    if (!fits([...subs, { x: at, hw }])) continue
    t.sub = sub
    t.subX = at
    subs.push({ x: at, hw })
  }
  const subRow = subs.length > 0

  // ---- sections in lanes ----
  const sections: SectionBox[] = []
  let outside = 0
  const laneEnds: number[] = []
  const spans = input.items
    .filter(it => it.kind === 'section')
    .map(it => ({ it, a: dayOf(it.date) ?? 0, b: dayOf(it.end ?? it.date) ?? 0 }))
    .sort((p, q) => p.a - q.a || q.b - q.a - (p.b - p.a) || p.it.index - q.it.index)
  for (const { it, a, b } of spans) {
    if (b < startDay || a > endDay) {
      outside++
      continue
    }
    const ca = Math.max(a, startDay)
    const cb = Math.min(b, endDay)
    let lane = laneEnds.findIndex(e => e < ca)
    if (lane < 0) lane = laneEnds.length
    laneEnds[lane] = cb
    const left = x0 + (ca - startDay) * cellW
    const right = x0 + (cb - startDay + 1) * cellW
    sections.push({ item: it, lane, x: left + 1, w: Math.max(4, right - left - 2), y: 0, h: TL.lane, openLeft: a < startDay, openRight: b > endDay })
  }
  const lanes = laneEnds.length

  // ---- pins ----
  const sized: Sized[] = []
  for (const it of input.items) {
    if (it.kind === 'section') continue
    const d = dayOf(it.date)
    if (d === null || d < startDay || d > endDay) {
      outside++
      continue
    }
    sized.push(sizeOf(it, xOf(d), w, measure))
  }

  // ---- heights: tiers above up to a cap, the rest below; the card's spare room around them ----
  const labelBlock = TL.labelGap + TL.labelH + (subRow ? TL.subH : 0)
  const laneBlock = lanes ? TL.lanesGap + lanes * TL.lane + (lanes - 1) * TL.laneGap : 0
  const above = pack(sized, w)
  const heights = tierHeights(above)
  // The first tier always sits above, however tall; then tiers while they fit under the cap.
  let k = Math.min(1, heights.length)
  while (k < heights.length && stackH(heights.slice(0, k + 1), TL.tierGap) <= TL.aboveMax) k++
  const rest = above.filter(p => p.tier >= k)
  const down = rest.length ? pack(rest.map(({ tier: _t, bx: _b, ...s }) => s), w) : []
  const downH = tierHeights(down)
  const upPx = Math.max(TL.minAbove, k ? stackH(heights.slice(0, k), TL.tierGap) + TL.stem : 0)
  const downPx = downH.length ? TL.belowGap + TL.stem + stackH(downH, TL.tierGap) : 0
  const needed = TL.head + TL.padTop + upPx + labelBlock + laneBlock + downPx + TL.padBottom
  const h = Math.max(input.h, needed)
  // Spare room: two parts over the content to one under it, so the axis rides a little low.
  const spare = h - needed
  const axisY = Math.round(TL.head + TL.padTop + upPx + (spare * 2) / 3)
  const labelsY = axisY + TL.labelGap
  const lanesY = labelsY + TL.labelH + (subRow ? TL.subH : 0) + TL.lanesGap
  for (const s of sections) s.y = lanesY + s.lane * (TL.lane + TL.laneGap)

  const pins: PinBox[] = []
  // Above: tier 0's baseline a stem's length over the axis; each tier on top of the last.
  const baseAbove: number[] = []
  let yb = axisY - TL.stem
  for (let t = 0; t < k; t++) {
    baseAbove[t] = yb
    yb -= (heights[t] ?? 0) + TL.tierGap
  }
  for (const p of above) {
    if (p.tier < 0) {
      pins.push({ item: p.item, x: p.x, side: 'above', tier: -1, box: { x: p.x, y: axisY, w: 0, h: 0 }, lines: 0, clamped: false })
      continue
    }
    if (p.tier >= k) continue
    pins.push({ item: p.item, x: p.x, side: 'above', tier: p.tier, box: { x: p.bx, y: baseAbove[p.tier]! - p.h, w: p.w, h: p.h }, lines: p.lines, clamped: p.clamped })
  }
  // Below: past the labels and the lanes, each tier under the last.
  let yt = axisY + labelBlock + laneBlock + TL.belowGap + TL.stem
  const topBelow: number[] = []
  for (let t = 0; t < downH.length; t++) {
    topBelow[t] = yt
    yt += (downH[t] ?? 0) + TL.tierGap
  }
  for (const p of down) {
    if (p.tier < 0) continue
    pins.push({ item: p.item, x: p.x, side: 'below', tier: p.tier, box: { x: p.bx, y: topBelow[p.tier]!, w: p.w, h: p.h }, lines: p.lines, clamped: p.clamped })
  }
  pins.sort((a, b) => a.item.index - b.item.index)

  const today = input.today ? dayOf(input.today) : null
  return {
    w,
    h,
    needed,
    startDay,
    endDay,
    step,
    x0,
    x1,
    cellW,
    axisY,
    labelsY,
    subRow,
    lanesY,
    lanes,
    ticks: all,
    sections,
    pins,
    today: today !== null && today >= startDay && today <= endDay ? xOf(today) : null,
    outside,
  }
}

/** The day a section or pin covers, as day numbers. */
export const itemDays = (it: { date: string; end: string | null }) => {
  const a = dayOf(it.date) ?? 0
  return { a, b: it.end ? (dayOf(it.end) ?? a) : a }
}

export { isoOf }
