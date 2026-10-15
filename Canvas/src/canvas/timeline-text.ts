/**
 * A timeline kept in a note's own text: a `type:"sticky"` with
 * `view:"timeline"`, whose body is markdown every Copper already draws as a
 * readable note.
 *
 *   ### Q4 launch                                  the title: the first #, ## or ### heading
 *   2026-10-01 → 2026-12-31 · weekly               the range and its step (daily … yearly)
 *
 *   - 2026-10-14 · Kickoff                         a pin: one date (a note)
 *   - 2026-10-20 → 2026-11-03 · Build sprint · blue    a section: a span of days, in a colour
 *   - 2026-11-18 · Launch review · purple
 *     > Bubble body, markdown,                     a pin with quote lines under it is a bubble
 *     > as quote lines under the item.
 *
 * The text is the truth. Dates are ISO (`YYYY-MM-DD`), days only. A trailing
 * ` · <colour>` naming a palette colour is the item's colour; any other
 * segment is part of its label. The first range line outside a list item is
 * the range; without one the view falls back to the items' own span. Lines
 * that are none of these — a person's prose, a half-typed date, a line an
 * older Copper added — are kept as they are and drawn by nobody.
 *
 * Every write changes only the characters of its own lines (the title's, the
 * range's, or one item's line and quote lines), so edits to different items
 * from any two Coppers merge. Items are written in date order; an item whose
 * date moves past its neighbours is lifted out and put back in its place.
 */
import * as Y from 'yjs'
import { textSplice } from './text-diff'

export const VIEW_TIMELINE = 'timeline'

export const STEPS = ['day', 'week', 'month', 'quarter', 'year'] as const
export type Step = (typeof STEPS)[number]
/** The word a range line says for each step. */
export const STEP_WORD: Record<Step, string> = { day: 'daily', week: 'weekly', month: 'monthly', quarter: 'quarterly', year: 'yearly' }
export const DEFAULT_STEP: Step = 'week'

/** The colours an item can wear: the board's palette less white. */
export const ITEM_COLORS = ['yellow', 'pink', 'blue', 'green', 'purple', 'gray'] as const
export type ItemColor = (typeof ITEM_COLORS)[number]

export type ItemKind = 'note' | 'bubble' | 'section'

const STEP_NAMES: Record<string, Step> = {}
for (const [step, words] of Object.entries({
  day: ['d', 'day', 'days', 'daily'],
  week: ['w', 'wk', 'week', 'weeks', 'weekly'],
  month: ['m', 'mo', 'month', 'months', 'monthly'],
  quarter: ['q', 'quarter', 'quarters', 'quarterly'],
  year: ['y', 'yr', 'year', 'years', 'yearly', 'annual', 'annually'],
}))
  for (const w of words) STEP_NAMES[w] = step as Step

/** A step from what a person or an agent wrote: `week`, `weekly`, `Weeks`… null when it is none. */
export function readStep(v: unknown): Step | null {
  return typeof v === 'string' ? (STEP_NAMES[v.trim().toLowerCase()] ?? null) : null
}

/** An item colour from what was written (`Blue`, `grey`); null when it is none. */
export function readItemColor(v: unknown): ItemColor | null {
  if (typeof v !== 'string') return null
  const c = v.trim().toLowerCase()
  if (c === 'grey') return 'gray'
  return (ITEM_COLORS as readonly string[]).includes(c) ? (c as ItemColor) : null
}

// ---- days ---------------------------------------------------------------------------

const DAY_MS = 86_400_000
const ISO = /^(\d{4})-(\d{2})-(\d{2})$/

/** Days since 1970-01-01 for an ISO date, or null when it is not a real day. */
export function dayOf(iso: string): number | null {
  const m = ISO.exec(iso.trim())
  if (!m) return null
  const y = Number(m[1])
  const mo = Number(m[2])
  const d = Number(m[3])
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null
  const t = Date.UTC(y, mo - 1, d)
  const back = new Date(t)
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) return null
  return Math.round(t / DAY_MS)
}

/** The ISO date of a day number. */
export function isoOf(day: number): string {
  const d = new Date(day * DAY_MS)
  const y = d.getUTCFullYear()
  return `${y < 0 ? '-' : ''}${String(Math.abs(y)).padStart(4, '0')}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`
}

