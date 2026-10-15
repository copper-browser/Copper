/**
 * The checklist (RSVP) card: a title, 1–4 columns ("Yes", "No") and up to
 * 60 rows (people, tasks). Each row has at most one pick; one column makes
 * plain to-do boxes.
 *
 * Two stored forms, one card:
 *
 * - **A note** (`type:"sticky"`, `view:"checklist"`, what this page writes):
 *   the note's text is the checklist, as markdown every Copper draws as task
 *   boxes — see `checklist-text.ts`. Older Coppers show and tick it as a note.
 * - **Legacy** (`type:"checklist"`, written by the first cut and still taken
 *   by copper-cloud's REST `/ops`), on the shape's own `Y.Map`:
 *
 *   title    string
 *   columns  string[]                   whole value, last writer wins
 *   rows     {id, label}[]              whole value, last writer wins
 *   pick:<rowId>  {col, by, byId, at}   one key per row
 *   note:<rowId>  {text, by, byId, at}  a row's comment, one key per row
 *   assignees:<rowId>  [{name, id?, email?, by?, byId?, at?}]  who the row is assigned to
 *
 * A pick lives under its row's own key, so two people clicking different rows
 * at the same moment both stick: neither rewrites the other's. `col` is the
 * column's label; renaming a column rewrites the picks that name it, removing
 * one drops them. A pick naming no current column (or no current row) reads
 * as no pick.
 *
 * Pure apart from Yjs: the board, the ops (`ops.ts`) and the cloud's mirror
 * (`crates/canvas/src/checklist.rs`) share these rules.
 */
import * as Y from 'yjs'
import {
  TICK_COLUMN,
  VIEW_CHECKLIST,
  WHO_PREFIX,
  assigneeBlock,
  assigneeName,
  insertRowLine,
  noteBlock,
  noteLines,
  noteText,
  oneLine,
  parseChecklistText,
  removeRowLine,
  rowKey,
  rowLine,
  whoKey,
  writeRowAssignees,
  writeRowLabel,
  writeRowNote,
  writeRowPick,
  writeTitle,
  type ParsedChecklist,
  type TextRow,
} from './checklist-text'
import type { CanvasStore, Origin } from './doc'
import type { ChecklistAssignee, ChecklistNote, ChecklistPick, ChecklistRow } from './types'

export const PICK_PREFIX = 'pick:'
/** A legacy card's comment on a row: `note:<rowId>` → `{text, by, byId, at}`. */
export const NOTE_PREFIX = 'note:'
/** Who last wrote a note's row comment, and when: `noteBy:<label key>` → `{by, byId, at}` (the words are the text's). */
export const NOTE_BY_PREFIX = 'noteBy:'
/**
 * Who a row's assignees are: `assignees:<label key>` on a note (the names are
 * the text's), `assignees:<rowId>` on a legacy card → `[{name, id?, email?,
 * by?, byId?, at?}]` (`id`: a cloud user id; `by`/`at`: who assigned them, when).
 */
export const ASSIGNEES_PREFIX = 'assignees:'
/** People on one row. */
export const MAX_ASSIGNEES = 12
export const MAX_COLUMNS = 4
export const MAX_ROWS = 60
/** Labels are cut to these many characters (UTF-16 units, as JavaScript counts). */
export const MAX_COLUMN_LABEL = 40
export const MAX_ROW_LABEL = 200
/** A row's comment is cut to these many characters. */
export const MAX_NOTE = 4000
export const DEFAULT_COLUMNS: readonly string[] = ['Yes', 'No']
/** Ids a caller may give a row. */
export const ROW_ID = /^[A-Za-z0-9_-]{1,32}$/

export const pickKey = (rowId: string) => PICK_PREFIX + rowId
export const noteKey = (rowId: string) => NOTE_PREFIX + rowId
export const noteByKey = (label: string) => NOTE_BY_PREFIX + rowKey(label)
/** A note row's assignees' ids, by its label; a legacy row's assignees, by its id. */
export const assigneesKey = (label: string) => ASSIGNEES_PREFIX + rowKey(label)
export const legacyAssigneesKey = (rowId: string) => ASSIGNEES_PREFIX + rowId

/** A comment as it is kept: `\n` line breaks, at most `MAX_NOTE` characters. */
export const cleanNote = (text: string) => noteLines(text).slice(0, MAX_NOTE)

export function newRowId(): string {
  let id = 'r'
  for (let i = 0; i < 8; i++) id += Math.floor(Math.random() * 36).toString(36)
  return id
}

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)
const plain = (v: unknown): Record<string, unknown> | null => {
  if (v instanceof Y.Map) return v.toJSON() as Record<string, unknown>
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}
const list = (v: unknown): unknown[] | null => (v instanceof Y.Array ? v.toArray() : Array.isArray(v) ? v : null)
const fold = (s: string) => s.trim().toLowerCase()

// ---- tolerant reads -------------------------------------------------------------

/** Columns as stored: strings, deduplicated, at most four; none → `fallback` (Yes / No). */
export function readColumns(v: unknown, fallback: readonly string[] = DEFAULT_COLUMNS): string[] {
  const out: string[] = []
  for (const c of list(v) ?? []) {
    if (typeof c !== 'string' || !c.trim()) continue
    if (out.some(o => fold(o) === fold(c))) continue
    out.push(c)
    if (out.length === MAX_COLUMNS) break
  }
  return out.length ? out : [...fallback]
}

/** Rows as stored: `{id, label}` with unique ids, at most sixty. */
export function readRows(v: unknown): ChecklistRow[] {
  const out: ChecklistRow[] = []
  const seen = new Set<string>()
  for (const r of list(v) ?? []) {
    const o = plain(r)
    if (!o || typeof o.id !== 'string' || !o.id || seen.has(o.id)) continue
    seen.add(o.id)
    out.push({ id: o.id, label: typeof o.label === 'string' ? o.label : '' })
    if (out.length === MAX_ROWS) break
  }
  return out
}

