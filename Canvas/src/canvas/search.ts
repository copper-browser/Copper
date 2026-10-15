/**
 * Board search (Cmd+F): what the box matches, how hits rank, and where the
 * view flies to show one. Pure: no React, no Yjs.
 *
 * Matching is case- and diacritic-insensitive over the text people see, with
 * markdown stripped first: `**Ship** it` matches "ship it", and a link
 * `[the plan](https://…)` answers to "plan" and to its address. Every query
 * term has to match somewhere in the item (AND). A term at the start of a
 * field beats one at a word start, which beats one mid-word; on equal footing
 * frame titles beat note text.
 */
import { arrowPath } from './arrows'
import { MAX_ZOOM, MIN_ZOOM, type Box, type Point, type Segment, type View } from './geometry'
import { parseMarkdownLite, type Inline } from './markdown-lite'
import { isShown, type CommentThread } from './comments'
import type { Shape } from './types'

export type SearchKind = 'frame' | 'sticky' | 'text' | 'arrow' | 'link' | 'checklist' | 'timeline' | 'comment'

/** A comment thread's search ref: `comment:<threadId>` (never a shape id). */
export const COMMENT_REF = 'comment:'

/** One searchable thing on the board. */
export interface SearchItem {
  /** The shape id, or `comment:<threadId>` for a comment thread. */
  ref: string
  kind: SearchKind
  /** Frame title, link title, arrow label or note text; markdown is fine. */
  text: string
  /** Links: the address, searched as a second field. */
  url?: string
  /** Author: the shape's `by`. */
  by?: string
  /** Top-left on the board; orders hits that tie, top to bottom. */
  at?: Point
}

/** Which part of an item matched best. */
export type SearchField = 'title' | 'text' | 'url'

/** Plain text plus the ranges to mark, half-open `[start, end)`, sorted, disjoint. */
export interface Highlighted {
  text: string
  marks: [number, number][]
}

export interface SearchResult {
  ref: string
  kind: SearchKind
  /** Snippet of the matched text. */
  primary: Highlighted
  /** Links: the address. */
  secondary?: Highlighted
  field: SearchField
  score: number
  by?: string
}

// ---- plain text ------------------------------------------------------------

/** Text that answers for a span of the plain text: a link's address. */
interface Alias {
  start: number
  end: number
  text: string
}

export interface PlainText {
  text: string
  aliases: Alias[]
}

/**
 * Backslash-escaped ASCII punctuation (`\*`) hides in the private use area
 * while markdown-lite parses, which has no escapes, then comes back literal.
 */
const ESCAPED = /\\([!-/:-@[-`{-~])/g
const HIDDEN = /[\ue000-\ue07f]/g
const hide = (s: string) =>
  s.replace(ESCAPED, (_, c: string) =>
    String.fromCharCode(0xe000 + c.charCodeAt(0))
  )
const unhide = (s: string) =>
  s.replace(HIDDEN, c => String.fromCharCode(c.charCodeAt(0) - 0xe000))

/**
 * What a reader sees of some markdown-lite, on one line: marks dropped,
 * `[label](url)` as "label" (with the url kept as an alias of that span),
 * blocks and lines joined by a space.
 */
export function plainText(markdown: string): PlainText {
  let text = ''
  const aliases: Alias[] = []
  const gap = () => {
    if (text && !text.endsWith(' ')) text += ' '
  }
  const walk = (nodes: Inline[]) => {
    for (const n of nodes) {
      if (n.type === 'text' || n.type === 'code') text += unhide(n.text)
      else if (n.type === 'bold' || n.type === 'italic' || n.type === 'strike') walk(n.children)
      else {
        const start = text.length
        const alias = unhide(n.href)
        walk(n.children)
        if (alias !== text.slice(start)) aliases.push({ start, end: text.length, text: alias })
      }
    }
  }
  for (const block of parseMarkdownLite(hide(markdown))) {
    if (block.type === 'heading') {
      gap()
      walk(block.children)
    } else if (block.type === 'paragraph' || block.type === 'quote') {
      for (const line of block.lines) {
        gap()
        walk(line)
      }
    } else {
      for (const item of block.items) {
        gap()
        walk(item.children)
      }
    }
  }
  return { text: text.trimEnd(), aliases }
}

// ---- folding ---------------------------------------------------------------

/** Letters NFD does not take apart. */
const FOLD_EXTRA: Record<string, string> = {
  ß: 'ss',
  æ: 'ae',
  œ: 'oe',
  ø: 'o',
  ł: 'l',
  đ: 'd',
  ð: 'd',
  þ: 'th',
  ı: 'i',
}

export interface Folded {
  text: string
  /** `map[i]` = index in the source of folded char `i`; one extra entry for the end. */
  map: number[]
}

/** Lower case, accents off, with a map back to the source for highlighting. */
export function fold(source: string): Folded {
  let text = ''
  const map: number[] = []
  let i = 0
  for (const ch of source) {
    const lower = ch
      .normalize('NFD')
      .replace(/\p{M}+/gu, '')
      .toLowerCase()
    const f = FOLD_EXTRA[lower] ?? lower
    for (let k = 0; k < f.length; k++) map.push(i)
    text += f
    i += ch.length
  }
  map.push(source.length)
  return { text, map }
}

/** Query → folded terms, markdown punctuation dropped, duplicates removed. */
export function queryTerms(query: string): string[] {
  const words = fold(query)
    .text.replace(/[*`[\]|]/g, ' ')
    .split(/\s+/)
    .filter(Boolean)
  return [...new Set(words)]
}

