/**
 * Comment threads on shapes: who said what about a frame (a slide, a
 * section) or any other shape, with replies, kept in the canvas document so
 * everyone on the board sees them live.
 *
 * Threads live in their own top-level map of the canvas Y.Doc, never in a
 * shape, so a comment and an edit to the shape never touch the same data and
 * older Coppers (and the sync server) simply carry the map along unread:
 *
 *   comments: Y.Map<threadId, Y.Map{
 *     id, anchor (shape id), anchorName (what the shape was called, for when it is gone),
 *     by, byId, at,                                  // who started it, when (ms)
 *     resolved: boolean, resolvedBy?, resolvedById?, resolvedAt?,
 *     messages: Y.Array<Y.Map{id, by, byId, at, text, editedAt?, deleted?}>
 *   }>
 *
 * Every write sets only its own keys: a reply is one push onto `messages`
 * (two people replying at once both land), resolving sets three keys on the
 * thread (a reply at the same moment lands too), an edit sets `text` and
 * `editedAt` on its own message. Deleting a message leaves a tombstone, so a
 * reply racing it is never lost and a thread whose every message is deleted
 * just stops showing. The undo manager watches `shapes` only: ⌘Z never takes
 * back a comment, and a comment never takes a shape edit off the undo stack.
 * A thread outlives its shape: it is listed as on a deleted shape, and comes
 * back to the shape if an undo brings the shape back (same id).
 */
import * as Y from 'yjs'
import type { Shape } from './types'

export const COMMENTS_KEY = 'comments'
/** Transaction origin of comment writes from the board (synced and stored, never undone). */
export const COMMENT = 'comment'
/** Characters in one message. */
export const MAX_COMMENT = 10_000

export interface CommentAuthor {
  id: string
  name: string
}

export interface CommentMessage {
  id: string
  by: string
  byId: string
  /** Epoch ms. */
  at: number
  text: string
  editedAt?: number
  /** Deleted by its author: kept as a tombstone, text cleared. */
  deleted?: true
}

export interface CommentThread {
  id: string
  /** The shape it is on (which may be gone). */
  anchor: string
  /** What that shape was called when last written to; shown once it is deleted. */
  anchorName: string
  by: string
  byId: string
  at: number
  resolved: boolean
  resolvedBy?: string
  resolvedById?: string
  resolvedAt?: number
  /** In order, tombstones included. */
  messages: CommentMessage[]
  /** The newest message's time (or the thread's), for "last activity". */
  lastAt: number
}

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)
const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)
const str = (v: unknown, fallback = ''): string => (typeof v === 'string' ? v : fallback)
const plain = (v: unknown): Record<string, unknown> | null => (v instanceof Y.Map ? (v.toJSON() as Record<string, unknown>) : isObject(v) ? v : null)