export function readPick(v: unknown): ChecklistPick | null {
  const o = plain(v)
  if (!o || typeof o.col !== 'string' || !o.col) return null
  return {
    col: o.col,
    by: typeof o.by === 'string' ? o.by : '',
    byId: typeof o.byId === 'string' ? o.byId : '',
    at: finite(o.at) ? o.at : 0,
  }
}

/** Each row's pick, when it names a current column. */
export function readPicks(m: Y.Map<unknown>, rows: readonly ChecklistRow[], columns: readonly string[]): Record<string, ChecklistPick> {
  const out: Record<string, ChecklistPick> = {}
  for (const row of rows) {
    const pick = readPick(m.get(pickKey(row.id)))
    if (pick && columns.includes(pick.col)) out[row.id] = pick
  }
  return out
}

/** Who wrote a comment and when (`noteBy:` on a note); null when unknown. */
function readNoteBy(v: unknown): Omit<ChecklistNote, 'text'> | null {
  const o = plain(v)
  if (!o || typeof o.by !== 'string') return null
  return { by: o.by, byId: typeof o.byId === 'string' ? o.byId : '', at: finite(o.at) ? o.at : 0 }
}

/** A legacy card's comment on a row, when it has words. */
export function readLegacyNote(v: unknown): ChecklistNote | null {
  const o = plain(v)
  if (!o || typeof o.text !== 'string' || !o.text) return null
  return { text: o.text, ...(readNoteBy(o) ?? { by: '', byId: '', at: 0 }) }
}

/** A legacy card's comments, by row id. */
export function readNotes(m: Y.Map<unknown>, rows: readonly ChecklistRow[]): Record<string, ChecklistNote> {
  const out: Record<string, ChecklistNote> = {}
  for (const row of rows) {
    const note = readLegacyNote(m.get(noteKey(row.id)))
    if (note) out[row.id] = note
  }
  return out
}

/** One stored assignee (tolerant: a bare string is a name). */
export function readAssignee(v: unknown): ChecklistAssignee | null {
  if (typeof v === 'string') {
    const name = assigneeName(v)
    return name ? { name } : null
  }
  const o = plain(v)
  if (!o || typeof o.name !== 'string') return null
  const name = assigneeName(o.name)
  if (!name) return null
  const out: ChecklistAssignee = { name }
  if (typeof o.id === 'string' && o.id.trim()) out.id = o.id.trim().toLowerCase().slice(0, 80)
  if (typeof o.email === 'string' && o.email.includes('@')) out.email = o.email.trim().slice(0, 200)
  if (typeof o.by === 'string' && o.by) out.by = o.by
  if (typeof o.byId === 'string' && o.byId) out.byId = o.byId
  if (finite(o.at) && o.at > 0) out.at = o.at
  return out
}

/** A stored list of assignees, each person once (by id, else name), at most twelve. */
export function readAssigneeList(v: unknown): ChecklistAssignee[] {
  const out: ChecklistAssignee[] = []
  for (const raw of list(v) ?? []) {
    const a = readAssignee(raw)
    if (!a || out.some(o => samePerson(o, a))) continue
    out.push(a)
    if (out.length === MAX_ASSIGNEES) break
  }
  return out
}

/** The same person: the same id when both have one, else the same name (any case), else the same email. */
export function samePerson(a: { name: string; id?: string; email?: string }, b: { name: string; id?: string; email?: string }): boolean {
  if (a.id && b.id) return a.id === b.id
  if (fold(a.name) === fold(b.name)) return true
  return !!a.email && !!b.email && fold(a.email) === fold(b.email)
}

/** A legacy card's assignees, by row id, for rows that have some. */
export function readLegacyAssignees(m: Y.Map<unknown>, rows: readonly ChecklistRow[]): Record<string, ChecklistAssignee[]> {
  const out: Record<string, ChecklistAssignee[]> = {}
  for (const row of rows) {
    const people = readAssigneeList(m.get(legacyAssigneesKey(row.id)))
    if (people.length) out[row.id] = people
  }
  return out
}

/**
 * A note row's assignees: the names its `@` lines hold, each with whatever
 * is known beside the note about that name (its id, email, who assigned them).
 */
export function noteAssignees(m: Y.Map<unknown>, row: TextRow): ChecklistAssignee[] {
  if (!row.assignees.length) return []
  const known = readAssigneeList(m.get(assigneesKey(row.label)))
  return row.assignees.map(name => {
    const k = known.find(p => fold(p.name) === fold(name))
    return k ? { ...k, name } : { name }
  })
}

/** How many rows picked each column, in column order. */
export function tally(columns: readonly string[], rows: readonly ChecklistRow[], picks: Readonly<Record<string, ChecklistPick>>) {
  const out: Record<string, number> = {}
  for (const c of columns) out[c] = 0
  for (const row of rows) {
    const p = picks[row.id]
    if (p && p.col in out) out[p.col]!++
  }
  return out
}

// ---- size -------------------------------------------------------------------------

/** Layout numbers shared with ChecklistView (world px). */
export const CHECKLIST_LAYOUT = {
  /** Title band, its padding and its rule. */
  head: 49,
  /** Column header band (several columns only). */
  columnsHead: 28,
  row: 34,
  /** A row's collapsed comment: one muted line under it. */
  note: 22,
  /** Padding around the rows and the card's border. */
  foot: 14,
  /** One choice column. */
  col: 64,
  /** The label column's room in a fresh card. */
  label: 168,
  pad: 14,
} as const

