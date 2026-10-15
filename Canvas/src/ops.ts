/**
 * Canvas ops and reads: the agent-facing contract, shared by the window API
 * (`copperCanvas.apply` / `copperCanvas.read`), and mirrored by the sync
 * server's own ops endpoint.
 *
 * apply: `{ops:[...], as?:{id,name,color}}` (or a bare array). Ops run in
 * order inside one transaction; a bad op is skipped and reported, the rest
 * still apply. Returns `{applied, ids, errors}` where `ids[i]` is the id op
 * `i` created or touched (null when it failed, or for `clear`).
 *
 *   {op:"add", shape:{type, id?, x?, y?, w?, h?, color?, …}}  // no x/y → free space near the viewport centre
 *   {op:"update", id, patch:{…}}                              // merges props
 *
 * A checklist (`checklist.ts`) takes `title`, `columns` (1–4, default Yes/No),
 * `rows` (labels or {label, id?}, ≤ 60), `picks` ({rowIdOrLabel: column |
 * true | null}), `notes` ({rowIdOrLabel: text | null}, a row's comment;
 * null clears it) and `assignees` ({rowIdOrLabel: [name | email | id, …] |
 * null}, who the row is assigned to — people on the canvas by name, email or
 * id, anyone else by a name of their own; null clears it) on add and update;
 * `rows` and `columns` replace the lists, rows keeping their picks, comments
 * and assignees by label.
 * An add makes a note in the checklist view (`type:"sticky"`, `view:"checklist"`,
 * the list in its text — `checklist-text.ts`), which older Coppers show and tick
 * as a note. `update {view:"checklist", columns?}` turns a note that holds a
 * heading and a task list into a card in place, its text (and ticks) untouched;
 * `view:null` makes it a plain note again. A legacy `type:"checklist"` shape
 * still updates as before.
 *
 * A timeline (`canvas/timeline.ts`) is a note in the timeline view too, its
 * text the timeline (`canvas/timeline-text.ts`). Add takes `title`, `start`,
 * `end` (YYYY-MM-DD), `step` (day|week|month|quarter|year; by the span when
 * omitted) and `items` ([{date, end?, label, text?, color?}]: a date alone is
 * a note, `text` makes it a bubble, `end` a section). Update takes the same,
 * `items` replacing the list, plus `addItems` and `editItems`
 * ({ref: patch | null}, null removes; a ref is "YYYY-MM-DD · label", a label,
 * a date, or an index). `view:"timeline"` / `view:null` convert in place.
 *   {op:"move", id, dx, dy}                                    // a frame carries what sits inside it
 *   {op:"resize", id, w, h}
 *   {op:"delete", id}                                          // arrows ending on it go too
 *   {op:"connect", from:id, to:id, label?, color?, fromSide?, toSide?}
 *   {op:"clear"}
 *
 * Comment threads (`canvas/comments.ts`), attributed to `as`:
 *   {op:"comment", on:shapeId, text, id?}                    // a new thread on a shape; ids[i] is the thread's id
 *   {op:"reply", thread, text}                               // add onto a thread (a resolved one opens again)
 *   {op:"resolve", thread, resolved?:true|false}             // resolve (default) or reopen
 */
import { arrowBox, arrowPath } from './canvas/arrows'
import { AGENT, bareId, readEndpoint, type CanvasStore, type ShapeInput, type ShapeProps } from './canvas/doc'
import {
  ASSIGNEES_PREFIX,
  CHECKLIST_LAYOUT,
  DEFAULT_COLUMNS,
  NOTE_BY_PREFIX,
  assigneesKey,
  checklistHeight,
  checklistWidth,
  cleanAssignees,
  cleanColumns,
  cleanNotes,
  cleanPicks,
  cleanRows,
  noteByKey,
  noteRowId,
  legacyAssigneesKey,
  mergeAssignees,
  noteAssignees,
  readAssigneeList,
  storedAssignee,
  readNoteColumns,
  summarizeChecklist,
  summarizeNoteChecklist,
  writeColumns,
  writeLegacyNote,
  writeNoteAssignees,
  writeNoteColumns,
  writeNoteNote,
  writeNotePick,
  writePick,
  writeRows,
  type Person,
  type Picker,
} from './canvas/checklist'
import {
  VIEW_CHECKLIST,
  WHO_PREFIX,
  checklistMarkdown,
  noteText,
  parseChecklistText,
  replaceRows,
  rowBlock,
  rowKey,
  whoKey,
  writeTitle,
} from './canvas/checklist-text'
import { liveAgents, readAgents } from './canvas/agents'
import { cleanCommentText, isShown, shapeLabel, type CommentAuthor } from './canvas/comments'
import { center, containsBox, boxesOverlap, SIDES, type Box, type Point, type Side } from './canvas/geometry'
import { MIN_SIZE, isResizable, minSizeOf } from './canvas/resize'
import {
  TIMELINE_MIN,
  TIMELINE_SIZE,
  VIEW_TIMELINE,
  neededHeight,
  readItemPatch,
  readItemsInput,
  readStepInput,
  summarizeItems,
  unresolvedRefs,
  writeTimeline,
  type ItemPatch,
  type TimelineEdits,
} from './canvas/timeline'
import { addMonths, cleanIso, dayOf, timelineMarkdown, todayIso, type ItemFields, type Step } from './canvas/timeline-text'
import { LIVE_SIZE, frameUrl } from './canvas/frames'
import { frameSizeFor, imageSizeFor, MAX_DATA_URL } from './canvas/images'
import { findFreeSpot, occupied } from './placement'
import {
  SHAPE_SIZE,
  isRefEndpoint,
  isShapeColor,
  isShapeType,
  type CanvasAgent,
  type ChecklistAssignee,
  type ChecklistRow,
  type Endpoint,
  type Shape,
  type ShapeType,
} from './canvas/types'

export const MAX_OPS = 500
const ID = /^[A-Za-z0-9_:.-]{1,64}$/
const MAX_TEXT = 20_000
const MAX_TITLE = 500

export interface Actor {
  id: string
  name: string
  color?: string
}

export interface OpError {
  index: number
  op: string
  error: string
}

export interface ApplyResult {
  applied: number
  ids: (string | null)[]
  errors: OpError[]
}

/** People an op assigned to a checklist row (only those new to it): the page tells them, as a chat mention would. */
export interface Assigned {
  shapeId: string
  title: string
  row: string
  people: ChecklistAssignee[]
}

export interface OpsContext {
  store: CanvasStore
  /** Where unplaced shapes go: the middle of what the user is looking at. */
  viewportCenter: () => Point
  readOnly?: boolean
  /** The people on the canvas, whom checklist `assignees` resolve against by name, email or id. */
  people?: () => readonly Person[]
  /** Someone was assigned to a checklist row. */
  onAssigned?: (event: Assigned) => void
}

export interface ParsedInput {
  ops: unknown[]
  as: Actor | null
}

class OpFailure extends Error {}
const fail = (message: string): never => {
  throw new OpFailure(message)
}

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)
const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)

/** `{ops, as?}`, a bare array, or either as a JSON string. */
export function parseApplyInput(raw: unknown): ParsedInput {
  let value = raw
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value)
    } catch {
      fail('ops are not valid JSON')
    }
  }
  if (Array.isArray(value)) return { ops: value, as: null }
  if (!isObject(value)) fail('expected {ops:[...], as?:{id,name,color}} or an array of ops')
  const obj = value as Record<string, unknown>
  if (!Array.isArray(obj.ops)) fail('`ops` must be an array')
  let as: Actor | null = null
  if (obj.as !== undefined && obj.as !== null) {
    if (typeof obj.as === 'string') as = { id: `agent:${obj.as}`, name: obj.as }
    else if (isObject(obj.as)) {
      const name = typeof obj.as.name === 'string' && obj.as.name.trim() ? obj.as.name.trim().slice(0, 60) : 'Agent'
      const id =
        typeof obj.as.id === 'string' && obj.as.id.trim() ? obj.as.id.trim().slice(0, 64) : `agent:${name.toLowerCase()}`
      as = { id, name }
      if (typeof obj.as.color === 'string' && obj.as.color) as.color = obj.as.color.slice(0, 32)
    } else fail('`as` must be {id,name,color}')
  }
  return { ops: obj.ops as unknown[], as }
}

// ---- prop validation ---------------------------------------------------------