// ---- matching --------------------------------------------------------------

const AT_START = 2
const AT_WORD = 1
const MID_WORD = 0
const isWordChar = (c: string | undefined) => !!c && /[\p{L}\p{N}]/u.test(c)

/** How well `term` sits in `hay`: start, word start, mid-word; -1 if absent. */
export function matchQuality(hay: string, term: string): number {
  if (!term) return -1
  let best = -1
  for (let i = hay.indexOf(term); i !== -1; i = hay.indexOf(term, i + 1)) {
    if (i === 0) return AT_START
    if (!isWordChar(hay[i - 1])) return AT_WORD
    best = MID_WORD
  }
  return best
}

const WEIGHT: Record<SearchField, number> = {
  title: 3,
  text: 2,
  url: 1,
}
/** Position beats field: a sticky that starts with the term outranks a title that only contains it. */
const termScore = (quality: number, field: SearchField) =>
  quality * 10 + WEIGHT[field] * 3
/** The whole field is the query: "Roadmap" the frame over "Roadmap review". */
const EXACT_BONUS = 15

interface IndexedField {
  field: SearchField
  plain: PlainText
  folded: Folded
  aliases: { start: number; end: number; folded: string }[]
  /** Folded text with runs of space squeezed, for the exact-match bonus. */
  squeezed: string
}

export interface IndexedItem {
  item: SearchItem
  fields: IndexedField[]
}

function indexField(field: SearchField, markdown: string): IndexedField {
  const plain = field === 'url' ? { text: markdown, aliases: [] } : plainText(markdown)
  const folded = fold(plain.text)
  return {
    field,
    plain,
    folded,
    aliases: plain.aliases.map(a => ({ ...a, folded: fold(a.text).text })),
    squeezed: folded.text.replace(/\s+/g, ' ').trim(),
  }
}

/** Fold every item once; search the result as the query changes. */
export function indexSearchItems(items: readonly SearchItem[]): IndexedItem[] {
  return items.map(item => {
    const main = item.kind === 'frame' || item.kind === 'link' ? 'title' : 'text'
    const fields = [indexField(main, item.text)]
    if (item.url) fields.push(indexField('url', item.url))
    return { item, fields }
  })
}

function fieldQuality(f: IndexedField, term: string): number {
  let best = matchQuality(f.folded.text, term)
  for (const a of f.aliases) best = Math.max(best, matchQuality(a.folded, term))
  return best
}

/** Every place the terms occur in a field, as ranges of its plain text. */
function fieldMarks(f: IndexedField, terms: readonly string[]): Highlighted {
  const marks: [number, number][] = []
  const { text, map } = f.folded
  for (const term of terms) {
    for (let i = text.indexOf(term); i !== -1; i = text.indexOf(term, i + 1))
      marks.push([map[i]!, map[i + term.length]!])
    for (const a of f.aliases)
      if (a.folded.includes(term)) marks.push([a.start, a.end])
  }
  return { text: f.plain.text, marks: mergeMarks(marks) }
}