export const CHECKLIST_MIN = { w: 200, h: 72 } as const

/** A fresh card's width for this many columns. */
export function checklistWidth(columns: number): number {
  const L = CHECKLIST_LAYOUT
  return columns <= 1 ? 280 : L.pad * 2 + L.label + L.col * columns
}

/** The height a card needs before anyone has measured it (one line per label, one per comment). */
export function checklistHeight(columns: number, rows: number, notes = 0): number {
  const L = CHECKLIST_LAYOUT
  return L.head + (columns > 1 ? L.columnsHead : 0) + L.row * Math.max(rows, 1) + L.note * notes + L.foot
}

// ---- writes (inside a transaction) -----------------------------------------------

export interface Picker {
  name: string
  id: string
}

/** Set (or with `col` null, clear) one row's pick. Touches no other row. */
export function writePick(m: Y.Map<unknown>, rowId: string, col: string | null, by: Picker, at = Date.now()) {
  const key = pickKey(rowId)
  if (col === null) {
    if (m.has(key)) m.delete(key)
    return
  }
  m.set(key, { col, by: by.name, byId: by.id, at })
}

/**
 * New columns. Picks follow a rename (`renames[old] = new`) or a column whose
 * label is unchanged but for case; a pick naming a column that has gone is
 * dropped.
 */
export function writeColumns(m: Y.Map<unknown>, next: readonly string[], renames: Readonly<Record<string, string>> = {}) {
  m.set('columns', [...next])
  const byFold = new Map(next.map(c => [fold(c), c] as const))
  for (const key of [...m.keys()]) {
    if (!key.startsWith(PICK_PREFIX)) continue
    const pick = readPick(m.get(key))
    if (!pick) {
      m.delete(key)
      continue
    }
    const to = renames[pick.col] ?? byFold.get(fold(pick.col))
    if (!to || !next.includes(to)) m.delete(key)
    else if (to !== pick.col) m.set(key, { ...pick, col: to })
  }
}

/** New rows; the picks and comments of rows that are gone go with them. */
export function writeRows(m: Y.Map<unknown>, next: readonly ChecklistRow[]) {
  m.set(
    'rows',
    next.map(r => ({ id: r.id, label: r.label }))
  )
  const keep = new Set(next.flatMap(r => [pickKey(r.id), noteKey(r.id), legacyAssigneesKey(r.id)]))
  for (const key of [...m.keys()])
    if ((key.startsWith(PICK_PREFIX) || key.startsWith(NOTE_PREFIX) || key.startsWith(ASSIGNEES_PREFIX)) && !keep.has(key)) m.delete(key)
}

/** Set (or with '' clear) a legacy card's comment on one row. Touches no other row. */
export function writeLegacyNote(m: Y.Map<unknown>, rowId: string, text: string, by: Picker, at = Date.now()) {
  const key = noteKey(rowId)
  if (!text) {
    if (m.has(key)) m.delete(key)
    return
  }
  m.set(key, { text, by: by.name, byId: by.id, at })
}

// ---- a note shown as a checklist (checklist-text.ts) -----------------------------

/** Whether a shape is drawn as a checklist card: either stored form. */
export const isChecklist = (s: { type: string; view?: string } | null | undefined): boolean =>
  !!s && (s.type === 'checklist' || (s.type === 'sticky' && s.view === VIEW_CHECKLIST))

/** A note's columns: its own, else one column of ticks. */
export const readNoteColumns = (v: unknown) => readColumns(v, [TICK_COLUMN])

/** The id a note's row goes by on the board: its place among the rows. */
export const noteRowId = (index: number) => `t${index}`
const noteRowIndex = (id: string) => (/^t\d{1,4}$/.test(id) ? Number(id.slice(1)) : -1)

/** Who picked a note's row, when that still agrees with the text. */
function noteWho(m: Y.Map<unknown>, row: TextRow): ChecklistPick | null {
  if (!row.pick) return null
  const who = readPick(m.get(whoKey(row.label)))
  return who && fold(who.col) === fold(row.pick) ? { ...who, col: row.pick } : null
}

/** A note's checklist as the board reads it. */
export function readNoteChecklist(m: Y.Map<unknown>, text: string) {
  const columns = readNoteColumns(m.get('columns'))
  const parsed = parseChecklistText(text, columns)
  const rows: ChecklistRow[] = parsed.rows.map(r => ({ id: noteRowId(r.index), label: r.label }))
  const picks: Record<string, ChecklistPick> = {}
  const notes: Record<string, ChecklistNote> = {}
  const assignees: Record<string, ChecklistAssignee[]> = {}
  for (const r of parsed.rows) {
    if (r.note) notes[noteRowId(r.index)] = { text: r.note, ...(readNoteBy(m.get(noteByKey(r.label))) ?? { by: '', byId: '', at: 0 }) }
    if (r.assignees.length) assignees[noteRowId(r.index)] = noteAssignees(m, r)
    if (!r.pick) continue
    picks[noteRowId(r.index)] = noteWho(m, r) ?? { col: r.pick, by: '', byId: '', at: 0 }
  }
  return { title: parsed.title, columns, rows, picks, notes, assignees }
}

/** The note's row `id` (or, when the text moved under it, the row with that label). */
function noteRow(parsed: ParsedChecklist, id: string, label?: string): TextRow | null {
  const at = parsed.rows[noteRowIndex(id)]
  if (at && (label === undefined || at.label === label)) return at
  if (label === undefined) return null
  return parsed.rows.find(r => r.label === label) ?? null
}