export const newCommentId = () =>
  typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`

/** User ids compare lowercased (uuids from the cloud come in either case). */
export const sameAuthor = (a: string, b: string) => !!a && !!b && a.trim().toLowerCase() === b.trim().toLowerCase()

/** Tolerant read of one message (another client, an agent, an older page). */
export function readCommentMessage(v: unknown): CommentMessage | null {
  const o = plain(v)
  if (!o || typeof o.id !== 'string' || !o.id) return null
  const msg: CommentMessage = {
    id: o.id,
    by: str(o.by).trim().slice(0, 120) || 'Someone',
    byId: str(o.byId),
    at: finite(o.at) ? o.at : 0,
    text: str(o.text).slice(0, MAX_COMMENT),
  }
  if (finite(o.editedAt)) msg.editedAt = o.editedAt
  if (o.deleted === true) {
    msg.deleted = true
    msg.text = ''
  }
  return msg
}

function rawMessages(m: Y.Map<unknown>): unknown[] {
  const v = m.get('messages')
  if (v instanceof Y.Array) return v.toArray()
  return Array.isArray(v) ? v : []
}

/** Tolerant read of one thread; null when it is not one. */
export function readThread(id: string, v: unknown): CommentThread | null {
  if (!(v instanceof Y.Map)) return null
  const anchor = v.get('anchor')
  if (typeof anchor !== 'string' || !anchor) return null
  const messages: CommentMessage[] = []
  const seen = new Set<string>()
  for (const raw of rawMessages(v)) {
    const msg = readCommentMessage(raw)
    if (!msg || seen.has(msg.id)) continue
    seen.add(msg.id)
    messages.push(msg)
  }
  const at = v.get('at')
  const thread: CommentThread = {
    id,
    anchor,
    anchorName: str(v.get('anchorName')).slice(0, 200),
    by: str(v.get('by')).trim().slice(0, 120) || messages[0]?.by || 'Someone',
    byId: str(v.get('byId')) || messages[0]?.byId || '',
    at: finite(at) ? at : (messages[0]?.at ?? 0),
    resolved: v.get('resolved') === true,
    messages,
    lastAt: 0,
  }
  if (thread.resolved) {
    const by = v.get('resolvedBy')
    const byId = v.get('resolvedById')
    const when = v.get('resolvedAt')
    if (typeof by === 'string' && by) thread.resolvedBy = by
    if (typeof byId === 'string' && byId) thread.resolvedById = byId
    if (finite(when)) thread.resolvedAt = when
  }
  thread.lastAt = messages.reduce((t, m) => (m.deleted ? t : Math.max(t, m.at, m.editedAt ?? 0)), thread.at)
  return thread
}

/** Messages still standing (not deleted). */
export const liveMessages = (t: CommentThread) => t.messages.filter(m => !m.deleted)

/** A thread shows while any of its messages does. */
export const isShown = (t: CommentThread) => t.messages.some(m => !m.deleted)

/** Replies: live messages after the first. */
export const replyCount = (t: CommentThread) => Math.max(0, liveMessages(t).length - (t.messages[0]?.deleted ? 0 : 1))

/**
 * What a shape is called in a comment's heading: a frame's title, the first
 * line of a note, a checklist's or link's title, an arrow's label.
 */
export function shapeLabel(s: Pick<Shape, 'type' | 'text' | 'title' | 'label' | 'url' | 'view'>): string {
  const firstLine = (t: string) =>
    t
      .split('\n')
      .map(l => l.replace(/^\s*(?:#{1,6}\s+|[-*]\s+(?:\[[ xX]\]\s+)?|>\s?)/, '').replace(/[*_`~]/g, '').trim())
      .find(Boolean) ?? ''
  const clip = (t: string) => (t.length > 80 ? `${t.slice(0, 79).trimEnd()}…` : t)
  switch (s.type) {
    case 'frame':
      return clip(s.title.trim()) || 'Frame'
    case 'sticky':
      if (s.view === 'checklist') return clip(s.title.trim()) || 'Checklist'
      if (s.view === 'timeline') return clip(s.title.trim()) || 'Timeline'
      return clip(firstLine(s.text)) || 'Note'
    case 'text':
      return clip(firstLine(s.text)) || 'Text'
    case 'checklist':
      return clip(s.title.trim()) || 'Checklist'
    case 'link':
      return clip(s.title.trim() || s.url || '') || 'Link'
    case 'image':
      return 'Image'
    case 'arrow':
      return clip((s.label ?? '').trim()) || 'Arrow'
  }
}

/** How long ago, short: "now", "4 min", "3 h", "Yesterday", then the date ("Oct 5", "Oct 5, 2025"). */
export function agoLabel(at: number, now = Date.now()): string {
  const ago = now - at
  if (ago < 45_000) return 'now'
  if (ago < 3_600_000) return `${Math.max(1, Math.round(ago / 60_000))} min`
  const d = new Date(at)
  const today = new Date(now)
  const start = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime()
  const days = Math.round((start(today) - start(d)) / 86_400_000)
  if (days <= 0) return `${Math.max(1, Math.round(ago / 3_600_000))} h`
  if (days === 1) return 'Yesterday'
  const sameYear = d.getFullYear() === today.getFullYear()
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', ...(sameYear ? {} : { year: 'numeric' }) })
}