const COMMON = ['x', 'y', 'w', 'h', 'color', 'z'] as const
const BY_TYPE: Record<ShapeType, readonly string[]> = {
  sticky: [...COMMON, 'text', 'fontSize'],
  text: [...COMMON, 'text', 'fontSize', 'align'],
  frame: [...COMMON, 'title', 'image'],
  arrow: ['color', 'z', 'from', 'to', 'label'],
  image: [...COMMON, 'src', 'naturalW', 'naturalH'],
  link: [...COMMON, 'url', 'title', 'favicon', 'live'],
  checklist: [...COMMON, 'title', 'columns', 'rows', 'picks', 'notes', 'assignees'],
}
/** Friendly spellings: `text` on a frame or link is its title, on an arrow its label. */
const ALIAS: Partial<Record<ShapeType, Record<string, string>>> = {
  frame: { text: 'title', label: 'title' },
  link: { text: 'title', label: 'title', embed: 'live' },
  arrow: { text: 'label', title: 'label' },
  sticky: { title: 'text' },
  text: { title: 'text' },
  checklist: { text: 'title', label: 'title' },
}
/** Accepted and dropped silently: the page owns these. */
const IGNORED = new Set(['id', 'type', 'by', 'createdAt', 'updatedAt'])

export function validImageSrc(src: unknown): string {
  if (typeof src !== 'string' || !src) return fail('`src` must be a data: or https: URL')
  if (src.startsWith('data:')) {
    if (!/^data:image\/[a-z0-9.+-]+[;,]/i.test(src)) fail('`src` data URL must be an image')
    if (src.length > MAX_DATA_URL) fail(`image data URL is over ${Math.round(MAX_DATA_URL / 1024 / 1024)} MB`)
    return src
  }
  if (/^https:\/\/\S+$/i.test(src)) return src
  return fail('`src` must be a data: or https: URL')
}

function validUrl(url: unknown): string {
  if (typeof url !== 'string' || !url.trim()) return fail('`url` must be a non-empty string')
  const trimmed = url.trim()
  let parsed: URL
  try {
    parsed = new URL(/^[a-z][a-z0-9+.-]*:/i.test(trimmed) ? trimmed : `https://${trimmed}`)
  } catch {
    return fail(`\`url\` is not a URL: ${trimmed.slice(0, 80)}`)
  }
  if (!['http:', 'https:', 'mailto:', 'copper:'].includes(parsed.protocol)) fail(`unsupported link scheme ${parsed.protocol}`)
  return parsed.toString()
}

/** Where a URL points, for a default link title. */
export function hostOf(url: string): string {
  try {
    const u = new URL(url)
    return u.hostname.replace(/^www\./, '') || url
  } catch {
    return url
  }
}

/**
 * The checked, normalised props a caller gave for a shape of `type`. Throws
 * an OpFailure naming the first bad prop.
 */
function cleanProps(type: ShapeType, raw: Record<string, unknown>, store: CanvasStore, selfId?: string): ShapeProps {
  const allowed = BY_TYPE[type]
  const out: Record<string, unknown> = {}
  for (const [rawKey, value] of Object.entries(raw)) {
    if (value === undefined) continue
    const key = ALIAS[type]?.[rawKey] ?? rawKey
    if (IGNORED.has(key)) continue
    if (!allowed.includes(key)) {
      if (type === 'arrow' && ['x', 'y', 'w', 'h'].includes(key))
        fail('arrows have no box of their own: set `from`/`to` (or move the shapes they join)')
      fail(`unknown prop \`${rawKey}\` for ${type} (allowed: ${allowed.join(', ')})`)
    }
    switch (key) {
      case 'x':
      case 'y':
      case 'z':
        if (!finite(value)) fail(`\`${key}\` must be a finite number`)
        out[key] = value
        break
      case 'w':
      case 'h':
        if (!finite(value) || value <= 0) fail(`\`${key}\` must be a positive number`)
        out[key] = value
        break
      case 'naturalW':
      case 'naturalH':
        if (!finite(value) || value < 0) fail(`\`${key}\` must be a non-negative number`)
        out[key] = value
        break
      case 'color':
        if (!isShapeColor(value))
          fail('`color` must be yellow, pink, blue, green, purple, gray, white or a #hex colour')
        out.color = value
        break
      case 'text':
        if (typeof value !== 'string') fail('`text` must be a string')
        if ((value as string).length > MAX_TEXT) fail(`\`text\` is over ${MAX_TEXT} characters`)
        out.text = value
        break
      case 'title':
      case 'label':
        if (typeof value !== 'string') fail(`\`${key}\` must be a string`)
        out[key] = (value as string).slice(0, MAX_TITLE)
        break
      case 'fontSize':
        if (!finite(value) || value < 6 || value > 240) fail('`fontSize` must be between 6 and 240')
        out.fontSize = value
        break
      case 'align':
        if (value !== 'left' && value !== 'center' && value !== 'right') fail('`align` must be left, center or right')
        out.align = value
        break
      case 'image': {
        if (value === null || value === '') {
          out.image = null
          break
        }
        if (typeof value === 'string') {
          out.image = { src: validImageSrc(value), naturalW: 0, naturalH: 0 }
          break
        }
        if (!isObject(value)) fail('`image` must be {src, naturalW, naturalH} or null')
        const img = value as Record<string, unknown>
        out.image = {
          src: validImageSrc(img.src),
          naturalW: finite(img.naturalW) ? img.naturalW : 0,
          naturalH: finite(img.naturalH) ? img.naturalH : 0,
        }
        break
      }
      case 'src':
        out.src = validImageSrc(value)
        break
      case 'url':
        out.url = validUrl(value)
        break
      case 'live':
        if (typeof value !== 'boolean') fail('`live` must be true or false')
        out.live = value
        break
      case 'favicon':
        if (typeof value !== 'string') fail('`favicon` must be a data: or https: URL')
        if (value) {
          if (!/^(data:image\/|https:\/\/)/i.test(value as string)) fail('`favicon` must be a data: or https: URL')
          if ((value as string).length > 256 * 1024) fail('`favicon` is over 256 KB')
        }
        out.favicon = value
        break
      case 'columns':
        out.columns = cleanColumns(value)
        break
      case 'rows':
        out.rows = cleanRows(value, (selfId && store.live(selfId)?.rows) || [])
        break
      case 'picks':
      case 'notes':
      case 'assignees':
        // Resolved against the final rows and columns by the op (`writeChecklist`, `updateChecklistNote`).
        break
      case 'from':
      case 'to': {
        const end = readEndpoint(value)
        if (!end) fail(`\`${key}\` must be a shape id, {ref, side?} or {x, y}`)
        checkEnd(end as Endpoint, store, key, selfId)
        out[key] = end
        break
      }
    }
  }
  return out as ShapeProps
}

/** The `picks` an add or update gave (by any alias), if any. */
function rawPicks(raw: Record<string, unknown>): unknown {
  return raw.picks
}

/**
 * Write a checklist's new rows and columns (dropping picks and comments they
 * orphan) and the op's `picks` and `notes`, all in the op's transaction.
 * Fresh lists also size the card, unless the op sized it.
 */
function writeChecklist(
  ctx: OpsContext,
  id: string,
  props: ShapeProps,
  picks: unknown,
  notes: unknown,
  assignees: unknown,
  as: Actor | null,
  sized: { w: boolean; h: boolean }
) {
  const m = ctx.store.shapes.get(id)
  if (!m) return
  const live = ctx.store.live(id)
  const rows: ChecklistRow[] = props.rows ?? live?.rows ?? []
  const columns: string[] = props.columns ?? live?.columns ?? [...DEFAULT_COLUMNS]
  const resolved = picks === undefined ? [] : cleanPicks(picks, rows, columns)
  const said = notes === undefined ? [] : cleanNotes(notes, rows)
  const people = assignees === undefined ? [] : cleanAssignees(assignees, rows, ctx.people?.() ?? [])
  if (props.columns) writeColumns(m, columns)
  if (props.rows) writeRows(m, rows)
  const by: Picker = { name: as?.name ?? 'Agent', id: as?.id ?? 'agent' }
  const now = Date.now()
  for (const [rowId, col] of resolved) writePick(m, rowId, col, by, now)
  for (const [rowId, text] of said) writeLegacyNote(m, rowId, text, by, now)
  for (const [rowId, next] of people) {
    const merged = mergeAssignees(readAssigneeList(m.get(legacyAssigneesKey(rowId))), next, by, now)
    if (merged.people.length) m.set(legacyAssigneesKey(rowId), merged.people.map(storedAssignee))
    else m.delete(legacyAssigneesKey(rowId))
    const label = rows.find(r => r.id === rowId)?.label ?? ''
    if (merged.added.length) ctx.onAssigned?.({ shapeId: id, title: (m.get('title') as string) ?? '', row: label, people: merged.added })
  }
  if (props.columns && !sized.w) m.set('w', Math.max(live?.w ?? 0, checklistWidth(columns.length)))
  if ((props.rows || props.columns) && !sized.h) m.set('h', checklistHeight(columns.length, rows.length))
}