/** Set (or with '' clear) a note row's comment and who wrote it. */
export function writeNoteNote(m: Y.Map<unknown>, t: Y.Text, row: TextRow, text: string, by: Picker, at = Date.now()) {
  writeRowNote(t, row, text)
  const key = noteByKey(row.label)
  if (text) m.set(key, { by: by.name, byId: by.id, at })
  else if (m.has(key)) m.delete(key)
}

/** What an assignee keeps beside the note: who they are and who assigned them (the name is the text's). */
export const storedAssignee = (p: ChecklistAssignee) => {
  const out: Record<string, unknown> = { name: p.name }
  for (const k of ['id', 'email', 'by', 'byId', 'at'] as const) if (p[k] !== undefined && p[k] !== '') out[k] = p[k]
  return out
}

/**
 * The people on a row as they will be, from `next` (names, or people with
 * ids): who stays keeps who assigned them and when; who is new is assigned
 * by `by`, now. Also who is new, for the notification.
 */
export function mergeAssignees(now: readonly ChecklistAssignee[], next: readonly ChecklistAssignee[], by: Picker, at = Date.now()) {
  const out: ChecklistAssignee[] = []
  const added: ChecklistAssignee[] = []
  for (const raw of next) {
    const name = assigneeName(raw.name)
    if (!name) continue
    const p: ChecklistAssignee = { ...raw, name }
    if (out.some(o => samePerson(o, p))) continue
    const was = now.find(o => samePerson(o, p))
    if (was) out.push({ ...was, ...p, ...(was.by ? { by: was.by, byId: was.byId } : {}), ...(was.at ? { at: was.at } : {}) })
    else {
      const fresh: ChecklistAssignee = { ...p, by: by.name, byId: by.id, at }
      out.push(fresh)
      added.push(fresh)
    }
    if (out.length === MAX_ASSIGNEES) break
  }
  return { people: out, added }
}

/** Set a note row's assignees: their `@` lines, and who they are beside the note. */
export function writeNoteAssignees(m: Y.Map<unknown>, t: Y.Text, row: TextRow, people: readonly ChecklistAssignee[]) {
  writeRowAssignees(
    t,
    row,
    people.map(p => p.name)
  )
  const key = assigneesKey(row.label)
  if (people.length) m.set(key, people.map(storedAssignee))
  else if (m.has(key)) m.delete(key)
}

/** Set (or clear) a note row's pick and who made it. */
export function writeNotePick(m: Y.Map<unknown>, t: Y.Text, row: TextRow, col: string | null, columns: readonly string[], by: Picker, at = Date.now()) {
  writeRowPick(t, row, col, columns)
  const key = whoKey(row.label)
  if (col) m.set(key, { col, by: by.name, byId: by.id, at })
  else if (m.has(key)) m.delete(key)
}

/**
 * New columns for a note. Each row keeps its pick when the column stays
 * (renamed via `renames`, or the same name in any case) and loses it when the
 * column goes; only lines whose meaning would change are rewritten.
 */
export function writeNoteColumns(m: Y.Map<unknown>, next: readonly string[], renames: Readonly<Record<string, string>> = {}) {
  const t = noteText(m)
  const old = readNoteColumns(m.get('columns'))
  const before = parseChecklistText(t.toString(), old)
  const after = parseChecklistText(t.toString(), next)
  const byFold = new Map(next.map(c => [fold(c), c] as const))
  const want = (pick: string | null) => {
    if (!pick) return null
    const to = renames[pick] ?? byFold.get(fold(pick))
    return to && next.includes(to) ? to : null
  }
  // Last row first: each write stays inside its own line, so earlier offsets hold.
  for (let i = before.rows.length - 1; i >= 0; i--) {
    const row = before.rows[i]!
    const to = want(row.pick)
    const now = after.rows[i]
    if (now && now.pick === to && now.label === row.label && !(next.length === 1 && row.suffix)) continue
    writeRowPick(t, row, to, next)
  }
  m.set('columns', [...next])
  for (const key of [...m.keys()]) {
    if (!key.startsWith(WHO_PREFIX)) continue
    const who = readPick(m.get(key))
    const to = who ? want(who.col) : null
    if (!who || !to) m.delete(key)
    else if (to !== who.col) m.set(key, { ...who, col: to })
  }
}

// ---- what the board does ---------------------------------------------------------

type Current =
  | { kind: 'legacy'; m: Y.Map<unknown>; rows: ChecklistRow[]; columns: string[] }
  | { kind: 'note'; m: Y.Map<unknown>; t: Y.Text; columns: string[]; parsed: ParsedChecklist; rows: ChecklistRow[] }

/** The live map and its rows and columns (inside a transaction the snapshot lags). */
function current(store: CanvasStore, id: string): Current | null {
  const m = store.shapes.get(id)
  if (!m) return null
  if (m.get('type') === 'checklist') return { kind: 'legacy', m, rows: readRows(m.get('rows')), columns: readColumns(m.get('columns')) }
  if (m.get('type') !== 'sticky' || m.get('view') !== VIEW_CHECKLIST) return null
  const t = noteText(m)
  const columns = readNoteColumns(m.get('columns'))
  const parsed = parseChecklistText(t.toString(), columns)
  return { kind: 'note', m, t, columns, parsed, rows: parsed.rows.map(r => ({ id: noteRowId(r.index), label: r.label })) }
}

function touch(m: Y.Map<unknown>) {
  m.set('updatedAt', Date.now())
}

/**
 * One click on a cell: pick it, or clear it when it is already the pick.
 * `label` is the row's label as the click saw it: should the note's text
 * have moved under the click, the row with that label is the one meant.
 */