/** A real ISO date, as written (trimmed), or null. */
export const cleanIso = (v: unknown): string | null => (typeof v === 'string' && dayOf(v) !== null ? v.trim() : null)

/** Today on this Mac's calendar, as an ISO date. */
export function todayIso(now = new Date()): string {
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`
}

/** `iso` moved by whole months (the day clamped to the month's length). */
export function addMonths(iso: string, months: number): string {
  const m = ISO.exec(iso)
  if (!m) return iso
  const y = Number(m[1])
  const mo = Number(m[2]) - 1 + months
  const ty = y + Math.floor(mo / 12)
  const tm = ((mo % 12) + 12) % 12
  const last = new Date(Date.UTC(ty, tm + 1, 0)).getUTCDate()
  return isoOf(Math.round(Date.UTC(ty, tm, Math.min(Number(m[3]), last)) / DAY_MS))
}

export const addDays = (iso: string, days: number) => {
  const d = dayOf(iso)
  return d === null ? iso : isoOf(d + days)
}

// ---- reading -------------------------------------------------------------------------

const HEADING = /^(#{1,3})(\s+)(.*?)\s*#*\s*$/
const DATE = String.raw`(\d{4}-\d{2}-\d{2})`
const ARROW = String.raw`\s*(?:→|->|–|—|\.\.)\s*`
/** `2026-10-01 → 2026-12-31 · weekly` (the step optional). */
const RANGE_LINE = new RegExp(String.raw`^\s*${DATE}${ARROW}${DATE}(?:\s*·\s*([A-Za-z]+))?\s*$`)
/** `- 2026-10-14 · Kickoff`, `* 2026-10-20 → 2026-11-03 · Sprint · blue`, `- 2026-10-14: Kickoff`. */
const ITEM_LINE = new RegExp(String.raw`^\s*[-*]\s+${DATE}(?:${ARROW}${DATE})?(.*)$`)
/** What follows the dates: ` · label · colour`, `: label`, ` - label` or just ` label`. */
const ITEM_REST = /^(?:\s*[·:]\s*|\s+-\s+|\s+)(.*)$/
/** A bubble's body line under its item: `  > words` (an unindented `>` is taken too). */
const BODY_LINE = /^[ \t]*> ?(.*)$/
const SEP = /\s+·\s+/
/** How this page writes a body line (before its words). */
const BODY_LEAD = '  >'

export interface TextItem {
  /** Order among the item lines, from 0. */
  index: number
  /** The first day (ISO). */
  date: string
  /** A section's last day (ISO); null for a pin. */
  end: string | null
  label: string
  color: ItemColor | null
  /** A bubble's body (its quote lines joined by `\n`); null when it has none (a note, a plain section). */
  body: string | null
  kind: ItemKind
  /** Offsets in the whole text. */
  lineStart: number
  lineEnd: number
  /** Where the item's last line ends: its last body line, else `lineEnd`. */
  blockEnd: number
}

export interface TextRange {
  start: string
  end: string
  step: Step
  /** The step word was given (else the default). */
  stepGiven: boolean
  lineStart: number
  lineEnd: number
}

export interface ParsedTimeline {
  title: string
  /** The title's heading: where its words sit (to the line's end) and where its line ends. */
  heading: { start: number; end: number; lineEnd: number } | null
  range: TextRange | null
  items: TextItem[]
}

/** A label as it is kept: one line, single-spaced at its ends. */
export const oneLine = (s: string) => s.replace(/[\r\n]+/g, ' ')

/** A body as it is kept: `\n` line breaks. */
export const bodyLines = (s: string) => s.replace(/\r\n?/g, '\n')

/** The kind an item is by its shape. */
export const kindOf = (it: { end: string | null; body: string | null }): ItemKind => (it.end ? 'section' : it.body !== null ? 'bubble' : 'note')

/** Split what follows an item's dates into its label and colour. */
function labelAndColor(rest: string): { label: string; color: ItemColor | null } {
  const m = ITEM_REST.exec(rest)
  const body = (m ? (m[1] ?? '') : rest).trim()
  if (!body) return { label: '', color: null }
  const parts = body.split(SEP)
  const last = parts[parts.length - 1] ?? ''
  const color = readItemColor(last)
  if (color && parts.length > 1) return { label: parts.slice(0, -1).join(' · ').trim(), color }
  // A lone segment that names a colour is the colour of an unlabelled item.
  if (color && parts.length === 1 && /^[A-Za-z]+$/.test(last.trim())) return { label: '', color }
  return { label: body, color: null }
}

/** Read the title, the range and the items out of a note's text. Never throws. */
export function parseTimelineText(text: string): ParsedTimeline {
  const out: ParsedTimeline = { title: '', heading: null, range: null, items: [] }
  let at = 0
  /** The item whose body lines may follow, and those lines so far. */
  let open: { item: TextItem; lines: string[] } | null = null
  for (const line of text.split('\n')) {
    const start = at
    const end = start + line.length
    at = end + 1
    if (open) {
      const body = BODY_LINE.exec(line)
      if (body) {
        open.lines.push(body[1] ?? '')
        open.item.body = open.lines.join('\n')
        open.item.kind = kindOf(open.item)
        open.item.blockEnd = end
        continue
      }
      open = null
    }
    const m = ITEM_LINE.exec(line)
    if (m) {
      const a = dayOf(m[1] ?? '')
      const b = m[2] !== undefined ? dayOf(m[2]) : null
      if (a !== null && (m[2] === undefined || b !== null)) {
        const { label, color } = labelAndColor(m[3] ?? '')
        const lo = b !== null && b < a ? b : a
        const hi = b !== null ? Math.max(a, b) : null
        const item: TextItem = {
          index: out.items.length,
          date: isoOf(lo),
          end: hi !== null ? isoOf(hi) : null,
          label,
          color,
          body: null,
          kind: hi !== null ? 'section' : 'note',
          lineStart: start,
          lineEnd: end,
          blockEnd: end,
        }
        out.items.push(item)
        open = { item, lines: [] }
        continue
      }
    }
    if (!out.range) {
      const r = RANGE_LINE.exec(line)
      const a = r ? dayOf(r[1] ?? '') : null
      const b = r ? dayOf(r[2] ?? '') : null
      if (r && a !== null && b !== null) {
        const step = readStep(r[3])
        out.range = {
          start: isoOf(Math.min(a, b)),
          end: isoOf(Math.max(a, b)),
          step: step ?? DEFAULT_STEP,
          stepGiven: step !== null,
          lineStart: start,
          lineEnd: end,
        }
        continue
      }
    }
    if (!out.heading) {
      const h = HEADING.exec(line)
      if (h) {
        const lead = (h[1] ?? '').length + (h[2] ?? '').length
        // The heading's words run to the line's end (or a closing ` ###`), trailing spaces
        // included, so a title typed a key at a time is spliced where it really ends.
        const rest = line.slice(lead)
        const closing = /\s+#+\s*$/.exec(rest)
        const raw = closing ? rest.slice(0, rest.length - closing[0].length) : rest
        out.title = h[3] ?? ''
        out.heading = { start: start + lead, end: start + lead + raw.length, lineEnd: end }
      }
    }
  }
  return out
}