function messageMap(id: string, text: string, by: CommentAuthor, at: number): Y.Map<unknown> {
  const m = new Y.Map<unknown>()
  m.set('id', id)
  m.set('by', by.name)
  m.set('byId', by.id)
  m.set('at', at)
  m.set('text', text)
  return m
}

/** Text as it is stored: line endings normalised, ends trimmed. Throws when empty or too long. */
export function cleanCommentText(raw: unknown): string {
  if (typeof raw !== 'string') throw new Error('`text` must be a string')
  const text = raw.replace(/\r\n?/g, '\n').trim()
  if (!text) throw new Error('`text` is empty')
  if (text.length > MAX_COMMENT) throw new Error(`a comment holds at most ${MAX_COMMENT} characters`)
  return text
}

type Listener = () => void

/** The threads of one canvas: a snapshot that changes only when they do, and the writes. */
export class CommentStore {
  readonly doc: Y.Doc
  readonly map: Y.Map<unknown>
  private byId = new Map<string, CommentThread>()
  private list: readonly CommentThread[] = []
  private listeners = new Set<Listener>()
  private readonly observer: (events: Y.YEvent<Y.AbstractType<unknown>>[]) => void

  constructor(doc: Y.Doc) {
    this.doc = doc
    this.map = doc.getMap<unknown>(COMMENTS_KEY)
    this.map.forEach((v, id) => {
      const t = readThread(id, v)
      if (t) this.byId.set(id, t)
    })
    this.list = this.sorted()
    this.observer = events => {
      const changed = new Set<string>()
      for (const e of events) {
        if (e.target === this.map) for (const key of e.changes.keys.keys()) changed.add(key)
        else if (typeof e.path[0] === 'string') changed.add(e.path[0])
      }
      if (changed.size === 0) return
      for (const id of changed) {
        const t = readThread(id, this.map.get(id))
        if (t) this.byId.set(id, t)
        else this.byId.delete(id)
      }
      this.list = this.sorted()
      for (const fn of this.listeners) fn()
    }
    this.map.observeDeep(this.observer)
  }

  destroy() {
    this.map.unobserveDeep(this.observer)
    this.listeners.clear()
  }

  private sorted(): readonly CommentThread[] {
    return [...this.byId.values()].sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
  }

  /** Every readable thread, oldest first, tombstoned ones included; a new array only when one changed. */
  getThreads = (): readonly CommentThread[] => this.list

  subscribe = (fn: Listener) => {
    this.listeners.add(fn)
    return () => {
      this.listeners.delete(fn)
    }
  }

  /** Straight from the doc (inside a transaction the snapshot lags). */
  get(id: string): CommentThread | null {
    return readThread(id, this.map.get(id))
  }

  /** Start a thread on `anchor` with its first message; returns the thread id. */
  create(
    anchor: string,
    rawText: string,
    by: CommentAuthor,
    { id, anchorName = '', now = Date.now(), origin = COMMENT }: { id?: string; anchorName?: string; now?: number; origin?: unknown } = {}
  ): string {
    const text = cleanCommentText(rawText)
    const threadId = id && !this.map.has(id) ? id : newCommentId()
    this.doc.transact(() => {
      const t = new Y.Map<unknown>()
      t.set('id', threadId)
      t.set('anchor', anchor)
      t.set('anchorName', anchorName.slice(0, 200))
      t.set('by', by.name)
      t.set('byId', by.id)
      t.set('at', now)
      t.set('resolved', false)
      const messages = new Y.Array<Y.Map<unknown>>()
      messages.push([messageMap(newCommentId(), text, by, now)])
      t.set('messages', messages)
      this.map.set(threadId, t)
    }, origin)
    return threadId
  }