export function togglePick(store: CanvasStore, id: string, rowId: string, col: string, by: Picker, origin: Origin = 'local', label?: string) {
  store.transact(() => {
    const c = current(store, id)
    if (!c || !c.columns.includes(col)) return
    if (c.kind === 'note') {
      const row = noteRow(c.parsed, rowId, label)
      if (!row) return
      writeNotePick(c.m, c.t, row, row.pick === col ? null : col, c.columns, by)
      touch(c.m)
      return
    }
    if (!c.rows.some(r => r.id === rowId)) return
    const now = readPick(c.m.get(pickKey(rowId)))
    writePick(c.m, rowId, now?.col === col ? null : col, by)
    touch(c.m)
  }, origin)
}

/** The card's title. */
export function setTitle(store: CanvasStore, id: string, title: string, origin: Origin = 'local') {
  store.transact(() => {
    const c = current(store, id)
    if (!c) return
    const clean = oneLine(title).slice(0, 500)
    if (c.kind === 'note') {
      if (c.parsed.title === clean) return
      writeTitle(c.t, c.parsed, clean)
    } else {
      if (c.m.get('title') === clean) return
      c.m.set('title', clean)
    }
    touch(c.m)
  }, origin)
}

export function setRowLabel(store: CanvasStore, id: string, rowId: string, label: string, origin: Origin = 'local') {
  store.transact(() => {
    const c = current(store, id)
    if (!c) return
    const clean = label.slice(0, MAX_ROW_LABEL)
    if (c.kind === 'note') {
      const row = noteRow(c.parsed, rowId)
      const next = oneLine(clean)
      if (!row || row.label === next) return
      // Who picked it, who wrote its comment and who its assignees are follow the row to its new name.
      const alone = !c.parsed.rows.some(r => r !== row && rowKey(r.label) === rowKey(row.label))
      for (const key of [whoKey, noteByKey, assigneesKey]) {
        const from = key(row.label)
        const to = key(next)
        const value = c.m.get(from)
        if (from === to || value === undefined || !alone) continue
        c.m.delete(from)
        if (next.trim()) c.m.set(to, value)
      }
      writeRowLabel(c.t, row, next)
      touch(c.m)
      return
    }
    if (!c.rows.some(r => r.id === rowId && r.label !== clean)) return
    writeRows(
      c.m,
      c.rows.map(r => (r.id === rowId ? { ...r, label: clean } : r))
    )
    touch(c.m)
  }, origin)
}

/** A new row after `after` (or at the end); its id, or null when the list is full. */
export function addRow(store: CanvasStore, id: string, after: string | null = null, label = '', origin: Origin = 'local'): string | null {
  let made: string | null = null
  store.transact(() => {
    const c = current(store, id)
    if (!c || c.rows.length >= MAX_ROWS) return
    if (c.kind === 'note') {
      const ref = after ? noteRow(c.parsed, after) : null
      if (after && !ref) return
      const index = insertRowLine(c.t, c.parsed, ref ? ref.index : null, rowLine(label.slice(0, MAX_ROW_LABEL), null, c.columns))
      touch(c.m)
      made = noteRowId(index)
      return
    }
    const row = { id: newRowId(), label: label.slice(0, MAX_ROW_LABEL) }
    const at = after ? c.rows.findIndex(r => r.id === after) + 1 : c.rows.length
    const next = [...c.rows]
    next.splice(at > 0 ? at : c.rows.length, 0, row)
    writeRows(c.m, next)
    touch(c.m)
    made = row.id
  }, origin)
  return made
}

export function removeRow(store: CanvasStore, id: string, rowId: string, origin: Origin = 'local') {
  store.transact(() => {
    const c = current(store, id)
    if (!c) return
    if (c.kind === 'note') {
      const row = noteRow(c.parsed, rowId)
      if (!row) return
      removeRowLine(c.t, row)
      if (!c.parsed.rows.some(r => r !== row && rowKey(r.label) === rowKey(row.label))) {
        c.m.delete(whoKey(row.label))
        c.m.delete(noteByKey(row.label))
        c.m.delete(assigneesKey(row.label))
      }
      touch(c.m)
      return
    }
    if (!c.rows.some(r => r.id === rowId)) return
    writeRows(
      c.m,
      c.rows.filter(r => r.id !== rowId)
    )
    touch(c.m)
  }, origin)
}

/**
 * One row's comment, as typed: '' clears it. Only that row's comment lines
 * (or, on a legacy card, its `note:` key) change. `label` is as for
 * `togglePick`: should the text have moved under the editor, the row with
 * that label is the one meant.
 */
export function setRowNote(store: CanvasStore, id: string, rowId: string, text: string, by: Picker, origin: Origin = 'local', label?: string) {
  store.transact(() => {
    const c = current(store, id)
    if (!c) return
    const clean = cleanNote(text)
    if (c.kind === 'note') {
      const row = noteRow(c.parsed, rowId, label)
      if (!row || row.note === clean) return
      writeNoteNote(c.m, c.t, row, clean, by)
      touch(c.m)
      return
    }
    if (!c.rows.some(r => r.id === rowId)) return
    if ((readLegacyNote(c.m.get(noteKey(rowId)))?.text ?? '') === clean) return
    writeLegacyNote(c.m, rowId, clean, by)
    touch(c.m)
  }, origin)
}

/** A row's assignees as they are now, on either form. */
function currentAssignees(c: Current, row: TextRow | ChecklistRow): ChecklistAssignee[] {
  if (c.kind === 'note') return noteAssignees(c.m, row as TextRow)
  return readAssigneeList(c.m.get(legacyAssigneesKey((row as ChecklistRow).id)))
}

/**
 * Set the people a row is assigned to (none clears it). Who stays keeps who
 * assigned them; who is new is assigned by `by`. Returns who is new (for the
 * notification), or null when the row is not there. `label` is as for
 * `togglePick`.
 */