// ---- writing ------------------------------------------------------------------------

export interface ItemFields {
  date: string
  end?: string | null
  label: string
  color?: ItemColor | null
  /** null (or absent): no body (a note, a plain section); a string: a bubble's body ('' is an empty one). */
  body?: string | null
}

/** The range line as this page writes it. */
export const rangeLine = (start: string, end: string, step: Step) => `${start} → ${end} · ${STEP_WORD[step]}`

/** An item's line as this page writes it. */
export function itemLine(it: ItemFields): string {
  let s = `- ${it.date}`
  if (it.end) s += ` → ${it.end}`
  const label = oneLine(it.label).trim()
  if (label) s += ` · ${label}`
  if (it.color) s += ` · ${it.color}`
  return s
}

/** A body's lines as they follow its item's line (each with the line break before it); none for null. */
export function bodyBlock(body: string | null | undefined): string {
  if (body === null || body === undefined) return ''
  return bodyLines(body)
    .split('\n')
    .map(l => `\n${BODY_LEAD}${l ? ` ${l}` : ''}`)
    .join('')
}

/** An item's line and, under it, its body's lines. */
export const itemBlock = (it: ItemFields) => itemLine(it) + bodyBlock(it.body)

const byDate = (a: ItemFields, b: ItemFields) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0)

