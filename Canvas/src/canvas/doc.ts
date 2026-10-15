/**
 * One canvas document: the Y.Doc, its maps, tolerant reads, the mutations the
 * board and the ops share, and an undo manager scoped to `shapes` (comment
 * threads, `comments.ts`, live beside them and are never undone).
 */
import * as Y from 'yjs'
import { readColumns, readNoteChecklist, readNotes, readPicks, readRows } from './checklist'
import { VIEW_CHECKLIST } from './checklist-text'
import { CommentStore } from './comments'
import { SIDES, type Point, type Side } from './geometry'
import { textSplice } from './text-diff'
import { VIEW_TIMELINE, readNoteTimeline } from './timeline'
import {
  DEFAULT_COLOR,
  SHAPE_SIZE,
  isShapeColor,
  isShapeType,
  type Endpoint,
  type ImageRef,
  type Shape,
  type ShapeType,
  type TextAlign,
} from './types'

/** Transaction origins. Only `LOCAL` (and `null`) and `AGENT` are undoable. */
export const LOCAL = 'local'
export const AGENT = 'agent'
/** Updates the host hands us (stored or relayed): never echoed back, never undone. */
export const HOST = 'host'
/** Agent presence writes: synced and stored, but not part of undo. */
export const PRESENCE = 'presence'
/** Bookkeeping the page writes on its own (canvas meta). */
export const INIT = 'init'
/** A board brought over from Easels (`importLegacy`): stored and synced, never undone. */
export const IMPORT = 'import'
/**
 * A live frame's page changed under the person using it (`frames.ts`): synced
 * and stored, never undone — ⌘Z after browsing should undo the last edit to
 * the board, not the last link clicked inside a site.
 */
export const FRAME = 'frame'

export type Origin = typeof LOCAL | typeof AGENT | typeof INIT | typeof PRESENCE | typeof IMPORT | typeof FRAME

/** Props a caller may set on a shape (everything but its id and type). */
export type ShapeProps = Partial<Omit<Shape, 'id' | 'type'>>
export type ShapeInput = { type: ShapeType; id?: string } & ShapeProps

const TEXT_KEYS = new Set(['text'])
/** Read-side only: a checklist's picks and comments live under their own keys, or in its text (`checklist.ts`). */
const DERIVED_KEYS = new Set(['picks', 'notes', 'timeline'])
/** A note in the checklist view reads its title and rows from its text: never stored as props. */
const NOTE_DERIVED = new Set(['title', 'rows'])
const ROUNDED = new Set(['x', 'y', 'w', 'h'])

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)
const num = (v: unknown, fallback: number) => (finite(v) ? v : fallback)
const str = (v: unknown): string | undefined =>
  typeof v === 'string' ? v : v instanceof Y.Text ? v.toString() : undefined

const plain = (v: unknown): Record<string, unknown> | null => {
  if (v instanceof Y.Map) return v.toJSON() as Record<string, unknown>
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}

const isSide = (v: unknown): v is Side => typeof v === 'string' && (SIDES as readonly string[]).includes(v)

/** Strip a `shape:` prefix some callers put on refs. */
export const bareId = (ref: string) => (ref.startsWith('shape:') ? ref.slice(6) : ref)

/**
 * An endpoint in any accepted spelling — `{x,y}`, `{ref, side?}`, `"id"` or
 * `"shape:id"` — or null when it is none of those.
 */
export function readEndpoint(v: unknown): Endpoint | null {
  if (typeof v === 'string') return v.trim() ? { ref: bareId(v.trim()) } : null
  const o = plain(v)
  if (!o) return null
  if (typeof o.ref === 'string' && o.ref.trim()) {
    const ref = bareId(o.ref.trim())
    return isSide(o.side) ? { ref, side: o.side } : { ref }
  }
  if (typeof o.id === 'string' && o.id.trim()) {
    const ref = bareId(o.id.trim())
    return isSide(o.side) ? { ref, side: o.side } : { ref }
  }
  if (finite(o.x) && finite(o.y)) return { x: Math.round(o.x), y: Math.round(o.y) }
  return null
}