  /** Add onto a thread; returns the new message's id. A resolved thread opens again (as in Docs and Figma). */
  reply(
    threadId: string,
    rawText: string,
    by: CommentAuthor,
    { now = Date.now(), origin = COMMENT, anchorName, reopen = true }: { now?: number; origin?: unknown; anchorName?: string; reopen?: boolean } = {}
  ): string {
    const text = cleanCommentText(rawText)
    const t = this.map.get(threadId)
    if (!(t instanceof Y.Map)) throw new Error(`no comment thread ${threadId}`)
    const id = newCommentId()
    this.doc.transact(() => {
      let messages = t.get('messages')
      if (!(messages instanceof Y.Array)) {
        // Written as a plain list by someone else: carried over once, in order.
        const before = Array.isArray(messages) ? messages : []
        const arr = new Y.Array<unknown>()
        arr.push(
          before
            .map(readCommentMessage)
            .filter((m): m is CommentMessage => !!m)
            .map(m => {
              const mm = messageMap(m.id, m.text, { id: m.byId, name: m.by }, m.at)
              if (m.editedAt) mm.set('editedAt', m.editedAt)
              if (m.deleted) mm.set('deleted', true)
              return mm
            })
        )
        t.set('messages', arr)
        messages = arr
      }
      ;(messages as Y.Array<unknown>).push([messageMap(id, text, by, now)])
      if (anchorName) t.set('anchorName', anchorName.slice(0, 200))
      if (reopen && t.get('resolved') === true) this.writeResolved(t, false, by, now)
    }, origin)
    return id
  }

  private writeResolved(t: Y.Map<unknown>, resolved: boolean, by: CommentAuthor, now: number) {
    t.set('resolved', resolved)
    if (resolved) {
      t.set('resolvedBy', by.name)
      t.set('resolvedById', by.id)
      t.set('resolvedAt', now)
    } else {
      for (const k of ['resolvedBy', 'resolvedById', 'resolvedAt']) if (t.has(k)) t.delete(k)
    }
  }

  /** Resolve (true) or reopen (false). False when there is no such thread. */
  setResolved(threadId: string, resolved: boolean, by: CommentAuthor, { now = Date.now(), origin = COMMENT }: { now?: number; origin?: unknown } = {}): boolean {
    const t = this.map.get(threadId)
    if (!(t instanceof Y.Map)) return false
    if ((t.get('resolved') === true) === resolved) return true
    this.doc.transact(() => this.writeResolved(t, resolved, by, now), origin)
    return true
  }

  private messageAt(threadId: string, messageId: string): Y.Map<unknown> | null {
    const t = this.map.get(threadId)
    if (!(t instanceof Y.Map)) return null
    const messages = t.get('messages')
    if (!(messages instanceof Y.Array)) return null
    for (const m of messages.toArray()) if (m instanceof Y.Map && m.get('id') === messageId) return m
    return null
  }

  /** Change your own message. False when it is not there or not yours. */
  edit(threadId: string, messageId: string, rawText: string, by: CommentAuthor, { now = Date.now(), origin = COMMENT }: { now?: number; origin?: unknown } = {}): boolean {
    const text = cleanCommentText(rawText)
    const m = this.messageAt(threadId, messageId)
    if (!m || m.get('deleted') === true || !sameAuthor(str(m.get('byId')), by.id)) return false
    if (m.get('text') === text) return true
    this.doc.transact(() => {
      m.set('text', text)
      m.set('editedAt', now)
    }, origin)
    return true
  }

  /** Undo a delete of your own message: its words back in the place it had. */
  restore(threadId: string, messageId: string, rawText: string, by: CommentAuthor, { origin = COMMENT }: { origin?: unknown } = {}): boolean {
    const text = cleanCommentText(rawText)
    const m = this.messageAt(threadId, messageId)
    if (!m || !sameAuthor(str(m.get('byId')), by.id)) return false
    this.doc.transact(() => {
      if (m.has('deleted')) m.delete('deleted')
      m.set('text', text)
    }, origin)
    return true
  }

  /** Delete your own message (a tombstone keeps its place). False when it is not there or not yours. */
  remove(threadId: string, messageId: string, by: CommentAuthor, { origin = COMMENT }: { origin?: unknown } = {}): boolean {
    const m = this.messageAt(threadId, messageId)
    if (!m || !sameAuthor(str(m.get('byId')), by.id)) return false
    if (m.get('deleted') === true) return true
    this.doc.transact(() => {
      m.set('deleted', true)
      m.set('text', '')
      if (m.has('editedAt')) m.delete('editedAt')
    }, origin)
    return true
  }
}