// ---- a checklist kept as a note (checklist-text.ts) --------------------------------

const NOTE_LIST_KEYS = ['view', 'title', 'columns', 'rows', 'picks', 'notes', 'assignees'] as const

/** What an add or update said about a checklist note, checked; box props and text go through `cleanProps`. */
interface NoteListInput {
  props: ShapeProps
  view?: typeof VIEW_CHECKLIST | null
  title?: string
  columns?: string[]
  rows?: string[]
  picks?: unknown
  notes?: unknown
  assignees?: unknown
}

function cleanNoteList(type: 'sticky' | 'checklist', raw: Record<string, unknown>, store: CanvasStore, selfId?: string): NoteListInput {
  if (type === 'checklist') {
    // The checklist type's own names and spellings (`text` is its title).
    const props = cleanProps('checklist', raw, store, selfId)
    const { title, columns, rows, ...box } = props
    return { props: box, title, columns, rows: rows?.map(r => r.label), picks: raw.picks, notes: raw.notes, assignees: raw.assignees }
  }
  const rest: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(raw)) if (!(NOTE_LIST_KEYS as readonly string[]).includes(k)) rest[k] = v
  const out: NoteListInput = { props: cleanProps('sticky', rest, store, selfId) }
  if (raw.view !== undefined) {
    if (raw.view === VIEW_CHECKLIST) out.view = VIEW_CHECKLIST
    else if (raw.view === null || raw.view === false || raw.view === '' || raw.view === 'note') out.view = null
    else fail('`view` must be "checklist" or null')
  }
  if (raw.title !== undefined) {
    if (typeof raw.title !== 'string') fail('`title` must be a string')
    out.title = (raw.title as string).slice(0, MAX_TITLE)
  }
  if (raw.columns !== undefined) out.columns = cleanColumns(raw.columns)
  if (raw.rows !== undefined) out.rows = cleanRows(raw.rows).map(r => r.label)
  if (raw.picks !== undefined) out.picks = raw.picks
  if (raw.notes !== undefined) out.notes = raw.notes
  if (raw.assignees !== undefined) out.assignees = raw.assignees
  return out
}

const listRows = (labels: readonly string[]): ChecklistRow[] => labels.map((label, i) => ({ id: noteRowId(i), label }))
const pickerOf = (as: Actor | null): Picker => ({ name: as?.name ?? 'Agent', id: as?.id ?? 'agent' })

/** A new checklist: a note in the checklist view whose text is the list. */
function addChecklistNote(type: 'sticky' | 'checklist', raw: Record<string, unknown>, ctx: OpsContext, as: Actor | null, id: string | undefined) {
  const input = cleanNoteList(type, raw, ctx.store, id)
  if (input.view === null) fail('a checklist note needs `view:"checklist"`')
  const { props } = input
  const listed =
    type === 'checklist' ||
    input.rows !== undefined ||
    input.title !== undefined ||
    input.picks !== undefined ||
    input.notes !== undefined ||
    input.assignees !== undefined
  if (listed && props.text !== undefined && type === 'sticky') fail('give the note `text`, or `title`/`rows`/`picks`/`notes`/`assignees`, not both')
  const columns = input.columns ?? (type === 'checklist' ? [...DEFAULT_COLUMNS] : undefined)
  const cols = columns ?? readNoteColumns(undefined)
  let text = props.text ?? ''
  const parsedText = parseChecklistText(text, cols)
  let rowCount = parsedText.rows.length
  let noteCount = parsedText.rows.filter(r => r.note).length
  const picked: [string, string][] = []
  const noted: string[] = []
  const assigned: [string, ChecklistAssignee[]][] = []
  const by = pickerOf(as)
  const now = Date.now()
  if (listed) {
    const rows = listRows(input.rows ?? [])
    // Checked before anything is written: a bad pick, comment or assignee fails the whole add.
    const resolved = new Map(input.picks === undefined ? [] : cleanPicks(input.picks, rows, cols))
    const said = new Map(input.notes === undefined ? [] : cleanNotes(input.notes, rows))
    const people = new Map(input.assignees === undefined ? [] : cleanAssignees(input.assignees, rows, ctx.people?.() ?? []))
    for (const r of rows) {
      const list = mergeAssignees([], people.get(r.id) ?? [], by, now).people
      if (list.length) assigned.push([r.label, list])
    }
    const named = new Map(assigned)
    text = checklistMarkdown(
      input.title ?? '',
      rows.map(r => ({
        label: r.label,
        pick: resolved.get(r.id) ?? null,
        note: said.get(r.id) ?? '',
        assignees: (named.get(r.label) ?? []).map(p => p.name),
      })),
      cols
    )
    for (const r of rows) {
      const col = resolved.get(r.id)
      if (col) picked.push([r.label, col])
      if (said.get(r.id)) noted.push(r.label)
    }
    rowCount = rows.length
    noteCount = noted.length
  }
  const shape: ShapeInput = {
    ...props,
    type: 'sticky',
    view: VIEW_CHECKLIST,
    text,
    color: props.color ?? 'green',
    by: as?.name ?? 'Agent',
  }
  if (columns) shape.columns = columns
  if (id) shape.id = id
  const min = minSizeOf({ type: 'sticky', view: VIEW_CHECKLIST })
  const size = {
    w: Math.max(props.w ?? checklistWidth(cols.length), min.w),
    h: Math.max(props.h ?? checklistHeight(cols.length, rowCount, noteCount), min.h),
  }
  shape.w = size.w
  shape.h = size.h
  if (props.x === undefined || props.y === undefined) {
    const spot = findFreeSpot(boxesOf(ctx.store), size, ctx.viewportCenter(), { gap: 24, step: 32 })
    if (props.x === undefined) shape.x = spot.x
    if (props.y === undefined) shape.y = spot.y
  }
  const newId = ctx.store.create(shape, AGENT)
  const m = ctx.store.shapes.get(newId)
  if (m && (picked.length || noted.length || assigned.length)) {
    ctx.store.transact(() => {
      for (const [label, col] of picked) m.set(whoKey(label), { col, by: by.name, byId: by.id, at: now })
      for (const label of noted) m.set(noteByKey(label), { by: by.name, byId: by.id, at: now })
      for (const [label, list] of assigned) m.set(assigneesKey(label), list.map(storedAssignee))
    }, AGENT)
  }
  for (const [label, list] of assigned) ctx.onAssigned?.({ shapeId: newId, title: input.title ?? '', row: label, people: list })
  return { id: newId, anchor: center({ x: shape.x!, y: shape.y!, w: size.w, h: size.h }) }
}

/**
 * An update to a note that is (or is becoming) a checklist: box props and
 * `text` as for any note, then `view`, `columns`, `rows`, `title`, `picks` —
 * each an edit of the note's text. Turning the view on leaves the text alone.
 */