export function readImage(v: unknown): ImageRef | undefined {
  const o = plain(v)
  if (!o || typeof o.src !== 'string' || !o.src) return undefined
  return { src: o.src, naturalW: num(o.naturalW, 0), naturalH: num(o.naturalH, 0) }
}

/** Tolerant read: agents, servers and older clients may write partial shapes. */
export function readShape(id: string, m: unknown): Shape | null {
  if (!(m instanceof Y.Map)) return null
  const type = m.get('type')
  if (!isShapeType(type)) return null
  const color = m.get('color')
  const size = SHAPE_SIZE[type]
  const shape: Shape = {
    id,
    type,
    x: num(m.get('x'), 0),
    y: num(m.get('y'), 0),
    w: Math.max(0, num(m.get('w'), size.w)),
    h: Math.max(0, num(m.get('h'), size.h)),
    color: isShapeColor(color) ? color : DEFAULT_COLOR[type],
    createdAt: num(m.get('createdAt'), 0),
    updatedAt: num(m.get('updatedAt'), 0),
    z: num(m.get('z'), 0),
    text: str(m.get('text')) ?? '',
    title: str(m.get('title')) ?? '',
  }
  const by = str(m.get('by'))
  if (by) shape.by = by
  const fontSize = m.get('fontSize')
  if (finite(fontSize) && fontSize > 0) shape.fontSize = fontSize
  const align = m.get('align')
  if (align === 'left' || align === 'center' || align === 'right') shape.align = align as TextAlign
  if (type === 'frame') {
    const image = readImage(m.get('image'))
    if (image) shape.image = image
  }
  if (type === 'arrow') {
    const from = readEndpoint(m.get('from'))
    const to = readEndpoint(m.get('to'))
    if (from) shape.from = from
    if (to) shape.to = to
    shape.label = str(m.get('label')) ?? ''
  }
  if (type === 'image') {
    shape.src = str(m.get('src')) ?? ''
    shape.naturalW = num(m.get('naturalW'), shape.w)
    shape.naturalH = num(m.get('naturalH'), shape.h)
  }
  if (type === 'link') {
    shape.url = str(m.get('url')) ?? ''
    const favicon = str(m.get('favicon'))
    if (favicon) shape.favicon = favicon
    if (m.get('live') === true) shape.live = true
  }
  if (type === 'sticky' && m.get('view') === VIEW_CHECKLIST) {
    const list = readNoteChecklist(m, shape.text)
    shape.view = VIEW_CHECKLIST
    shape.title = list.title
    shape.columns = list.columns
    shape.rows = list.rows
    shape.picks = list.picks
    shape.notes = list.notes
  }
  if (type === 'sticky' && m.get('view') === VIEW_TIMELINE) {
    const { title, timeline } = readNoteTimeline(shape.text)
    shape.view = VIEW_TIMELINE
    shape.title = title
    shape.timeline = timeline
  }
  if (type === 'checklist') {
    const columns = readColumns(m.get('columns'))
    const rows = readRows(m.get('rows'))
    shape.columns = columns
    shape.rows = rows
    shape.picks = readPicks(m, rows, columns)
    shape.notes = readNotes(m, rows)
  }
  return shape
}

/** Value as it is stored: numbers for boxes rounded, endpoints normalised. */
function storeValue(key: string, value: unknown): unknown {
  if (ROUNDED.has(key) && finite(value)) return Math.round(value)
  if ((key === 'from' || key === 'to') && value !== undefined) return readEndpoint(value) ?? undefined
  if (key === 'image' && value && typeof value === 'object') {
    const image = readImage(value)
    return image ? { ...image } : undefined
  }
  return value
}

/** Whether a type keeps its body text in a Y.Text. */
const hasBody = (type: ShapeType) => type === 'sticky' || type === 'text'