export function setRowAssignees(
  store: CanvasStore,
  id: string,
  rowId: string,
  next: readonly ChecklistAssignee[],
  by: Picker,
  origin: Origin = 'local',
  label?: string
): ChecklistAssignee[] | null {
  let added: ChecklistAssignee[] | null = null
  store.transact(() => {
    const c = current(store, id)
    if (!c) return
    const row = c.kind === 'note' ? noteRow(c.parsed, rowId, label) : c.rows.find(r => r.id === rowId)
    if (!row) return
    const now = currentAssignees(c, row)
    const merged = mergeAssignees(now, next, by)
    added = merged.added
    const same = merged.people.length === now.length && merged.people.every((p, i) => p.name === now[i]!.name && p.id === now[i]!.id)
    if (same) return
    if (c.kind === 'note') writeNoteAssignees(c.m, c.t, row as TextRow, merged.people)
    else {
      const key = legacyAssigneesKey(rowId)
      if (merged.people.length) c.m.set(key, merged.people.map(storedAssignee))
      else if (c.m.has(key)) c.m.delete(key)
    }
    touch(c.m)
  }, origin)
  return added
}

/** Add someone to a row, or take them off it when they are on it already. True: they are on it now. */
export function toggleAssignee(
  store: CanvasStore,
  id: string,
  rowId: string,
  person: ChecklistAssignee,
  by: Picker,
  origin: Origin = 'local',
  label?: string
): { on: boolean; added: ChecklistAssignee[] } {
  const shape = store.live(id)
  const row = shape?.rows?.find(r => r.id === rowId && (label === undefined || r.label === label)) ?? shape?.rows?.find(r => r.label === label)
  const now = (row && shape?.assignees?.[row.id]) ?? []
  const on = now.some(p => samePerson(p, person))
  const next = on ? now.filter(p => !samePerson(p, person)) : [...now, person]
  const added = setRowAssignees(store, id, row?.id ?? rowId, next, by, origin, row?.label ?? label) ?? []
  return { on: !on, added }
}

/** A label for a new column: Maybe after Yes / No, else Option N. */
export function nextColumnLabel(columns: readonly string[]): string {
  const taken = new Set(columns.map(fold))
  if (taken.has('yes') && taken.has('no') && !taken.has('maybe')) return 'Maybe'
  for (let n = columns.length + 1; ; n++) if (!taken.has(`option ${n}`)) return `Option ${n}`
}

/** New columns on either form; picks follow `renames`, picks of columns that went are dropped. */
function setColumns(c: Current, next: string[], renames: Record<string, string> = {}) {
  if (c.kind === 'note') writeNoteColumns(c.m, next, renames)
  else writeColumns(c.m, next, renames)
}

/** Add a column at the end; its index, or -1 when there are four already. */
export function addColumn(store: CanvasStore, id: string, label?: string, origin: Origin = 'local'): number {
  let index = -1
  store.transact(() => {
    const c = current(store, id)
    if (!c || c.columns.length >= MAX_COLUMNS) return
    const clean = (label ?? nextColumnLabel(c.columns)).trim().slice(0, MAX_COLUMN_LABEL)
    if (!clean || c.columns.some(o => fold(o) === fold(clean))) return
    setColumns(c, [...c.columns, clean])
    touch(c.m)
    index = c.columns.length
  }, origin)
  return index
}

/**
 * Rename column `index`; its picks follow. An empty or duplicate name changes
 * nothing (false).
 */
export function renameColumn(store: CanvasStore, id: string, index: number, label: string, origin: Origin = 'local'): boolean {
  let done = false
  store.transact(() => {
    const c = current(store, id)
    const old = c?.columns[index]
    if (!c || old === undefined) return
    const clean = label.trim().slice(0, MAX_COLUMN_LABEL)
    if (!clean || clean === old) return
    if (c.columns.some((o, i) => i !== index && fold(o) === fold(clean))) return
    setColumns(
      c,
      c.columns.map((o, i) => (i === index ? clean : o)),
      { [old]: clean }
    )
    touch(c.m)
    done = true
  }, origin)
  return done
}

/** Remove column `index` and its picks; the last column stays. */
export function removeColumn(store: CanvasStore, id: string, index: number, origin: Origin = 'local') {
  store.transact(() => {
    const c = current(store, id)
    if (!c || c.columns.length <= 1 || index < 0 || index >= c.columns.length) return
    setColumns(
      c,
      c.columns.filter((_, i) => i !== index)
    )
    touch(c.m)
  }, origin)
}

// ---- agent input (ops.ts; mirrored by the cloud) ----------------------------------

/** A checklist value an op got wrong: the message names it, as the page reports it. */
export class ChecklistInputError extends Error {}
const bad = (message: string): never => {
  throw new ChecklistInputError(message)
}

/** `columns`: 1–4 distinct non-empty strings, each cut to 40 characters. */
export function cleanColumns(v: unknown): string[] {
  if (!Array.isArray(v) || v.length < 1 || v.length > MAX_COLUMNS) bad('`columns` must be a list of 1 to 4 names')
  const out: string[] = []
  for (const c of v as unknown[]) {
    if (typeof c !== 'string' || !c.trim()) bad('`columns` names must be non-empty strings')
    const name = (c as string).trim().slice(0, MAX_COLUMN_LABEL)
    if (out.some(o => fold(o) === fold(name))) bad(`\`columns\` has ${JSON.stringify(name)} twice`)
    out.push(name)
  }
  return out
}

/**
 * `rows`: up to 60 labels (`"Ann"`) or `{label, id?}`. A row keeps its id —
 * and so its pick — when it names an existing row's id, or failing that has
 * the same label as an existing row not yet taken.
 */
