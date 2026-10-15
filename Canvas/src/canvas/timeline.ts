/**
 * The timeline card: a title, a date range with a step, and items along it —
 * notes (a date and a label), bubbles (a note with a markdown body) and
 * sections (a span of days, in a colour).
 *
 * Stored as a note (`type:"sticky"`, `view:"timeline"`) whose text is the
 * timeline, as markdown every Copper draws as a readable note — see
 * `timeline-text.ts` for the grammar. Nothing but `view` is a prop; the
 * title, range and items are all read from the text, so an older Copper
 * that edits the note as text edits the timeline.
 *
 * Every edit here re-reads the text inside its own transaction and finds its
 * item again by what it was (`ItemRef`), so an edit made against a view a
 * peer has since changed lands on the right line, or on none.
 */
import * as Y from 'yjs'
import type { CanvasStore, Origin } from './doc'
import {
  DEFAULT_STEP,
  VIEW_TIMELINE,
  addMonths,
  cleanIso,
  dayOf,
  insertItemLines,
  isoOf,
  kindOf,
  noteText,
  parseTimelineText,
  readItemColor,
  readStep,
  removeItemLines,
  replaceItems,
  todayIso,
  writeItem,
  writeRange,
  writeTitle,
  type ItemColor,
  type ItemFields,
  type ItemKind,
  type ParsedTimeline,
  type Step,
  type TextItem,
} from './timeline-text'
import { layoutTimeline, type Measure } from './timeline-layout'
import type { Shape } from './types'

export { VIEW_TIMELINE }

/** `doc.ts`'s LOCAL (a type-only import keeps the two modules out of a cycle). */
const LOCAL: Origin = 'local'

/** A new card's box (world px). */
export const TIMELINE_SIZE = { w: 880, h: 300 } as const
/** The least a card may be resized to; its content may need more height. */
export const TIMELINE_MIN = { w: 360, h: 160 } as const
/** Most items one card takes from an agent. */
export const MAX_ITEMS = 200

export interface TimelineItem {
  index: number
  date: string
  end: string | null
  label: string
  color: ItemColor | null
  body: string | null
  kind: ItemKind
}

export interface TimelineData {
  start: string
  end: string
  step: Step
  /** The text has its own range line (else the range is the items' span). */
  ranged: boolean
  items: TimelineItem[]
}

export const isTimeline = (s: Pick<Shape, 'type' | 'view'> | null | undefined): boolean => !!s && s.type === 'sticky' && s.view === VIEW_TIMELINE

const toItem = (it: TextItem): TimelineItem => ({
  index: it.index,
  date: it.date,
  end: it.end,
  label: it.label,
  color: it.color,
  body: it.body,
  kind: it.kind,
})

/** What a card draws from its text: the range (or the items' span, or the next three months) and the items. */
export function timelineOf(parsed: ParsedTimeline, today = todayIso()): TimelineData {
  const items = parsed.items.map(toItem)
  if (parsed.range) return { start: parsed.range.start, end: parsed.range.end, step: parsed.range.step, ranged: true, items }
  let lo: number | null = null
  let hi: number | null = null
  for (const it of items) {
    const a = dayOf(it.date)
    const b = dayOf(it.end ?? it.date)
    if (a === null || b === null) continue
    lo = lo === null ? a : Math.min(lo, a)
    hi = hi === null ? b : Math.max(hi, b)
  }
  if (lo === null || hi === null) return { start: today, end: addMonths(today, 3), step: DEFAULT_STEP, ranged: false, items }
  // A little room either side of the items' own span.
  const pad = Math.max(1, Math.round((hi - lo) * 0.05))
  return { start: isoOf(lo - pad), end: isoOf(hi + pad), step: DEFAULT_STEP, ranged: false, items }
}

/** The title and timeline of a note in the timeline view. */
export function readNoteTimeline(text: string): { title: string; timeline: TimelineData } {
  const parsed = parseTimelineText(text)
  return { title: parsed.title, timeline: timelineOf(parsed) }
}

// ---- measuring (the card's own font in a page; an estimate elsewhere) ---------------

let measurer: Measure | undefined