export const newId = () =>
  typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`

type Listener = () => void

export class CanvasStore {
  readonly doc: Y.Doc
  readonly shapes: Y.Map<Y.Map<unknown>>
  readonly agents: Y.Map<unknown>
  readonly meta: Y.Map<unknown>
  /** Comment threads on shapes: their own top-level map, outside the undo manager's scope. */
  readonly comments: CommentStore
  readonly undo: Y.UndoManager
  private snapshot = new Map<string, Shape>()
  private listeners = new Set<Listener>()
  private observer: (events: Y.YEvent<Y.AbstractType<unknown>>[]) => void

  constructor(doc: Y.Doc) {
    this.doc = doc
    this.shapes = doc.getMap<Y.Map<unknown>>('shapes')
    this.agents = doc.getMap<unknown>('agents')
    this.meta = doc.getMap<unknown>('meta')
    this.comments = new CommentStore(doc)
    // `shapes` only: ⌘Z never takes back a comment (nor a comment a shape edit).
    this.undo = new Y.UndoManager([this.shapes], {
      captureTimeout: 500,
      trackedOrigins: new Set([null, LOCAL, AGENT]),
    })
    this.shapes.forEach((m, id) => {
      const shape = readShape(id, m)
      if (shape) this.snapshot.set(id, shape)
    })
    this.observer = events => {
      const changed = new Set<string>()
      for (const e of events) {
        if (e.target === this.shapes) for (const key of e.changes.keys.keys()) changed.add(key)
        else if (typeof e.path[0] === 'string') changed.add(e.path[0])
      }
      if (changed.size === 0) return
      const next = new Map(this.snapshot)
      for (const id of changed) {
        const shape = readShape(id, this.shapes.get(id))
        if (shape) next.set(id, shape)
        else next.delete(id)
      }
      this.snapshot = next
      for (const fn of this.listeners) fn()
    }
    this.shapes.observeDeep(this.observer)
  }

  destroy() {
    this.shapes.unobserveDeep(this.observer)
    this.comments.destroy()
    this.undo.destroy()
    this.listeners.clear()
  }

  /** Every readable shape; a new Map only when something changed. */
  getShapes = (): ReadonlyMap<string, Shape> => this.snapshot

  subscribe = (fn: Listener) => {
    this.listeners.add(fn)
    return () => {
      this.listeners.delete(fn)
    }
  }

  get(id: string): Shape | undefined {
    return this.snapshot.get(id) ?? readShape(id, this.shapes.get(id)) ?? undefined
  }

  /** Read straight from the doc (inside a transaction the snapshot lags). */
  live(id: string): Shape | null {
    return readShape(id, this.shapes.get(id))
  }

  liveAll(): Shape[] {
    const out: Shape[] = []
    this.shapes.forEach((m, id) => {
      const s = readShape(id, m)
      if (s) out.push(s)
    })
    return out
  }

  maxZ(): number {
    let z = 0
    this.shapes.forEach(m => {
      const v = m.get('z')
      if (finite(v) && v > z) z = v
    })
    return z
  }

  minZ(): number {
    let z = 0
    this.shapes.forEach(m => {
      const v = m.get('z')
      if (finite(v) && v < z) z = v
    })
    return z
  }

  transact(fn: () => void, origin: Origin = LOCAL) {
    this.doc.transact(fn, origin)
  }

  /** Add a shape; returns its id. Unset size/colour get the type's defaults. */
  create(input: ShapeInput, origin: Origin = LOCAL): string {
    const id = input.id && !this.shapes.has(input.id) ? input.id : newId()
    const { type, id: _ignored, text, ...props } = input
    void _ignored
    const now = Date.now()
    const full: Record<string, unknown> = {
      ...(type === 'arrow' ? { x: 0, y: 0, w: 0, h: 0 } : SHAPE_SIZE[type]),
      color: DEFAULT_COLOR[type],
      z: this.maxZ() + 1,
      createdAt: now,
      updatedAt: now,
      ...props,
    }
    this.transact(() => {
      const m = new Y.Map<unknown>()
      m.set('id', id)
      m.set('type', type)
      for (const [k, v] of Object.entries(full)) {
        if (TEXT_KEYS.has(k) || DERIVED_KEYS.has(k) || (type === 'sticky' && NOTE_DERIVED.has(k))) continue
        const value = storeValue(k, v)
        if (value !== undefined) m.set(k, value)
      }
      if (hasBody(type)) m.set('text', new Y.Text(text ?? ''))
      else if (typeof text === 'string' && text) m.set('text', text)
      this.shapes.set(id, m)
    }, origin)
    return id
  }

  /** Set only the given keys, so concurrent edits to other props survive. */
  update(id: string, patch: ShapeProps, origin: Origin = LOCAL, touch = true) {
    const m = this.shapes.get(id)
    if (!m) return
    const note = m.get('type') === 'sticky'
    this.transact(() => {
      for (const [k, v] of Object.entries(patch)) {
        if (v === undefined || DERIVED_KEYS.has(k) || (note && NOTE_DERIVED.has(k))) continue
        if (k === 'text' && typeof v === 'string') {
          this.spliceText(m, v)
          continue
        }
        if (k === 'image' && !v) {
          m.delete('image')
          continue
        }
        const value = storeValue(k, v)
        if (value === undefined) continue
        m.set(k, value)
      }
      if (touch) m.set('updatedAt', Date.now())
    }, origin)
  }

  /** Move many shapes in one transaction (one sync message). */
  moveMany(positions: Iterable<[string, Point | Record<string, unknown>]>, origin: Origin = LOCAL) {
    this.transact(() => {
      const now = Date.now()
      for (const [id, p] of positions) {
        const m = this.shapes.get(id)
        if (!m) continue
        for (const [k, v] of Object.entries(p)) {
          const value = storeValue(k, v)
          if (value !== undefined) m.set(k, value)
        }
        m.set('updatedAt', now)
      }
    }, origin)
  }

  private spliceText(m: Y.Map<unknown>, next: string) {
    let text = m.get('text')
    if (!(text instanceof Y.Text)) {
      const type = m.get('type')
      if (!isShapeType(type) || !hasBody(type)) {
        m.set('text', next)
        return
      }
      const t = new Y.Text(typeof text === 'string' ? text : '')
      m.set('text', t)
      text = t
    }
    const t = text as Y.Text
    const { index, remove, insert } = textSplice(t.toString(), next)
    if (remove) t.delete(index, remove)
    if (insert) t.insert(index, insert)
  }

  /** Replace a shape's body with the minimal splice, merging with peers. */
  setText(id: string, next: string, origin: Origin = LOCAL) {
    const m = this.shapes.get(id)
    if (!m) return
    this.transact(() => {
      this.spliceText(m, next)
      m.set('updatedAt', Date.now())
    }, origin)
  }

  /** Ids of arrows with an end on one of `ids`. */
  arrowsTouching(ids: Iterable<string>): string[] {
    const set = new Set(ids)
    const out: string[] = []
    this.shapes.forEach((m, id) => {
      if (m.get('type') !== 'arrow') return
      const from = readEndpoint(m.get('from'))
      const to = readEndpoint(m.get('to'))
      const hit = (e: Endpoint | null) => !!e && 'ref' in e && set.has(e.ref)
      if (hit(from) || hit(to)) out.push(id)
    })
    return out
  }

  /** Delete shapes and every arrow that ends on one of them, as one step. */
  remove(ids: Iterable<string>, origin: Origin = LOCAL): string[] {
    const list = [...ids].filter(id => this.shapes.has(id))
    if (list.length === 0) return []
    const cascade = this.arrowsTouching(list)
    const all = [...new Set([...list, ...cascade])]
    this.transact(() => {
      for (const id of all) this.shapes.delete(id)
    }, origin)
    return all
  }

  clear(origin: Origin = LOCAL) {
    this.transact(() => {
      for (const id of [...this.shapes.keys()]) this.shapes.delete(id)
    }, origin)
  }

  /** Raw JSON of a shape, for copy/paste and duplication. */
  toJSON(id: string): (ShapeInput & { id: string }) | null {
    const m = this.shapes.get(id)
    if (!m) return null
    const json = m.toJSON() as Record<string, unknown>
    if (!isShapeType(json.type)) return null
    return { ...(json as ShapeInput), id }
  }
}