function mergeMarks(marks: [number, number][]): [number, number][] {
  const sorted = marks
    .filter(([a, b]) => b > a)
    .sort((x, y) => x[0] - y[0] || x[1] - y[1])
  const out: [number, number][] = []
  for (const [a, b] of sorted) {
    const last = out[out.length - 1]
    if (last && a <= last[1]) last[1] = Math.max(last[1], b)
    else out.push([a, b])
  }
  return out
}

/** Mark the terms in some text that was not indexed. */
export function markText(text: string, terms: readonly string[]): Highlighted {
  return fieldMarks(indexField('text', text), terms)
}

/** Gap a word-boundary snap may close at either end of a snippet. */
const SNAP = 14

/**
 * Cut text down to about `max` characters centred on the first mark, on
 * word boundaries, with an ellipsis on each cut end. The match stays in the
 * middle, so a row that shows less than `max` still shows it.
 */
export function clipSnippet(h: Highlighted, max = 90): Highlighted {
  const { text, marks } = h
  if (text.length <= max) return h
  const [a, b] = marks[0] ?? [0, 0]
  const mid = Math.floor((a + Math.min(b, a + max)) / 2)
  let start = Math.max(0, Math.min(mid - Math.floor(max / 2), text.length - max))
  let end = Math.min(text.length, start + max)
  // Start on a word, unless that would cut into the match.
  if (start > 0 && text[start - 1] !== ' ') {
    const next = text.indexOf(' ', start)
    if (next !== -1 && next < a && next - start < SNAP) start = next + 1
  }
  // End on a word, likewise.
  if (end < text.length && text[end] !== ' ') {
    const prev = text.lastIndexOf(' ', end)
    if (prev >= b && end - prev < SNAP) end = prev
  }
  while (end > start && text[end - 1] === ' ') end--
  const pre = start > 0 ? '…' : ''
  const post = end < text.length ? '…' : ''
  const shift = pre.length - start
  const kept: [number, number][] = []
  for (const [x, y] of marks) {
    const s = Math.max(x, start)
    const e = Math.min(y, end)
    if (e > s) kept.push([s + shift, e + shift])
  }
  return { text: pre + text.slice(start, end) + post, marks: kept }
}

/** About how many characters of a 13 px snippet fit in a results row `widthPx` wide. */
export function snippetChars(widthPx: number): number {
  // Row padding, the kind icon and its gap take ~48 px; ~6.8 px a character
  // (on the generous side, so the cut snippet fits the row whole).
  const chars = Math.floor((widthPx - 48) / 6.8)
  return Math.max(24, Math.min(120, Number.isFinite(chars) ? chars : 90))
}

const KIND_ORDER: Record<SearchKind, number> = {
  frame: 0,
  link: 1,
  sticky: 2,
  checklist: 2,
  timeline: 2,
  text: 3,
  arrow: 4,
  comment: 5,
}

/** Best first: score, then frames before notes, then top to bottom, left to right. */
function compareHits(
  a: { hit: SearchResult; at?: Point },
  b: { hit: SearchResult; at?: Point }
): number {
  const ay = a.at?.y ?? Infinity
  const by = b.at?.y ?? Infinity
  const ax = a.at?.x ?? Infinity
  const bx = b.at?.x ?? Infinity
  return (
    b.hit.score - a.hit.score ||
    KIND_ORDER[a.hit.kind] - KIND_ORDER[b.hit.kind] ||
    (ay === by ? 0 : ay < by ? -1 : 1) ||
    (ax === bx ? 0 : ax < bx ? -1 : 1) ||
    (a.hit.ref < b.hit.ref ? -1 : a.hit.ref > b.hit.ref ? 1 : 0)
  )
}