function updateChecklistNote(ctx: OpsContext, shape: Shape, raw: Record<string, unknown>, as: Actor | null): string {
  const m = ctx.store.shapes.get(shape.id)!
  const was = shape.view === VIEW_CHECKLIST
  const input = cleanNoteList('sticky', raw, ctx.store, shape.id)
  const { props } = input
  const listed = input.view === VIEW_CHECKLIST || (input.view === undefined && was)
  if (!listed) {
    // Back to (or still) a plain note: what is left is a plain note's update.
    for (const k of ['columns', 'rows', 'picks', 'notes', 'assignees'] as const) if (input[k] !== undefined) fail(`\`${k}\` is for a checklist: set \`view:"checklist"\``)
    if (input.title !== undefined) props.text = input.title
    if (props.w !== undefined) props.w = Math.max(props.w, MIN_SIZE.sticky.w)
    if (props.h !== undefined) props.h = Math.max(props.h, MIN_SIZE.sticky.h)
    ctx.store.update(shape.id, props, AGENT)
    if (input.view === null && m.has('view')) m.delete('view')
    return shape.id
  }
  // Everything is checked against the list as it will be before anything is written.
  const columns = input.columns ?? readNoteColumns(m.get('columns'))
  const text = props.text ?? shape.text
  const rows = input.rows ? listRows(input.rows) : listRows(parseChecklistText(text, columns).rows.map(r => r.label))
  if (input.picks !== undefined) cleanPicks(input.picks, rows, columns)
  if (input.notes !== undefined) cleanNotes(input.notes, rows)
  if (input.assignees !== undefined) cleanAssignees(input.assignees, rows, ctx.people?.() ?? [])
  const min = MIN_SIZE.checklist
  if (props.w !== undefined) props.w = Math.max(props.w, min.w)
  if (props.h !== undefined) props.h = Math.max(props.h, min.h)
  ctx.store.update(shape.id, props, AGENT)
  ctx.store.transact(() => {
    const t = noteText(m)
    if (!was) {
      m.set('view', VIEW_CHECKLIST)
      if (input.columns) m.set('columns', [...input.columns])
      if (props.w === undefined && shape.w < checklistWidth(columns.length)) m.set('w', checklistWidth(columns.length))
    } else if (input.columns) writeNoteColumns(m, input.columns)
    if (input.rows) {
      const now = parseChecklistText(t.toString(), columns)
      const left = [...now.rows]
      // A row keeps its pick, its comment and its assignees by label.
      const carry = (label: string) => {
        const i = left.findIndex(r => r.label === label) >= 0 ? left.findIndex(r => r.label === label) : left.findIndex(r => rowKey(r.label) === rowKey(label))
        return i >= 0 ? left.splice(i, 1)[0]! : null
      }
      replaceRows(
        t,
        now,
        input.rows.map(label => {
          const was = carry(label)
          return rowBlock(label, was?.pick ?? null, columns, was?.note ?? '', was?.assignees ?? [])
        })
      )
      const keep = new Set(input.rows.flatMap(label => [whoKey(label), noteByKey(label), assigneesKey(label)]))
      for (const key of [...m.keys()])
        if ((key.startsWith(WHO_PREFIX) || key.startsWith(NOTE_BY_PREFIX) || key.startsWith(ASSIGNEES_PREFIX)) && !keep.has(key)) m.delete(key)
    }
    if (input.title !== undefined) writeTitle(t, parseChecklistText(t.toString(), columns), input.title)
    if (input.picks !== undefined) {
      const now = parseChecklistText(t.toString(), columns)
      const resolved = cleanPicks(input.picks, listRows(now.rows.map(r => r.label)), columns)
      const by = pickerOf(as)
      const at = Date.now()
      // Last row first: each write stays inside its own line.
      const byIndex = resolved.map(([id, col]) => [now.rows[Number(id.slice(1))]!, col] as const).sort((a, b) => b[0].index - a[0].index)
      for (const [row, col] of byIndex) writeNotePick(m, t, row, col, columns, by, at)
    }
    const notedBefore = parseChecklistText(t.toString(), columns).rows.filter(r => r.note).length
    if (input.notes !== undefined) {
      const now = parseChecklistText(t.toString(), columns)
      const said = cleanNotes(input.notes, listRows(now.rows.map(r => r.label)))
      const by = pickerOf(as)
      const at = Date.now()
      // Last row first: each write stays inside its own row's lines.
      const byIndex = said.map(([id, text]) => [now.rows[Number(id.slice(1))]!, text] as const).sort((a, b) => b[0].index - a[0].index)
      for (const [row, text] of byIndex) if (row.note !== text) writeNoteNote(m, t, row, text, by, at)
    }
    if (input.assignees !== undefined) {
      const now = parseChecklistText(t.toString(), columns)
      const said = cleanAssignees(input.assignees, listRows(now.rows.map(r => r.label)), ctx.people?.() ?? [])
      const by = pickerOf(as)
      const at = Date.now()
      const title = now.title
      // Last row first: each write stays inside its own row's lines.
      const byIndex = said.map(([id, list]) => [now.rows[Number(id.slice(1))]!, list] as const).sort((a, b) => b[0].index - a[0].index)
      for (const [row, list] of byIndex) {
        const merged = mergeAssignees(noteAssignees(m, row), list, by, at)
        writeNoteAssignees(m, t, row, merged.people)
        if (merged.added.length) ctx.onAssigned?.({ shapeId: shape.id, title, row: row.label, people: merged.added })
      }
    }
    const after = parseChecklistText(t.toString(), columns)
    const notedAfter = after.rows.filter(r => r.note).length
    if (was && (input.rows || input.columns) && props.h === undefined) m.set('h', checklistHeight(columns.length, after.rows.length, notedAfter))
    else if (was && notedAfter !== notedBefore && props.h === undefined)
      // Comments alone: the card grows (or shrinks) by their lines, as measured so far.
      m.set('h', Math.max(min.h, (typeof m.get('h') === 'number' ? (m.get('h') as number) : shape.h) + CHECKLIST_LAYOUT.note * (notedAfter - notedBefore)))
    if (was && input.columns && props.w === undefined) m.set('w', Math.max(shape.w, checklistWidth(columns.length)))
    m.set('updatedAt', Date.now())
  }, AGENT)
  return shape.id
}

// ---- timelines ----------------------------------------------------------------

const TIMELINE_KEYS = ['view', 'type', 'title', 'start', 'end', 'step', 'items', 'addItems', 'editItems'] as const
/** Keys only a timeline takes (a plain note told them is told to set the view). */
const TIMELINE_ONLY = ['start', 'end', 'step', 'items', 'addItems', 'editItems'] as const

interface TimelineInput {
  props: ShapeProps
  view?: typeof VIEW_TIMELINE | null
  edits: TimelineEdits
}

function cleanDate(v: unknown, key: string): string {
  const d = cleanIso(v)
  return d ?? fail(`\`${key}\` must be a YYYY-MM-DD date`)
}

/** Wrap the model's own messages as op failures. */
function checked<T>(fn: () => T): T {
  try {
    return fn()
  } catch (e) {
    return fail(messageOf(e))
  }
}

/** A timeline's fields and the rest (a note's box, colour, text), checked. */
function cleanTimeline(raw: Record<string, unknown>, store: CanvasStore, selfId?: string): TimelineInput {
  const rest: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(raw)) if (!(TIMELINE_KEYS as readonly string[]).includes(k)) rest[k] = v
  const out: TimelineInput = { props: cleanProps('sticky', rest, store, selfId), edits: {} }
  const e = out.edits
  if (raw.view !== undefined) {
    if (raw.view === VIEW_TIMELINE) out.view = VIEW_TIMELINE
    else if (raw.view === null || raw.view === false || raw.view === '' || raw.view === 'note') out.view = null
    else fail('`view` must be "timeline", "checklist" or null')
  }
  if (raw.title !== undefined) {
    if (typeof raw.title !== 'string') fail('`title` must be a string')
    e.title = (raw.title as string).slice(0, MAX_TITLE)
  }
  if (raw.start !== undefined) e.start = cleanDate(raw.start, 'start')
  if (raw.end !== undefined) e.end = cleanDate(raw.end, 'end')
  if (raw.step !== undefined) e.step = checked(() => readStepInput(raw.step))
  if (raw.items !== undefined) e.items = checked(() => readItemsInput(raw.items, 'items'))
  if (raw.addItems !== undefined) e.add = checked(() => readItemsInput(raw.addItems, 'addItems'))
  if (raw.editItems !== undefined) {
    if (!isObject(raw.editItems)) fail('`editItems` must be {ref: patch | null}, a ref being "YYYY-MM-DD · label", a label, a date or an index')
    e.edit = Object.entries(raw.editItems as Record<string, unknown>).map(([ref, patch]): [string, ItemPatch | null] => [
      ref,
      patch === null ? null : checked(() => readItemPatch(patch, `editItems[${JSON.stringify(ref)}]`)),
    ])
  }
  return out
}

/** A step that suits a span of days, when none is given. */
function stepFor(days: number): Step {
  if (days <= 31) return 'day'
  if (days <= 270) return 'week'
  if (days <= 3 * 366) return 'month'
  if (days <= 8 * 366) return 'quarter'
  return 'year'
}