/** A whole timeline note: the title, the range line, a blank line, then the items in date order. */
export function timelineMarkdown(title: string, range: { start: string; end: string; step: Step }, items: readonly ItemFields[]): string {
  const head: string[] = []
  if (title.trim()) head.push(`### ${oneLine(title).trim()}`)
  head.push(rangeLine(range.start, range.end, range.step))
  const blocks = [...items].sort(byDate).map(itemBlock)
  return blocks.length ? `${head.join('\n')}\n\n${blocks.join('\n')}` : head.join('\n')
}

// ---- writes on the note's Y.Text (inside a transaction) -------------------------------

/** The note's body as a Y.Text (a plain string body becomes one). */
export function noteText(m: Y.Map<unknown>): Y.Text {
  const v = m.get('text')
  if (v instanceof Y.Text) return v
  const t = new Y.Text(typeof v === 'string' ? v : '')
  m.set('text', t)
  return t
}

function splice(t: Y.Text, index: number, remove: number, insert: string) {
  if (remove) t.delete(index, remove)
  if (insert) t.insert(index, insert)
}

/** Replace `prev` (at `index`) by `next`, touching only the characters that differ. */
function spliceWithin(t: Y.Text, index: number, prev: string, next: string) {
  const d = textSplice(prev, next)
  splice(t, index + d.index, d.remove, d.insert)
}

/** The title: the first heading's words, or a new `###` heading on top. */
export function writeTitle(t: Y.Text, parsed: ParsedTimeline, title: string) {
  const next = oneLine(title)
  if (parsed.heading) {
    spliceWithin(t, parsed.heading.start, t.toString().slice(parsed.heading.start, parsed.heading.end), next)
    return
  }
  if (!next.trim()) return
  t.insert(0, t.length ? `### ${next}\n` : `### ${next}`)
}

/** The range line: rewritten in place, or a new one under the title (or on top). */
export function writeRange(t: Y.Text, parsed: ParsedTimeline, start: string, end: string, step: Step) {
  const line = rangeLine(start, end, step)
  if (parsed.range) {
    const text = t.toString()
    spliceWithin(t, parsed.range.lineStart, text.slice(parsed.range.lineStart, parsed.range.lineEnd), line)
    return
  }
  if (parsed.heading) {
    t.insert(parsed.heading.lineEnd, `\n${line}`)
    return
  }
  t.insert(0, t.length ? `${line}\n` : line)
}

/**
 * One item's line and body as `next` says, touching only the characters that
 * differ — its body lines first (they come after the line, so its offsets
 * hold), then the line.
 */
function writeItemInPlace(t: Y.Text, item: TextItem, next: ItemFields) {
  const text = t.toString()
  const prevBody = text.slice(item.lineEnd, item.blockEnd)
  const nextBody = bodyBlock(next.body)
  if (prevBody !== nextBody) {
    // A first body goes in just after the line break that ends the item's
    // line, so a label edit at that line's end at the same moment stays on
    // the line (the last line of the text has no break to follow).
    if (!prevBody && item.lineEnd < text.length) t.insert(item.lineEnd + 1, `${nextBody.slice(1)}\n`)
    else spliceWithin(t, item.lineEnd, prevBody, nextBody)
  }
  const prevLine = text.slice(item.lineStart, item.lineEnd)
  const nextLine = itemLine(next)
  if (prevLine !== nextLine) spliceWithin(t, item.lineStart, prevLine, nextLine)
}

/** Remove an item's line and its body's lines (and one line break with them). */
export function removeItemLines(t: Y.Text, item: TextItem) {
  const length = t.length
  const end = item.blockEnd
  if (end < length) t.delete(item.lineStart, end - item.lineStart + 1)
  else if (item.lineStart > 0) t.delete(item.lineStart - 1, end - item.lineStart + 1)
  else if (end > 0) t.delete(0, end)
}

/**
 * A new item's block where its date puts it: after the last item on or
 * before that day, else before the first item, else after the range line (a
 * blank line between), the title, or at the end. Its index among the items.
 */