/** Every item that matches all terms of `query`, best first. */
export function searchIndex(
  index: readonly IndexedItem[],
  query: string,
  { snippet = 90 }: { snippet?: number } = {}
): SearchResult[] {
  const terms = queryTerms(query)
  if (terms.length === 0) return []
  const phrase = terms.join(' ')
  const hits: { hit: SearchResult; at?: Point }[] = []
  for (const { item, fields } of index) {
    let score = 0
    let best: { field: SearchField; score: number } | null = null
    for (const term of terms) {
      let termBest: { field: SearchField; score: number } | null = null
      for (const f of fields) {
        const q = fieldQuality(f, term)
        if (q < 0) continue
        const s = termScore(q, f.field)
        if (!termBest || s > termBest.score)
          termBest = { field: f.field, score: s }
      }
      if (!termBest) {
        score = -1
        break
      }
      score += termBest.score
      if (!best || termBest.score > best.score) best = termBest
    }
    if (score < 0 || !best) continue
    if (fields.some(f => f.squeezed === phrase)) score += EXACT_BONUS

    const [main, url] = fields
    const hit: SearchResult = {
      ref: item.ref,
      kind: item.kind,
      primary: clipSnippet(fieldMarks(main!, terms), snippet),
      field: best.field,
      score,
    }
    // The address shares its (smaller) line with the author.
    if (url) hit.secondary = clipSnippet(fieldMarks(url, terms), Math.round(snippet * 0.8))
    if (item.by) hit.by = item.by
    hits.push({ hit, at: item.at })
  }
  return hits.sort(compareHits).map(h => h.hit)
}

/** One-shot search over items (tests, small boards). */
export const searchItems = (items: readonly SearchItem[], query: string) =>
  searchIndex(indexSearchItems(items), query)

// ---- what is on the board ----------------------------------------------------

/**
 * The board's searchable things: stickies, text and frames with text, links,
 * checklists (title and row labels), timelines (title, item labels and
 * bubbles), and arrows with a label whose two ends are still on the board.
 */
export function boardSearchItems(shapes: Iterable<Shape>): SearchItem[] {
  const all = [...shapes]
  const boxes = new Map(all.filter(s => s.type !== 'arrow').map(s => [s.id, s] as const))
  const out: SearchItem[] = []
  for (const s of all) {
    let text = ''
    // A timeline answers to its title and its items' words, not its dates' markup.
    if (s.type === 'sticky' && s.timeline)
      text = [s.title, ...s.timeline.items.flatMap(it => [it.label, it.body ?? ''])].filter(t => t.trim()).join('\n')
    else if (s.type === 'sticky' || s.type === 'text') text = s.text
    else if (s.type === 'frame' || s.type === 'link') text = s.title
    else if (s.type === 'arrow') text = s.label ?? ''
    // A checklist answers to its title, every row's label and comment, and who each row is assigned to.
    else if (s.type === 'checklist')
      text = [s.title, ...(s.rows ?? []).flatMap(r => [r.label, s.notes?.[r.id]?.text ?? '', ...(s.assignees?.[r.id] ?? []).map(a => `@${a.name}`)])]
        .filter(t => t.trim())
        .join('\n')
    if (s.type === 'image') continue
    if (!text.trim() && !(s.type === 'link' && s.url)) continue
    if (s.type === 'arrow' && !arrowPath(s, id => boxes.get(id) ?? null)) continue
    // A note in the checklist view is found by its text, and shown as a checklist.
    const item: SearchItem = { ref: s.id, kind: s.view === 'checklist' ? 'checklist' : s.view === 'timeline' ? 'timeline' : s.type, text }
    if (s.type === 'link' && s.url) item.url = s.url
    if (s.type !== 'arrow') item.at = { x: s.x, y: s.y }
    if (s.by) item.by = s.by
    out.push(item)
  }
  return out
}

/**
 * Comment threads, found by what was said in them (deleted messages left
 * out), ranked after shapes and placed where their shape is.
 */
export function commentSearchItems(threads: Iterable<CommentThread>, shapes: ReadonlyMap<string, Shape>): SearchItem[] {
  const out: SearchItem[] = []
  for (const t of threads) {
    if (!isShown(t)) continue
    const text = t.messages
      .filter(m => !m.deleted)
      .map(m => m.text)
      .join('\n')
    if (!text.trim()) continue
    const item: SearchItem = { ref: `${COMMENT_REF}${t.id}`, kind: 'comment', text, by: t.by }
    const s = shapes.get(t.anchor)
    if (s && s.type !== 'arrow') item.at = { x: s.x, y: s.y }
    out.push(item)
  }
  return out
}