const hasEdits = (e: TimelineEdits) => Object.values(e).some(v => v !== undefined)

/** Item refs are tried on a copy first: an op writes all of its edits or none. */
function dryRun(text: string, edits: TimelineEdits) {
  const missing = unresolvedRefs(text, edits)
  if (missing.length) fail(`no item ${missing.map(m => JSON.stringify(m)).join(', ')} on this timeline (name one by "YYYY-MM-DD · label", its label, its date or its index)`)
}

/** A new timeline: a note in the timeline view whose text is the timeline. */
function addTimelineNote(raw: Record<string, unknown>, ctx: OpsContext, as: Actor | null, id: string | undefined) {
  const input = cleanTimeline(raw, ctx.store, id)
  if (input.view === null) fail('a timeline note needs `view:"timeline"`')
  const { props, edits } = input
  if (edits.edit) fail('`editItems` is for an update; give a new timeline its `items`')
  const listed = hasEdits(edits)
  let text: string
  if (props.text !== undefined && !listed) text = props.text
  else {
    if (props.text !== undefined) fail('give the timeline `text`, or `title`/`start`/`end`/`step`/`items`, not both')
    const items: ItemFields[] = [...(edits.items ?? []), ...(edits.add ?? [])]
    const days = items.flatMap(it => [it.date, it.end ?? it.date]).sort()
    let start = edits.start ?? days[0] ?? todayIso()
    let end = edits.end ?? (days.length ? days[days.length - 1]! : addMonths(start, 3))
    if (end < start) [start, end] = [end, start]
    if (end === start && !edits.end) end = addMonths(start, 1)
    const step = edits.step ?? stepFor((dayOf(end) ?? 0) - (dayOf(start) ?? 0) + 1)
    text = timelineMarkdown(edits.title ?? 'Timeline', { start, end, step }, items)
  }
  const shape: ShapeInput = { ...props, type: 'sticky', view: VIEW_TIMELINE, text, color: props.color ?? 'white', by: as?.name ?? 'Agent' }
  if (id) shape.id = id
  const w = Math.max(props.w ?? TIMELINE_SIZE.w, TIMELINE_MIN.w)
  const h = Math.max(props.h ?? TIMELINE_SIZE.h, TIMELINE_MIN.h, Math.ceil(neededHeight(text, w)))
  shape.w = w
  shape.h = h
  if (props.x === undefined || props.y === undefined) {
    const spot = findFreeSpot(boxesOf(ctx.store), { w, h }, ctx.viewportCenter(), { gap: 24, step: 32 })
    if (props.x === undefined) shape.x = spot.x
    if (props.y === undefined) shape.y = spot.y
  }
  const newId = ctx.store.create(shape, AGENT)
  return { id: newId, anchor: center({ x: shape.x!, y: shape.y!, w, h }) }
}

/**
 * An update to a note that is (or is becoming) a timeline: box props and
 * `text` as for any note, then `view` and the timeline's fields — each an
 * edit of the note's own lines. Turning the view on leaves the text alone.
 */
function updateTimelineNote(ctx: OpsContext, shape: Shape, raw: Record<string, unknown>): string {
  const m = ctx.store.shapes.get(shape.id)!
  const was = shape.view === VIEW_TIMELINE
  const input = cleanTimeline(raw, ctx.store, shape.id)
  const { props, edits } = input
  const on = input.view === VIEW_TIMELINE || (input.view === undefined && was)
  if (!on) {
    // Back to a plain note: what is left is a plain note's update.
    for (const k of TIMELINE_ONLY)
      if (raw[k] !== undefined) fail(`\`${k}\` is for a timeline: set \`view:"timeline"\``)
    if (edits.title !== undefined) props.text = edits.title
    if (props.w !== undefined) props.w = Math.max(props.w, MIN_SIZE.sticky.w)
    if (props.h !== undefined) props.h = Math.max(props.h, MIN_SIZE.sticky.h)
    ctx.store.update(shape.id, props, AGENT)
    if (input.view === null && m.has('view')) m.delete('view')
    return shape.id
  }
  if (props.text !== undefined && hasEdits(edits)) fail('give the timeline `text`, or its fields, not both')
  dryRun(props.text ?? shape.text, edits)
  if (props.w !== undefined) props.w = Math.max(props.w, TIMELINE_MIN.w)
  if (props.h !== undefined) props.h = Math.max(props.h, TIMELINE_MIN.h)
  ctx.store.update(shape.id, props, AGENT)
  ctx.store.transact(() => {
    if (!was) {
      m.set('view', VIEW_TIMELINE)
      if (props.w === undefined && shape.w < TIMELINE_SIZE.w) m.set('w', TIMELINE_SIZE.w)
    }
  }, AGENT)
  // The text alone (a conversion, a new body) still sizes the card to fit.
  writeTimeline(ctx.store, shape.id, edits, AGENT)
  return shape.id
}

function checkEnd(end: Endpoint, store: CanvasStore, key: string, selfId?: string) {
  if (!isRefEndpoint(end)) return
  if (end.ref === selfId) fail(`\`${key}\` cannot be the arrow itself`)
  const target = store.live(end.ref)
  if (!target) fail(`\`${key}\`: no shape ${end.ref}`)
  if (target!.type === 'arrow') fail(`\`${key}\`: ${end.ref} is an arrow; arrows join boxes`)
}

const boxesOf = (store: CanvasStore, except?: string): Box[] =>
  store
    .liveAll()
    .filter(s => s.type !== 'arrow' && s.id !== except)
    .map(occupied)

/** Shapes lying wholly inside a frame (not the frame, not arrows). */
export function frameChildren(shapes: readonly Shape[], frame: Box & { id: string }): Shape[] {
  return shapes.filter(s => s.id !== frame.id && s.type !== 'arrow' && containsBox(frame, s))
}

// ---- the ops ----------------------------------------------------------------

function opAdd(op: Record<string, unknown>, ctx: OpsContext, as: Actor | null): { id: string; anchor: Point } {
  let raw = isObject(op.shape) ? op.shape : fail('`add` needs `shape:{type, …}`')
  // `web` (or `iframe`): a live web frame, which is a link with `live` — one shape type, so older clients still show it.
  if (raw.type === 'web' || raw.type === 'iframe') raw = { ...raw, type: 'link', live: raw.live ?? raw.embed ?? true, embed: undefined }
  const type = raw.type
  if (!isShapeType(type) && type !== 'timeline') return fail('`shape.type` must be sticky, text, frame, arrow, image, link, checklist, timeline or web')
  let id: string | undefined
  if (raw.id !== undefined) {
    if (typeof raw.id !== 'string' || !ID.test(raw.id)) fail('`shape.id` must be 1–64 of A–Z a–z 0–9 _ - : .')
    if (ctx.store.shapes.has(raw.id as string)) fail(`a shape with id ${raw.id as string} already exists`)
    id = raw.id as string
  }
  // A timeline is a note in the timeline view: every Copper shows its text.
  if (type === 'timeline' || (type === 'sticky' && raw.view === VIEW_TIMELINE)) return addTimelineNote(raw, ctx, as, id)
  if (!isShapeType(type)) return fail('`shape.type` must be sticky, text, frame, arrow, image, link, checklist, timeline or web')
  // A checklist is a note in the checklist view: every Copper shows its text.
  if (type === 'sticky' && (raw.view === null || raw.view === false)) raw = { ...raw, view: undefined }
  if (type === 'checklist' || (type === 'sticky' && raw.view !== undefined)) return addChecklistNote(type, raw, ctx, as, id)
  const props = cleanProps(type, raw, ctx.store, id)
  const input: ShapeInput = { type, ...props }
  if (id) input.id = id
  input.by = as?.name ?? 'Agent'

  if (type === 'arrow') {
    if (!props.from || !props.to) fail('an arrow needs `from` and `to`')
    const newId = ctx.store.create(input, AGENT)
    const shape = ctx.store.live(newId)
    const path = shape ? arrowPath(shape, ref => ctx.store.live(ref)) : null
    return { id: newId, anchor: path ? path.mid : { x: 0, y: 0 } }
  }
  if (type === 'image') {
    if (!props.src) fail('an image needs `src`')
    const nw = props.naturalW || 0
    const nh = props.naturalH || 0
    if (props.w === undefined || props.h === undefined) {
      const size = imageSizeFor(nw || SHAPE_SIZE.image.w, nh || SHAPE_SIZE.image.h)
      if (props.w === undefined && props.h !== undefined) input.w = Math.round((props.h * size.w) / size.h)
      else if (props.h === undefined && props.w !== undefined) input.h = Math.round((props.w * size.h) / size.w)
      else {
        input.w = size.w
        input.h = size.h
      }
    }
    if (!nw || !nh) {
      input.naturalW = nw || input.w
      input.naturalH = nh || input.h
    }
  }
  if (type === 'frame' && props.image && props.w === undefined && props.h === undefined) {
    const size = frameSizeFor(props.image.naturalW || 640, props.image.naturalH || 480)
    input.w = size.w
    input.h = size.h
  }
  if (type === 'link') {
    if (!props.url) fail('a link needs `url`')
    if (!props.title) input.title = hostOf(props.url!)
    if (props.live && !frameUrl(props.url)) fail('a live frame needs an http(s) `url`')
  }
  const base = type === 'link' && props.live ? LIVE_SIZE : SHAPE_SIZE[type]
  const size = { w: input.w ?? base.w, h: input.h ?? base.h }
  if (isResizable(type)) {
    const min = minSizeOf({ type, live: props.live })
    size.w = Math.max(size.w, min.w)
    size.h = Math.max(size.h, min.h)
  }
  input.w = size.w
  input.h = size.h
  if (props.x === undefined || props.y === undefined) {
    const spot = findFreeSpot(boxesOf(ctx.store), size, ctx.viewportCenter(), { gap: 24, step: 32 })
    if (props.x === undefined) input.x = spot.x
    if (props.y === undefined) input.y = spot.y
  }
  const newId = ctx.store.create(input, AGENT)
  return { id: newId, anchor: center({ x: input.x!, y: input.y!, w: size.w, h: size.h }) }
}