export function insertItemLines(t: Y.Text, parsed: ParsedTimeline, fields: ItemFields): number {
  const block = itemBlock(fields)
  const items = parsed.items
  let after: TextItem | null = null
  for (const it of items) if (it.date <= fields.date) after = it
  if (after) {
    // Just after the line break that ends the item's block, when there is
    // one: a body line someone adds to that item at the same moment goes
    // before that break, so it stays that item's rather than the new one's.
    if (after.blockEnd < t.length) t.insert(after.blockEnd + 1, `${block}\n`)
    else t.insert(after.blockEnd, `\n${block}`)
    return after.index + 1
  }
  const first = items[0]
  if (first) {
    t.insert(first.lineStart, `${block}\n`)
    return 0
  }
  const text = t.toString()
  const anchor = parsed.range?.lineEnd ?? parsed.heading?.lineEnd ?? null
  if (anchor !== null) {
    // After the range (or title) and whatever blank lines follow it.
    let at = anchor
    while (at < text.length && text[at] === '\n' && (text[at + 1] === '\n' || at + 1 === text.length)) at++
    if (at >= text.length) t.insert(text.length, text.endsWith('\n') ? (text.endsWith('\n\n') ? block : `\n${block}`) : `\n\n${block}`)
    else t.insert(anchor, `\n\n${block}`)
    return 0
  }
  if (!text) t.insert(0, block)
  else t.insert(text.length, text.endsWith('\n') ? block : `\n${block}`)
  return 0
}

/**
 * Change one item. Its lines change in place while its date keeps it between
 * its neighbours; otherwise it is lifted out and put back where its new date
 * belongs. The item's index afterwards.
 */
export function writeItem(t: Y.Text, parsed: ParsedTimeline, item: TextItem, next: ItemFields): number {
  const prev = parsed.items[item.index - 1]
  const after = parsed.items[item.index + 1]
  const fits = (!prev || prev.date <= next.date) && (!after || next.date <= after.date)
  if (fits) {
    writeItemInPlace(t, item, next)
    return item.index
  }
  removeItemLines(t, item)
  return insertItemLines(t, parseTimelineText(t.toString()), next)
}

/**
 * Replace every item (with its body's lines) by `next`, in date order, where
 * the items were (or under the range line, a blank line between). Lines that
 * are not items stay where they are. One splice of what differs.
 */
export function replaceItems(t: Y.Text, parsed: ParsedTimeline, next: readonly ItemFields[]) {
  const before = t.toString()
  const lines = before.split('\n')
  const starts: number[] = []
  for (let i = 0, at = 0; i < lines.length; i++) {
    starts.push(at)
    at += (lines[i] ?? '').length + 1
  }
  const lineAt = (offset: number) => {
    let lo = 0
    let hi = starts.length - 1
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1
      if ((starts[mid] ?? 0) <= offset) lo = mid
      else hi = mid - 1
    }
    return lo
  }
  const isItem = new Set<number>()
  for (const it of parsed.items) for (let i = lineAt(it.lineStart); i <= lineAt(it.blockEnd); i++) isItem.add(i)
  const blocks = [...next].sort(byDate).map(itemBlock)
  let insertAt = parsed.items[0] ? lineAt(parsed.items[0].lineStart) : -1
  let lead: string[] = []
  if (insertAt < 0) {
    const anchor = parsed.range ? lineAt(parsed.range.lineStart) : parsed.heading ? lineAt(parsed.heading.lineEnd) : -1
    if (anchor < 0) insertAt = lines.length
    else {
      insertAt = anchor + 1
      // A blank line between the range (or title) and the list, unless one is there.
      if (blocks.length && lines[insertAt] !== undefined && lines[insertAt]!.trim() === '') insertAt++
      else if (blocks.length) lead = ['']
    }
  }
  const out: string[] = []
  for (let i = 0; i <= lines.length; i++) {
    if (i === insertAt && blocks.length) out.push(...lead, ...blocks)
    if (i < lines.length && !isItem.has(i)) out.push(lines[i] ?? '')
  }
  // The list was the end of the note: no blank lines left dangling after it.
  if (!blocks.length && parsed.items.length && isItem.has(lines.length - 1)) while (out.length > 1 && out[out.length - 1] === '') out.pop()
  // An empty note does not keep a blank first line.
  while (out.length > 1 && out[0] === '' && before === '') out.shift()
  spliceWithin(t, 0, before, out.join('\n'))
}