// ---- stepping --------------------------------------------------------------

/**
 * Where Enter (`dir` 1) or Shift+Enter (-1) goes: to the highlighted hit if
 * the view is not on it yet, else to its neighbour, wrapping. -1 when empty.
 */
export function stepHit(
  count: number,
  active: number,
  landed: boolean,
  dir: 1 | -1
): number {
  if (count <= 0) return -1
  const at = Math.min(Math.max(active, 0), count - 1)
  return landed ? (at + dir + count) % count : at
}

// ---- flying ----------------------------------------------------------------

/** Zoom at which notes read comfortably. */
export const READABLE_ZOOM = 1

const clampZoom = (z: number) => Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z))

/**
 * The view that shows `box` in a `width` x `height` viewport: centred, at a
 * readable zoom or the zoom that fits it, whichever is smaller, but never
 * zoomed out from where the view already is. A box too big to fit keeps its
 * top-left corner (a frame's title) in view instead of its middle. `top` and
 * `bottom` are how much of the viewport's top (the search box) and bottom
 * (the tool bar) something covers; the box is centred in the part between.
 */
export function revealView(
  box: Box,
  view: View,
  width: number,
  height: number,
  { padding = 64, top = 0, bottom = 0 }: { padding?: number; top?: number; bottom?: number } = {}
): View {
  const inset = Math.min(Math.max(top, 0), height / 2)
  const below = Math.min(Math.max(bottom, 0), (height - inset) / 3)
  const room = height - inset - below
  const fits = Math.min(
    (width - padding * 2) / Math.max(box.w, 1),
    (room - padding * 2) / Math.max(box.h, 1)
  )
  const z = clampZoom(Math.max(view.z, Math.min(READABLE_ZOOM, fits)))
  const axis = (start: number, size: number, from: number, room: number) =>
    size * z > room - padding * 2
      ? from + padding - start * z
      : from + room / 2 - (start + size / 2) * z
  return {
    x: axis(box.x, box.w, 0, width),
    y: axis(box.y, box.h, inset, room),
    z,
  }
}

/** Box an arrow's label sits in: its segment's midpoint. */
export const arrowLabelBox = (seg: Segment): Box => ({
  x: (seg.x1 + seg.x2) / 2 - 80,
  y: (seg.y1 + seg.y2) / 2 - 20,
  w: 160,
  h: 40,
})

const easeInOut = (t: number) =>
  t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2

/** Canvas point at the middle of the viewport. */
const centreOf = (v: View, width: number, height: number): Point => ({
  x: (width / 2 - v.x) / v.z,
  y: (height / 2 - v.y) / v.z,
})

/** How long a flight takes: a beat longer when it crosses the board. */
export function flightMs(from: View, to: View, width: number, height: number) {
  const a = centreOf(from, width, height)
  const b = centreOf(to, width, height)
  const screens =
    (Math.hypot(a.x - b.x, a.y - b.y) * Math.min(from.z, to.z)) / width
  return Math.round(360 + Math.min(1, screens / 3) * 260)
}

/**
 * The view `t` (0..1) of the way through a flight: eased, the middle of the
 * screen gliding between the two centres while zoom changes geometrically.
 * Long hops pull out mid-flight so both ends stay in sight, like a map.
 */
export function flightView(
  from: View,
  to: View,
  t: number,
  width: number,
  height: number
): View {
  if (t >= 1) return to
  if (t <= 0) return from
  const e = easeInOut(t)
  const a = centreOf(from, width, height)
  const b = centreOf(to, width, height)
  const c = { x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e }
  let z = from.z * (to.z / from.z) ** e
  // Zoom at which both ends fit in the viewport along the way.
  const mid = Math.sqrt(from.z * to.z)
  const wanted = Math.min(
    (width * 0.8) / Math.max(Math.abs(a.x - b.x), 1e-6),
    (height * 0.8) / Math.max(Math.abs(a.y - b.y), 1e-6)
  )
  if (wanted < mid)
    z *= (Math.max(wanted, MIN_ZOOM) / mid) ** Math.sin(Math.PI * e)
  return { x: width / 2 - c.x * z, y: height / 2 - c.y * z, z }
}