export function cleanRows(v: unknown, existing: readonly ChecklistRow[] = []): ChecklistRow[] {
  if (!Array.isArray(v)) return bad('`rows` must be a list of labels or {label, id?}')
  if (v.length > MAX_ROWS) bad(`\`rows\`: at most ${MAX_ROWS} rows`)
  const given = (v as unknown[]).map(r => {
    if (typeof r === 'string') return { label: r.trim().slice(0, MAX_ROW_LABEL), id: null as string | null }
    const o = plain(r)
    if (!o) return bad('`rows` must be a list of labels or {label, id?}')
    const label = o.label ?? o.text ?? o.title ?? ''
    if (typeof label !== 'string') bad('`rows`: a label must be a string')
    let id: string | null = null
    if (o.id !== undefined && o.id !== null) {
      if (typeof o.id !== 'string' || !ROW_ID.test(o.id)) bad('`rows`: an id must be 1–32 of A–Z a–z 0–9 _ -')
      id = o.id as string
    }
    return { label: (label as string).trim().slice(0, MAX_ROW_LABEL), id }
  })
  const taken = new Set<string>()
  for (const g of given) {
    if (!g.id) continue
    if (taken.has(g.id)) bad(`\`rows\`: id ${g.id} is used twice`)
    taken.add(g.id)
  }
  const out: ChecklistRow[] = []
  for (const g of given) {
    let id = g.id
    if (!id) {
      const same = existing.find(r => r.label === g.label && !taken.has(r.id))
      id = same ? same.id : null
      while (!id || taken.has(id)) id = newRowId()
      taken.add(id)
    }
    out.push({ id, label: g.label })
  }
  return out
}

/** The row `ref` names: its id, its label, or its label in any case. `field` names the op's key in a complaint. */
export function findRow(rows: readonly ChecklistRow[], ref: string, field = 'picks'): ChecklistRow {
  const byId = rows.find(r => r.id === ref)
  if (byId) return byId
  for (const same of [(r: ChecklistRow) => r.label === ref, (r: ChecklistRow) => fold(r.label) === fold(ref)]) {
    const hits = rows.filter(same)
    if (hits.length === 1) return hits[0]!
    if (hits.length > 1) return bad(`\`${field}\`: more than one row is called ${JSON.stringify(ref)} — use its id`)
  }
  return bad(`\`${field}\`: no row ${JSON.stringify(ref)}`)
}

/**
 * `picks`: `{rowIdOrLabel: column | true | null}` → `[rowId, column | null]`.
 * A column is named in any case; `true` is the first column; null, false or
 * "" clears the row.
 */
export function cleanPicks(v: unknown, rows: readonly ChecklistRow[], columns: readonly string[]): [string, string | null][] {
  const o = plain(v)
  if (!o) return bad('`picks` must be an object like {"Ann": "Yes"}')
  const out = new Map<string, string | null>()
  for (const [ref, value] of Object.entries(o)) {
    const row = findRow(rows, ref)
    let col: string | null
    if (value === null || value === false || value === '') col = null
    else if (value === true) col = columns[0]!
    else if (typeof value === 'string') {
      const hit = columns.find(c => fold(c) === fold(value))
      col = hit ?? bad(`\`picks\`: no column ${JSON.stringify(value)} (${columns.join(', ')})`)
    } else return bad('`picks` values must be a column name, true or null')
    out.set(row.id, col)
  }
  return [...out]
}

/**
 * `notes`: `{rowIdOrLabel: text | null}` → `[rowId, text]`, '' clearing the
 * row's comment (null, false and "" all clear). Text is cut to `MAX_NOTE`.
 */
export function cleanNotes(v: unknown, rows: readonly ChecklistRow[]): [string, string][] {
  const o = plain(v)
  if (!o) return bad('`notes` must be an object like {"Ann": "Back at 6"}')
  const out = new Map<string, string>()
  for (const [ref, value] of Object.entries(o)) {
    const row = findRow(rows, ref, 'notes')
    if (value === null || value === false) out.set(row.id, '')
    else if (typeof value === 'string') out.set(row.id, cleanNote(value))
    else return bad('`notes` values must be text or null')
  }
  return [...out]
}

/** Someone an agent or the picker can name: a person on the canvas. */
export interface Person {
  id: string
  name: string
  email?: string
}

/**
 * One assignee as an agent names them — a name, an email or a user id (or
 * `{name, id?, email?}`) — resolved against the people on the canvas: their
 * id, email, name, or the start of their name; else a name of its own (an
 * email that is nobody's is kept as both).
 */
export function resolveAssignee(v: unknown, people: readonly Person[] = []): ChecklistAssignee {
  const o = typeof v === 'string' ? { name: v } : plain(v)
  if (!o) return bad('`assignees` names must be strings like "Ann" or "ann@example.com"')
  const said = [o.id, o.email, o.name].find((x): x is string => typeof x === 'string' && !!x.trim())
  if (!said) return bad('`assignees`: each needs a name, an email or an id')
  const key = said.trim().replace(/^@+/, '').toLowerCase()
  // The start of a name only when it is one person's.
  const starts = key.length >= 2 ? people.filter(p => p.name.toLowerCase().startsWith(key)) : []
  const hit =
    people.find(p => p.id.toLowerCase() === key) ??
    people.find(p => !!p.email && p.email.toLowerCase() === key) ??
    people.find(p => p.name.toLowerCase() === key) ??
    (starts.length === 1 ? starts[0] : undefined)
  if (hit) return { name: assigneeName(hit.name) || assigneeName(hit.email ?? '') || 'Someone', id: hit.id.toLowerCase(), ...(hit.email ? { email: hit.email } : {}) }
  const name = assigneeName(typeof o.name === 'string' && o.name.trim() ? o.name : said)
  if (!name) return bad('`assignees`: a name must have letters in it')
  const email = typeof o.email === 'string' && o.email.includes('@') ? o.email.trim() : said.includes('@') && !/\s/.test(said.trim()) ? said.trim() : ''
  return { name, ...(email ? { email } : {}) }
}