/** The board's text measurer: a canvas in a page, the layout's estimate in tests. */
export function timelineMeasure(): Measure | undefined {
  if (measurer !== undefined) return measurer
  if (typeof document === 'undefined') return undefined
  const ctx = document.createElement('canvas').getContext?.('2d')
  if (!ctx) return undefined
  const family = getComputedStyle(document.documentElement).getPropertyValue('--font-sans').trim() || '-apple-system, system-ui, sans-serif'
  const fonts = {
    tick: `500 11px ${family}`,
    tickStrong: `600 11px ${family}`,
    chip: `500 12px ${family}`,
    bubbleTitle: `600 12.5px ${family}`,
    bubbleBody: `400 12.5px ${family}`,
  } as const
  const cache = new Map<string, number>()
  measurer = (text, font) => {
    const key = `${font}\u0000${text}`
    let w = cache.get(key)
    if (w === undefined) {
      ctx.font = fonts[font]
      w = ctx.measureText(text).width
      if (cache.size > 4000) cache.clear()
      cache.set(key, w)
    }
    return w
  }
  return measurer
}

/** The least height a card with this text needs at width `w`. */
export function neededHeight(text: string, w: number, measure = timelineMeasure()): number {
  const { timeline } = readNoteTimeline(text)
  return layoutTimeline({ ...timeline, w, h: 0, measure }).needed
}

/** Grow the card (never shrink it) to what its text now needs. Inside the caller's transaction. */
function fitHeight(store: CanvasStore, id: string, origin: Origin) {
  const s = store.live(id)
  if (!s) return
  const need = Math.ceil(neededHeight(s.text, s.w))
  if (need > s.h) store.update(id, { h: need }, origin, false)
}

// ---- an item, as an edit names it ----------------------------------------------------

/** An item as the view saw it when an edit began: found again by these. */
export interface ItemRef {
  index: number
  date: string
  end: string | null
  label: string
}

export const refOf = (it: Pick<TimelineItem, 'index' | 'date' | 'end' | 'label'>): ItemRef => ({ index: it.index, date: it.date, end: it.end, label: it.label })

/** The item `ref` names in `parsed`: the one at its index if it still matches, else the first that does. */
export function findItem(parsed: ParsedTimeline, ref: ItemRef): TextItem | null {
  const same = (it: TextItem) => it.date === ref.date && it.end === ref.end && it.label === ref.label
  const at = parsed.items[ref.index]
  if (at && same(at)) return at
  return parsed.items.find(same) ?? null
}

/** An edit to one item: only the keys given change. */
export interface ItemPatch {
  date?: string
  /** A section's last day; null makes it a pin. */
  end?: string | null
  label?: string
  color?: ItemColor | null
  /** A bubble's body; null makes it a note. */
  body?: string | null
}

/** The item's fields after `patch` (a section's end never before its start). */
export function patched(it: Pick<TimelineItem, 'date' | 'end' | 'label' | 'color' | 'body'>, patch: ItemPatch): ItemFields {
  let date = patch.date ?? it.date
  let end = patch.end !== undefined ? patch.end : it.end
  if (end !== null && end < date) [date, end] = [end, date]
  return {
    date,
    end,
    label: patch.label ?? it.label,
    color: patch.color !== undefined ? patch.color : it.color,
    // A section has no body; a pin keeps its own unless the patch says.
    body: end !== null ? null : patch.body !== undefined ? patch.body : it.body,
  }
}

// ---- edits on the store (one undo step each) ---------------------------------------

function onText(store: CanvasStore, id: string, origin: Origin, fn: (t: Y.Text, parsed: ParsedTimeline) => void) {
  const m = store.shapes.get(id)
  if (!m) return
  store.transact(() => {
    const t = noteText(m)
    fn(t, parseTimelineText(t.toString()))
    m.set('updatedAt', Date.now())
    fitHeight(store, id, origin)
  }, origin)
}

export function setTimelineTitle(store: CanvasStore, id: string, title: string, origin: Origin = LOCAL) {
  onText(store, id, origin, (t, p) => writeTitle(t, p, title))
}

/** Start, end and step; the dates swap if they come the wrong way round. */
export function setRange(store: CanvasStore, id: string, range: { start?: string; end?: string; step?: Step }, origin: Origin = LOCAL) {
  onText(store, id, origin, (t, p) => {
    const now = timelineOf(p)
    let start = range.start ?? now.start
    let end = range.end ?? now.end
    if (end < start) [start, end] = [end, start]
    writeRange(t, p, start, end, range.step ?? now.step)
  })
}