function needShape(ctx: OpsContext, id: unknown): Shape {
  if (typeof id !== 'string' || !id) return fail('`id` must be a shape id')
  const shape = ctx.store.live(bareId(id))
  if (!shape) return fail(`no shape ${id}`)
  return shape
}

function anchorOf(ctx: OpsContext, id: string): Point {
  const shape = ctx.store.live(id)
  if (!shape) return ctx.viewportCenter()
  if (shape.type === 'arrow') {
    const path = arrowPath(shape, ref => ctx.store.live(ref))
    return path ? path.mid : ctx.viewportCenter()
  }
  return center(shape)
}

function opUpdate(op: Record<string, unknown>, ctx: OpsContext, as: Actor | null = null): string {
  const shape = needShape(ctx, op.id)
  const raw = isObject(op.patch) ? op.patch : isObject(op.props) ? op.props : fail('`update` needs `patch:{…}`')
  if (
    shape.type === 'sticky' &&
    (raw.view === VIEW_TIMELINE ||
      (shape.view === VIEW_TIMELINE && raw.view !== VIEW_CHECKLIST) ||
      (shape.view === undefined && TIMELINE_ONLY.some(k => raw[k] !== undefined)))
  )
    return updateTimelineNote(ctx, shape, raw)
  if (shape.type === 'sticky' && (shape.view === VIEW_CHECKLIST || raw.view !== undefined)) return updateChecklistNote(ctx, shape, raw, as)
  const props = cleanProps(shape.type, raw, ctx.store, shape.id)
  if (shape.type === 'checklist') {
    const { columns, rows, ...rest } = props
    const picks = rawPicks(raw)
    if (picks !== undefined) cleanPicks(picks, rows ?? shape.rows ?? [], columns ?? shape.columns ?? [...DEFAULT_COLUMNS])
    if (raw.notes !== undefined) cleanNotes(raw.notes, rows ?? shape.rows ?? [])
    if (raw.assignees !== undefined) cleanAssignees(raw.assignees, rows ?? shape.rows ?? [], ctx.people?.() ?? [])
    if (rest.w !== undefined) rest.w = Math.max(rest.w, MIN_SIZE.checklist.w)
    if (rest.h !== undefined) rest.h = Math.max(rest.h, MIN_SIZE.checklist.h)
    ctx.store.update(shape.id, rest, AGENT)
    writeChecklist(ctx, shape.id, { columns, rows }, picks, raw.notes, raw.assignees, as, { w: rest.w !== undefined, h: rest.h !== undefined })
    return shape.id
  }
  if (shape.type === 'link' && props.live && !frameUrl(props.url ?? shape.url)) fail('a live frame needs an http(s) `url`')
  // A new address without a new name: the old page's name and icon would be wrong. The host
  // stands in, and a live frame puts the page's own name back once it has loaded.
  if (shape.type === 'link' && props.url && props.url !== shape.url) {
    if (props.title === undefined) props.title = hostOf(props.url)
    if (props.favicon === undefined && shape.favicon && hostOf(props.url) !== hostOf(shape.url ?? '')) props.favicon = ''
  }
  if (isResizable(shape.type)) {
    const live = props.live ?? shape.live
    const min = minSizeOf({ type: shape.type, live })
    // Turning a small card live makes it a frame worth looking at.
    if (shape.type === 'link' && props.live && !shape.live) {
      props.w ??= Math.max(shape.w, LIVE_SIZE.w)
      props.h ??= Math.max(shape.h, LIVE_SIZE.h)
    }
    if (props.w !== undefined) props.w = Math.max(props.w, min.w)
    if (props.h !== undefined) props.h = Math.max(props.h, min.h)
  }
  if (shape.type === 'arrow') {
    const from = props.from ?? shape.from
    const to = props.to ?? shape.to
    if (from && to && isRefEndpoint(from) && isRefEndpoint(to) && from.ref === to.ref)
      fail('an arrow cannot start and end on the same shape')
  }
  ctx.store.update(shape.id, props, AGENT)
  return shape.id
}

function opMove(op: Record<string, unknown>, ctx: OpsContext): string {
  const shape = needShape(ctx, op.id)
  const dx = op.dx ?? 0
  const dy = op.dy ?? 0
  if (!finite(dx) || !finite(dy)) fail('`dx` and `dy` must be finite numbers')
  const moves: [string, Record<string, unknown>][] = []
  if (shape.type === 'arrow') {
    const shift = (e: Endpoint | undefined) => (e && !isRefEndpoint(e) ? { x: e.x + (dx as number), y: e.y + (dy as number) } : e)
    moves.push([shape.id, { from: shift(shape.from), to: shift(shape.to) }])
  } else {
    moves.push([shape.id, { x: shape.x + (dx as number), y: shape.y + (dy as number) }])
    if (shape.type === 'frame')
      for (const child of frameChildren(ctx.store.liveAll(), shape))
        moves.push([child.id, { x: child.x + (dx as number), y: child.y + (dy as number) }])
  }
  ctx.store.moveMany(moves, AGENT)
  return shape.id
}

function opResize(op: Record<string, unknown>, ctx: OpsContext): string {
  const shape = needShape(ctx, op.id)
  if (!isResizable(shape.type)) fail(`${shape.type} shapes have no size`)
  const w = op.w ?? shape.w
  const h = op.h ?? shape.h
  if (!finite(w) || !finite(h) || w <= 0 || h <= 0) fail('`w` and `h` must be positive numbers')
  const min = minSizeOf(shape as Shape & { type: keyof typeof MIN_SIZE })
  const nw = Math.max(w as number, min.w)
  // A timeline is never shorter than its content needs at its new width.
  const nh = Math.max(h as number, min.h, shape.view === VIEW_TIMELINE ? Math.ceil(neededHeight(shape.text, nw)) : 0)
  ctx.store.update(shape.id, { w: nw, h: nh }, AGENT)
  return shape.id
}

function opDelete(op: Record<string, unknown>, ctx: OpsContext): string {
  const shape = needShape(ctx, op.id)
  ctx.store.remove([shape.id], AGENT)
  return shape.id
}

const isSide = (v: unknown): v is Side => typeof v === 'string' && (SIDES as readonly string[]).includes(v)