/**
 * `assignees`: `{rowIdOrLabel: [who, …] | null}` → `[rowId, people]`, an
 * empty list (null, false or []) clearing the row. Each `who` is resolved by
 * `resolveAssignee`; at most twelve to a row.
 */
export function cleanAssignees(v: unknown, rows: readonly ChecklistRow[], people: readonly Person[] = []): [string, ChecklistAssignee[]][] {
  const o = plain(v)
  if (!o) return bad('`assignees` must be an object like {"Ann": ["Grace Hopper"]}')
  const out = new Map<string, ChecklistAssignee[]>()
  for (const [ref, value] of Object.entries(o)) {
    const row = findRow(rows, ref, 'assignees')
    if (value === null || value === false) {
      out.set(row.id, [])
      continue
    }
    const given = typeof value === 'string' ? [value] : Array.isArray(value) ? value : bad('`assignees` values must be a list of names or null')
    if (given.length > MAX_ASSIGNEES) bad(`\`assignees\`: at most ${MAX_ASSIGNEES} people on a row`)
    const list: ChecklistAssignee[] = []
    for (const g of given) {
      const p = resolveAssignee(g, people)
      if (!list.some(x => samePerson(x, p))) list.push(p)
    }
    out.set(row.id, list)
  }
  return [...out]
}

/** A row's comment as an agent reads it: `note`, and who wrote it and when when known. */
function noteSummary(n: ChecklistNote | undefined, clip: (s: string) => string) {
  if (!n) return {}
  return { note: clip(n.text), ...(n.by ? { noteBy: n.by } : {}), ...(n.at ? { noteAt: n.at } : {}) }
}

/** A row's assignees as an agent reads them: `[{name, id?, email?}]`, only when it has some. */
function assigneeSummary(list: readonly ChecklistAssignee[] | undefined) {
  if (!list?.length) return {}
  return { assignees: list.map(p => ({ name: p.name, ...(p.id ? { id: p.id } : {}), ...(p.email ? { email: p.email } : {}) })) }
}

type Notes = Readonly<Record<string, ChecklistNote>>
type Assignees = Readonly<Record<string, readonly ChecklistAssignee[]>>
const asIs = (s: string) => s

/** The checklist as an agent reads it (`canvas_read`). `clip` shortens a long comment. */
export function summarizeChecklist(
  columns: readonly string[],
  rows: readonly ChecklistRow[],
  picks: Readonly<Record<string, ChecklistPick>>,
  notes: Notes = {},
  clip: (s: string) => string = asIs,
  assignees: Assignees = {}
) {
  return {
    columns: [...columns],
    rows: rows.map(r => {
      const p = picks[r.id]
      const n = { ...noteSummary(notes[r.id], clip), ...assigneeSummary(assignees[r.id]) }
      return p ? { id: r.id, label: r.label, pick: p.col, by: p.by, at: p.at, ...n } : { id: r.id, label: r.label, pick: null, ...n }
    }),
    tally: tally(columns, rows, picks),
  }
}

/** A note's checklist as an agent reads it: rows by label (their place is their id), who and when only when known. */
export function summarizeNoteChecklist(
  columns: readonly string[],
  rows: readonly ChecklistRow[],
  picks: Readonly<Record<string, ChecklistPick>>,
  notes: Notes = {},
  clip: (s: string) => string = asIs,
  assignees: Assignees = {}
) {
  return {
    columns: [...columns],
    rows: rows.map(r => {
      const p = picks[r.id]
      const n = { ...noteSummary(notes[r.id], clip), ...assigneeSummary(assignees[r.id]) }
      if (!p) return { label: r.label, pick: null, ...n }
      return { label: r.label, pick: p.col, ...(p.by ? { by: p.by } : {}), ...(p.at ? { at: p.at } : {}), ...n }
    }),
    tally: tally(columns, rows, picks),
  }
}

/** "just now", "4 min ago", "3 h ago", "yesterday", "Oct 4". */
export function ago(at: number, now = Date.now()): string {
  if (!at) return ''
  const s = Math.max(0, Math.round((now - at) / 1000))
  if (s < 45) return 'just now'
  const m = Math.round(s / 60)
  if (m < 60) return `${m} min ago`
  const h = Math.round(m / 60)
  if (h < 24) return `${h} h ago`
  const d = Math.round(h / 24)
  if (d === 1) return 'yesterday'
  if (d < 7) return `${d} days ago`
  return new Date(at).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

/** Who made a pick and when: "Ann · 4 min ago". */
export const pickedBy = (p: ChecklistPick, now = Date.now()) => [p.by, ago(p.at, now)].filter(Boolean).join(' · ')

/** Plain text for copy and search: the title, then one line per row (its comment quoted under it, then its assignees). */
export function checklistText(
  title: string,
  rows: readonly ChecklistRow[],
  picks: Readonly<Record<string, ChecklistPick>> = {},
  columns: readonly string[] = [],
  notes: Notes = {},
  assignees: Assignees = {}
) {
  const one = columns.length === 1
  const lines = rows.map(r => {
    const p = picks[r.id]
    const line = one ? `- [${p ? 'x' : ' '}] ${r.label}` : p ? `- ${r.label}: ${p.col}` : `- ${r.label}`
    return line + noteBlock(notes[r.id]?.text ?? '') + assigneeBlock((assignees[r.id] ?? []).map(a => a.name))
  })
  return [title.trim(), ...lines].filter(Boolean).join('\n')
}