/** Add an item where its date belongs; its index afterwards (-1 when the card is gone). */
export function addItem(store: CanvasStore, id: string, fields: ItemFields, origin: Origin = LOCAL): number {
  let index = -1
  onText(store, id, origin, (t, p) => {
    index = insertItemLines(t, p, fields)
  })
  return index
}

/** Change one item; its index afterwards, or -1 when it is gone. */
export function editItem(store: CanvasStore, id: string, ref: ItemRef, patch: ItemPatch, origin: Origin = LOCAL): number {
  let index = -1
  onText(store, id, origin, (t, p) => {
    const it = findItem(p, ref)
    if (!it) return
    index = writeItem(t, p, it, patched(it, patch))
  })
  return index
}

export function removeItem(store: CanvasStore, id: string, ref: ItemRef, origin: Origin = LOCAL): boolean {
  let done = false
  onText(store, id, origin, (t, p) => {
    const it = findItem(p, ref)
    if (!it) return
    removeItemLines(t, it)
    done = true
  })
  return done
}

/** Replace every item. */
export function setItems(store: CanvasStore, id: string, items: readonly ItemFields[], origin: Origin = LOCAL) {
  onText(store, id, origin, (t, p) => replaceItems(t, p, items))
}

// ---- what agents write ----------------------------------------------------------------

/** One item from an agent: `{date, end?, label?, text?, color?, kind?}`; throws on what cannot be one. */
export function readItemInput(v: unknown, where: string): ItemFields {
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error(`${where} must be an object with a date`)
  const o = v as Record<string, unknown>
  const date = cleanIso(o.date ?? o.start)
  if (!date) throw new Error(`${where}.date must be a YYYY-MM-DD date`)
  let end: string | null = null
  if (o.end !== undefined && o.end !== null && o.end !== '') {
    end = cleanIso(o.end)
    if (!end) throw new Error(`${where}.end must be a YYYY-MM-DD date`)
  }
  let lo = date
  if (end !== null && end < lo) [lo, end] = [end, lo]
  const label = typeof o.label === 'string' ? o.label : typeof o.title === 'string' ? o.title : ''
  const color = o.color === undefined || o.color === null || o.color === '' ? null : readItemColor(o.color)
  if (o.color !== undefined && o.color !== null && o.color !== '' && !color) throw new Error(`${where}.color must be yellow, pink, blue, green, purple or gray`)
  const said = o.text ?? o.body
  const body = end !== null ? null : typeof said === 'string' ? said : o.kind === 'bubble' ? '' : null
  return { date: lo, end, label, color, body }
}

export function readItemsInput(v: unknown, key: string): ItemFields[] {
  if (!Array.isArray(v)) throw new Error(`\`${key}\` must be a list of items`)
  if (v.length > MAX_ITEMS) throw new Error(`\`${key}\` takes at most ${MAX_ITEMS} items`)
  return v.map((it, i) => readItemInput(it, `${key}[${i}]`))
}

/** An agent's patch for one item (`{date?, end?, label?, text?, color?, kind?}`); throws on bad values. */
export function readItemPatch(v: unknown, where: string): ItemPatch {
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error(`${where} must be an object, or null to remove the item`)
  const o = v as Record<string, unknown>
  const patch: ItemPatch = {}
  if (o.date !== undefined) {
    const d = cleanIso(o.date)
    if (!d) throw new Error(`${where}.date must be a YYYY-MM-DD date`)
    patch.date = d
  }
  if (o.end !== undefined) {
    if (o.end === null || o.end === '') patch.end = null
    else {
      const d = cleanIso(o.end)
      if (!d) throw new Error(`${where}.end must be a YYYY-MM-DD date, or null`)
      patch.end = d
    }
  }
  if (o.label !== undefined) {
    if (typeof o.label !== 'string') throw new Error(`${where}.label must be text`)
    patch.label = o.label
  }
  if (o.color !== undefined) {
    if (o.color === null || o.color === '') patch.color = null
    else {
      const c = readItemColor(o.color)
      if (!c) throw new Error(`${where}.color must be yellow, pink, blue, green, purple, gray or null`)
      patch.color = c
    }
  }
  const said = o.text !== undefined ? o.text : o.body
  if (said !== undefined) {
    if (said !== null && typeof said !== 'string') throw new Error(`${where}.text must be text, or null`)
    patch.body = said
  }
  if (o.kind === 'bubble' && patch.body === undefined) patch.body = patch.body ?? ''
  if (o.kind === 'note') patch.body = null
  return patch
}