function opConnect(op: Record<string, unknown>, ctx: OpsContext, as: Actor | null): { id: string; anchor: Point } {
  const end = (v: unknown, side: unknown, key: string): Endpoint => {
    const e = readEndpoint(v)
    if (!e) return fail(`\`${key}\` must be a shape id`)
    if (isRefEndpoint(e) && side !== undefined) {
      if (!isSide(side)) fail(`\`${key}Side\` must be top, right, bottom or left`)
      e.side = side as Side
    }
    return e
  }
  const from = end(op.from, op.fromSide, 'from')
  const to = end(op.to, op.toSide, 'to')
  if (isRefEndpoint(from) && isRefEndpoint(to) && from.ref === to.ref) fail('`from` and `to` are the same shape')
  const raw: Record<string, unknown> = { from, to }
  if (op.label !== undefined) raw.label = op.label
  if (op.color !== undefined) raw.color = op.color
  let id: string | undefined
  if (op.id !== undefined) {
    if (typeof op.id !== 'string' || !ID.test(op.id)) fail('`id` must be 1–64 of A–Z a–z 0–9 _ - : .')
    if (ctx.store.shapes.has(op.id as string)) fail(`a shape with id ${op.id as string} already exists`)
    id = op.id as string
  }
  const props = cleanProps('arrow', raw, ctx.store, id)
  const input: ShapeInput = { type: 'arrow', ...props, by: as?.name ?? 'Agent' }
  if (id) input.id = id
  const newId = ctx.store.create(input, AGENT)
  return { id: newId, anchor: anchorOf(ctx, newId) }
}

// ---- comment threads ---------------------------------------------------------

const authorOf = (as: Actor | null): CommentAuthor => ({ name: as?.name ?? 'Agent', id: as?.id ?? 'agent' })

const threadRef = (v: unknown): string => {
  if (typeof v !== 'string' || !v.trim()) return fail('`thread` must be a thread id (from canvas_read comments)')
  const t = v.trim()
  return t.startsWith('comment:') ? t.slice(8) : t
}

function opComment(op: Record<string, unknown>, ctx: OpsContext, as: Actor | null): { id: string; anchor: Point } {
  const on = op.on ?? op.shape ?? op.anchor
  if (typeof on !== 'string' || !on.trim()) fail('`comment` needs `on`: the id of the shape to comment on')
  const shape = ctx.store.live(bareId((on as string).trim()))
  if (!shape) fail(`no shape ${on as string}`)
  let id: string | undefined
  if (op.id !== undefined) {
    if (typeof op.id !== 'string' || !ID.test(op.id)) fail('`id` must be 1–64 of A–Z a–z 0–9 _ - : .')
    if (ctx.store.comments.map.has(op.id as string)) fail(`a comment thread with id ${op.id as string} already exists`)
    id = op.id as string
  }
  const text = commentText(op.text)
  const threadId = ctx.store.comments.create(shape!.id, text, authorOf(as), { id, anchorName: shapeLabel(shape!), origin: AGENT })
  return { id: threadId, anchor: anchorOf(ctx, shape!.id) }
}

function commentText(raw: unknown): string {
  try {
    return cleanCommentText(raw)
  } catch (e) {
    return fail(messageOf(e))
  }
}

function needThread(ctx: OpsContext, ref: unknown) {
  const id = threadRef(ref)
  const t = ctx.store.comments.get(id)
  if (!t || !isShown(t)) return fail(`no comment thread ${id}`)
  return t
}

function opReply(op: Record<string, unknown>, ctx: OpsContext, as: Actor | null): string {
  const t = needThread(ctx, op.thread ?? op.id)
  const text = commentText(op.text)
  const shape = ctx.store.live(t.anchor)
  ctx.store.comments.reply(t.id, text, authorOf(as), { origin: AGENT, anchorName: shape ? shapeLabel(shape) : undefined })
  return t.id
}

function opResolve(op: Record<string, unknown>, ctx: OpsContext, as: Actor | null): string {
  const t = needThread(ctx, op.thread ?? op.id)
  const resolved = op.resolved ?? true
  if (typeof resolved !== 'boolean') fail('`resolved` must be true or false')
  ctx.store.comments.setResolved(t.id, resolved as boolean, authorOf(as), { origin: AGENT })
  return t.id
}

export interface ApplyOutcome extends ApplyResult {
  /** Where the agent's cursor should rest: the last thing it touched. */
  anchor: Point | null
  actor: Actor | null
}

/** Apply ops (see the file header). Never throws. */
export function applyOps(ctx: OpsContext, raw: unknown): ApplyOutcome {
  let parsed: ParsedInput
  try {
    parsed = parseApplyInput(raw)
  } catch (e) {
    return { applied: 0, ids: [], errors: [{ index: -1, op: '', error: messageOf(e) }], anchor: null, actor: null }
  }
  const { ops, as } = parsed
  const result: ApplyOutcome = { applied: 0, ids: [], errors: [], anchor: null, actor: as }
  if (ctx.readOnly) {
    result.ids = ops.map(() => null)
    result.errors = ops.map((op, index) => ({ index, op: opName(op), error: 'this canvas is read-only' }))
    return result
  }
  if (ops.length > MAX_OPS) {
    result.errors.push({ index: -1, op: '', error: `at most ${MAX_OPS} ops per call (got ${ops.length})` })
    return result
  }
  ctx.store.transact(() => {
    ops.forEach((op, index) => {
      const name = opName(op)
      try {
        if (!isObject(op)) fail('an op must be an object like {op:"add", …}')
        const o = op as Record<string, unknown>
        let id: string | null = null
        switch (o.op) {
          case 'add': {
            const r = opAdd(o, ctx, as)
            id = r.id
            result.anchor = r.anchor
            break
          }
          case 'update':
            id = opUpdate(o, ctx, as)
            result.anchor = anchorOf(ctx, id)
            break
          case 'move':
            id = opMove(o, ctx)
            result.anchor = anchorOf(ctx, id)
            break
          case 'resize':
            id = opResize(o, ctx)
            result.anchor = anchorOf(ctx, id)
            break
          case 'delete': {
            const at = anchorOf(ctx, bareId(String(o.id ?? '')))
            id = opDelete(o, ctx)
            result.anchor = at
            break
          }
          case 'connect': {
            const r = opConnect(o, ctx, as)
            id = r.id
            result.anchor = r.anchor
            break
          }
          case 'clear':
            ctx.store.clear(AGENT)
            break
          case 'comment': {
            const r = opComment(o, ctx, as)
            id = r.id
            result.anchor = r.anchor
            break
          }
          case 'reply':
          case 'resolve': {
            id = o.op === 'reply' ? opReply(o, ctx, as) : opResolve(o, ctx, as)
            const anchor = ctx.store.comments.get(id)?.anchor
            if (anchor && ctx.store.live(anchor)) result.anchor = anchorOf(ctx, anchor)
            break
          }
          default:
            fail(`unknown op ${JSON.stringify(o.op ?? null)} (add, update, move, resize, delete, connect, clear, comment, reply, resolve)`)
        }
        result.ids.push(id)
        result.applied++
      } catch (e) {
        result.ids.push(null)
        result.errors.push({ index, op: name, error: messageOf(e) })
      }
    })
  }, AGENT)
  return result
}

const opName = (op: unknown) => (isObject(op) && typeof op.op === 'string' ? op.op : '')
const messageOf = (e: unknown) => (e instanceof Error ? e.message : String(e))

// ---- read -------------------------------------------------------------------

export interface ReadOptions {
  /** Whole text instead of the first 500 characters. */
  full?: boolean
  /** Only these shapes. */
  ids?: string[]
  /** Only shapes touching the visible area. */
  inView?: boolean
  /** Only these types. */
  types?: string[]
}

export interface ReadContext {
  store: CanvasStore
  canvas: { id: string; name: string; kind: string }
  /** The visible world rectangle and zoom; null when unknown. */
  viewport: (Box & { zoom: number }) | null
  selection: readonly string[]
  now?: number
}