/**
 * The item an agent names: `"YYYY-MM-DD · label"`, a label (any case), or a
 * date (its first item); a number is an index.
 */
export function resolveItem(parsed: ParsedTimeline, ref: string): TextItem | null {
  const r = ref.trim()
  if (/^\d+$/.test(r)) return parsed.items[Number(r)] ?? null
  const low = r.toLowerCase()
  const dated = /^(\d{4}-\d{2}-\d{2})(?:\s*(?:→|->)\s*(\d{4}-\d{2}-\d{2}))?(?:\s*·\s*(.*))?$/.exec(r)
  if (dated) {
    const [, date, end, label] = dated
    const hit = parsed.items.find(it => it.date === date && (end === undefined || it.end === end) && (label === undefined || it.label.trim().toLowerCase() === label.trim().toLowerCase()))
    if (hit) return hit
  }
  return parsed.items.find(it => it.label.trim().toLowerCase() === low) ?? null
}

export interface TimelineEdits {
  title?: string
  start?: string
  end?: string
  step?: Step
  items?: ItemFields[]
  add?: ItemFields[]
  edit?: [string, ItemPatch | null][]
}

/**
 * An agent's edits on a timeline's text: title, range, then the whole list
 * or single items (changes and removals first, then additions). The refs
 * that name no item, in order; the rest still apply.
 */
export function applyTimelineEdits(t: Y.Text, e: TimelineEdits): string[] {
  const missing: string[] = []
  if (e.title !== undefined) writeTitle(t, parseTimelineText(t.toString()), e.title)
  if (e.start !== undefined || e.end !== undefined || e.step !== undefined) {
    const p = parseTimelineText(t.toString())
    const now = timelineOf(p)
    let start = e.start ?? now.start
    let end = e.end ?? now.end
    if (end < start) [start, end] = [end, start]
    writeRange(t, p, start, end, e.step ?? now.step)
  }
  if (e.items) replaceItems(t, parseTimelineText(t.toString()), e.items)
  for (const [ref, patch] of e.edit ?? []) {
    const p = parseTimelineText(t.toString())
    const it = resolveItem(p, ref)
    if (!it) {
      missing.push(ref)
      continue
    }
    if (patch === null) removeItemLines(t, it)
    else writeItem(t, p, it, patched(it, patch))
  }
  for (const it of e.add ?? []) insertItemLines(t, parseTimelineText(t.toString()), it)
  return missing
}

/** The refs in `e` that would name no item of `text` (tried on a copy). */
export function unresolvedRefs(text: string, e: TimelineEdits): string[] {
  if (!e.edit?.length) return []
  const t = new Y.Doc().getText('t')
  t.insert(0, text)
  return applyTimelineEdits(t, { ...e, add: undefined })
}

/** `applyTimelineEdits` on a card, in one transaction; the card grows to fit. */
export function writeTimeline(store: CanvasStore, id: string, e: TimelineEdits, origin: Origin): string[] {
  let missing: string[] = []
  const m = store.shapes.get(id)
  if (!m) return missing
  store.transact(() => {
    missing = applyTimelineEdits(noteText(m), e)
    m.set('updatedAt', Date.now())
    fitHeight(store, id, origin)
  }, origin)
  return missing
}

export const readStepInput = (v: unknown, key = 'step'): Step => {
  const s = readStep(v)
  if (!s) throw new Error(`\`${key}\` must be day, week, month, quarter or year`)
  return s
}

/** What `canvas_read` says of a timeline's items. */
export function summarizeItems(items: readonly TimelineItem[]) {
  return items.map(it => {
    const out: Record<string, unknown> = { date: it.date }
    if (it.end) out.end = it.end
    out.label = it.label
    if (it.body !== null) out.text = it.body
    if (it.color) out.color = it.color
    out.kind = it.kind
    return out
  })
}

/** A note's text to start a new card from the toolbar: today to three months out, weekly. */
export function newTimelineText(today = todayIso(), title = 'Timeline') {
  return `### ${title}\n${today} → ${addMonths(today, 3)} · weekly`
}

export { kindOf }