export interface ShapeSummary {
  id: string
  type: ShapeType
  x: number
  y: number
  w: number
  h: number
  color: string
  z: number
  by?: string
  text?: string
  title?: string
  label?: string
  url?: string
  /** link: shown live (the site in a frame) rather than as a card. */
  live?: boolean
  fontSize?: number
  align?: string
  from?: Endpoint
  to?: Endpoint
  src?: string
  naturalW?: number
  naturalH?: number
  image?: { src: string; naturalW: number; naturalH: number }
  /** sticky: shown as a checklist card (its text is the list) or a timeline (its text is the timeline). */
  view?: 'checklist' | 'timeline'
  /** timeline: its range (YYYY-MM-DD), step and items in date order. */
  start?: string
  end?: string
  step?: string
  items?: Record<string, unknown>[]
  /** checklist (and a note in that view): its columns, rows with each one's pick (and who made it, when, when known), and the count per column. */
  columns?: string[]
  /** A checklist's rows: the pick (who and when, when known), the row's comment (who and when, when known) and who it is assigned to. */
  rows?: {
    id?: string
    label: string
    pick: string | null
    by?: string
    at?: number
    note?: string
    noteBy?: string
    noteAt?: number
    assignees?: { name: string; id?: string; email?: string }[]
  }[]
  tally?: Record<string, number>
  /** The innermost frame this shape sits in. */
  frame?: string
}

/** One comment thread as an agent reads it: deleted messages left out, texts clipped unless `full`. */
export interface CommentSummary {
  id: string
  /** The shape it is on. */
  anchor: string
  /** Set when that shape has been deleted (the thread stays). */
  anchorDeleted?: true
  resolved: boolean
  resolvedBy?: string
  messages: { id: string; by: string; at: number; text: string; edited?: true }[]
}

export interface CanvasRead {
  canvas: { id: string; name: string; kind: string }
  viewport?: { x: number; y: number; w: number; h: number; zoom: number }
  shapes: ShapeSummary[]
  /** Comment threads, oldest first; with `ids`/`types`/`inView`, only those on the shapes returned. */
  comments: CommentSummary[]
  agents: (Omit<CanvasAgent, 'cursor'> & { cursor: Point | null })[]
  selection: string[]
  count: number
}

export const READ_TEXT_LIMIT = 500

export function parseReadOptions(raw: unknown): ReadOptions {
  let v = raw
  if (typeof v === 'string') {
    if (!v.trim()) return {}
    try {
      v = JSON.parse(v)
    } catch {
      return {}
    }
  }
  if (!isObject(v)) return {}
  const out: ReadOptions = {}
  if (v.full === true) out.full = true
  if (v.inView === true || v.viewport === true) out.inView = true
  if (Array.isArray(v.ids)) out.ids = v.ids.filter((x): x is string => typeof x === 'string').map(bareId)
  if (Array.isArray(v.types)) out.types = v.types.filter((x): x is string => typeof x === 'string')
  return out
}

const clip = (s: string, full: boolean) => (full || s.length <= READ_TEXT_LIMIT ? s : `${s.slice(0, READ_TEXT_LIMIT)}…`)

/** A data URL is never echoed whole: its kind and size are enough to reason about. */
export function describeSrc(src: string, full = false): string {
  if (!src.startsWith('data:')) return src
  if (full && src.length <= 4096) return src
  const kind = /^data:([^;,]+)/.exec(src)?.[1] ?? 'data'
  const bytes = Math.round(((src.length - src.indexOf(',') - 1) * 3) / 4)
  return `data:${kind} (${bytes >= 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`})`
}

const r = (n: number) => Math.round(n)

/** The board as an agent should see it (see the spec's read format). */
export function readCanvas(ctx: ReadContext, rawOpts: unknown = {}): CanvasRead {
  const opts = parseReadOptions(rawOpts)
  const full = !!opts.full
  const all = [...ctx.store.getShapes().values()]
  const byId = new Map(all.map(s => [s.id, s] as const))
  const boxOf = (id: string) => {
    const s = byId.get(id)
    return s && s.type !== 'arrow' ? s : null
  }
  const frames = all.filter(s => s.type === 'frame')
  const parentFrame = (s: Shape) => {
    let best: Shape | null = null
    for (const f of frames) {
      if (f.id === s.id || !containsBox(f, s)) continue
      if (!best || f.w * f.h < best.w * best.h) best = f
    }
    return best?.id
  }
  const ids = opts.ids ? new Set(opts.ids) : null
  const types = opts.types ? new Set(opts.types) : null
  const out: ShapeSummary[] = []
  for (const s of all) {
    if (ids && !ids.has(s.id)) continue
    if (types && !types.has(s.type) && !(s.view === VIEW_CHECKLIST && types.has('checklist')) && !(s.view === VIEW_TIMELINE && types.has('timeline'))) continue
    let box: Box = { x: s.x, y: s.y, w: s.w, h: s.h }
    if (s.type === 'arrow') {
      const path = arrowPath(s, boxOf)
      box = path ? arrowBox(path) : { x: 0, y: 0, w: 0, h: 0 }
    }
    if (opts.inView && ctx.viewport && !boxesOverlap(ctx.viewport, box)) continue
    const sum: ShapeSummary = {
      id: s.id,
      type: s.type,
      x: r(box.x),
      y: r(box.y),
      w: r(box.w),
      h: r(box.h),
      color: s.color,
      z: s.z,
    }
    if (s.by) sum.by = s.by
    switch (s.type) {
      case 'sticky':
      case 'text':
        sum.text = clip(s.text, full)
        if (s.fontSize) sum.fontSize = s.fontSize
        if (s.align) sum.align = s.align
        if (s.view === VIEW_CHECKLIST) {
          sum.view = VIEW_CHECKLIST
          sum.title = clip(s.title, full)
          Object.assign(sum, summarizeNoteChecklist(s.columns ?? [], s.rows ?? [], s.picks ?? {}, s.notes ?? {}, t => clip(t, full), s.assignees ?? {}))
        }
        if (s.view === VIEW_TIMELINE && s.timeline) {
          sum.view = VIEW_TIMELINE
          sum.title = clip(s.title, full)
          sum.start = s.timeline.start
          sum.end = s.timeline.end
          sum.step = s.timeline.step
          sum.items = summarizeItems(s.timeline.items).map(it => (typeof it.text === 'string' ? { ...it, text: clip(it.text, full) } : it))
        }
        break
      case 'frame':
        sum.title = clip(s.title, full)
        if (s.image) sum.image = { ...s.image, src: describeSrc(s.image.src, full) }
        break
      case 'arrow':
        sum.label = clip(s.label ?? '', full)
        if (s.from) sum.from = s.from
        if (s.to) sum.to = s.to
        break
      case 'image':
        sum.src = describeSrc(s.src ?? '', full)
        sum.naturalW = s.naturalW
        sum.naturalH = s.naturalH
        break
      case 'link':
        sum.url = s.url
        sum.title = clip(s.title, full)
        if (s.live) sum.live = true
        break
      case 'checklist':
        sum.title = clip(s.title, full)
        Object.assign(sum, summarizeChecklist(s.columns ?? [], s.rows ?? [], s.picks ?? {}, s.notes ?? {}, t => clip(t, full), s.assignees ?? {}))
        break
    }
    if (s.type !== 'arrow') {
      const parent = parentFrame(s)
      if (parent) sum.frame = parent
    }
    out.push(sum)
  }
  out.sort((a, b) => a.y - b.y || a.x - b.x || (a.id < b.id ? -1 : 1))
  const now = ctx.now ?? Date.now()
  const filtered = !!(ids || types || (opts.inView && ctx.viewport))
  const returned = new Set(out.map(s => s.id))
  const comments: CommentSummary[] = []
  for (const t of ctx.store.comments.getThreads()) {
    if (!isShown(t) || (filtered && !returned.has(t.anchor))) continue
    const c: CommentSummary = {
      id: t.id,
      anchor: t.anchor,
      resolved: t.resolved,
      messages: t.messages
        .filter(m => !m.deleted)
        .map(m => ({ id: m.id, by: m.by, at: m.at, text: clip(m.text, full), ...(m.editedAt ? { edited: true as const } : {}) })),
    }
    if (!byId.has(t.anchor)) c.anchorDeleted = true
    if (t.resolved && t.resolvedBy) c.resolvedBy = t.resolvedBy
    comments.push(c)
  }
  const read: CanvasRead = {
    canvas: ctx.canvas,
    shapes: out,
    comments,
    agents: liveAgents(readAgents(ctx.store.agents), now),
    selection: [...ctx.selection],
    count: all.length,
  }
  if (ctx.viewport)
    read.viewport = {
      x: r(ctx.viewport.x),
      y: r(ctx.viewport.y),
      w: r(ctx.viewport.w),
      h: r(ctx.viewport.h),
      zoom: Math.round(ctx.viewport.zoom * 1000) / 1000,
    }
  return read
}
