/**
 * The page's chat state: what the host says about chat on this canvas
 * (`copperCanvas.setChat`), the message log read off the open session's
 * document, the read mark, and what the panel is doing. React reads it with
 * `useSyncExternalStore(hub.subscribe, hub.getVersion)`.
 *
 * The host owns everything that outlives the page or needs the network: the
 * panel's visibility and the read mark per canvas per person (it stores what
 * `{type:'chat'}` and `{type:'chatRead'}` say), the member list, and the
 * mentions API (`{type:'mention'}` after a message that mentions someone).
 */
import * as Y from 'yjs'
import { newId } from '../doc'
import { hostLog, postToHost } from '../../host-bridge'
import type { Session } from '../../controller'
import {
  CHAT_KEY,
  EXCERPT_MAX,
  MAX_TEXT,
  appendMessage,
  composeText,
  excerpt,
  normId,
  notifyIds,
  plainText,
  readLog,
  replaceMessage,
  segments,
  stableColor,
  unreadState,
  type ChatInvitee,
  type ChatMember,
  type ChatMessage,
  type Picked,
  type UnreadState,
} from './model'

/** Transaction origin for chat writes: stored and synced, never on the board's undo stack. */
export const CHAT_ORIGIN = 'chat'

/**
 * A mention that is an assignment, not a message: someone was put on a
 * checklist row. Its id names the card — `assign.<shapeId>.<nonce>` — so Open
 * shows the card rather than the chat.
 */
export const ASSIGN_PREFIX = 'assign.'
export const assignMentionId = (shapeId: string) => `${ASSIGN_PREFIX}${shapeId}.${newId()}`
/** The card an assignment's mention id names; null for a chat message's id. */
export function assignedCard(id: string): string | null {
  if (!id.startsWith(ASSIGN_PREFIX)) return null
  const rest = id.slice(ASSIGN_PREFIX.length)
  const dot = rest.lastIndexOf('.')
  return dot > 0 ? rest.slice(0, dot) : null
}

/** What an assignment tells: the row, then the card's title. */
export function assignExcerpt(row: string, title: string): string {
  const flat = [row, title].map(s => s.replace(/\s+/g, ' ').trim()).filter(Boolean)
  const line = flat.length > 1 ? `${flat[0]} · ${flat[1]}` : (flat[0] ?? 'A checklist row')
  return line.length <= EXCERPT_MAX ? line : `${line.slice(0, EXCERPT_MAX - 1).trimEnd()}…`
}

export interface ChatConfig {
  /** A shared canvas on a cloud: chat is offered. */
  enabled: boolean
  /** The panel is showing (remembered per canvas per person by the host). */
  open: boolean
  members: ChatMember[]
  invited: ChatInvitee[]
  /** The cloud takes mention notifications (copper-cloud 0.6.0+). */
  mentionsApi: boolean
  /** The host kept a read mark for this canvas (false: first time here). */
  known: boolean
  lastReadId: string | null
  lastReadAt: number | null
  /** Message ids the server still holds as unread mentions of me. */
  mentioned: string[]
  /** The member list has been read at least once (else the picker says it is loading). */
  membersKnown: boolean
}

const DEFAULTS: ChatConfig = {
  enabled: false,
  open: false,
  members: [],
  invited: [],
  mentionsApi: false,
  known: true,
  lastReadId: null,
  lastReadAt: null,
  mentioned: [],
  membersKnown: false,
}

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)

function readMembers(v: unknown): ChatMember[] {
  if (!Array.isArray(v)) return []
  const out: ChatMember[] = []
  const seen = new Set<string>()
  for (const raw of v) {
    if (!isObject(raw) || typeof raw.id !== 'string' || !raw.id.trim()) continue
    const id = normId(raw.id)
    if (seen.has(id)) continue
    seen.add(id)
    const email = typeof raw.email === 'string' ? raw.email.trim() : ''
    const name = typeof raw.name === 'string' && raw.name.trim() ? raw.name.trim() : email || 'Someone'
    const m: ChatMember = { id, name: name.slice(0, 120), email }
    if (typeof raw.role === 'string') m.role = raw.role
    m.color = typeof raw.color === 'string' && raw.color ? raw.color : stableColor(id)
    out.push(m)
  }
  return out
}

function readInvited(v: unknown): ChatInvitee[] {
  if (!Array.isArray(v)) return []
  return v.flatMap(raw => {
    if (!isObject(raw)) return []
    const email = typeof raw.email === 'string' ? raw.email.trim() : ''
    const name = typeof raw.name === 'string' && raw.name.trim() ? raw.name.trim() : email
    return name ? [{ name: name.slice(0, 120), email }] : []
  })
}

/** `setChat`: a partial patch merged over what is known. Unknown keys are ignored. */
export function parseChatPatch(raw: unknown): Partial<ChatConfig> | null {
  let v = raw
  if (typeof v === 'string') v = v.trim() ? JSON.parse(v) : null
  if (v === null || v === undefined) return null
  if (!isObject(v)) throw new Error('setChat: expected {enabled?, open?, members?, …}')
  const out: Partial<ChatConfig> = {}
  if (typeof v.enabled === 'boolean') out.enabled = v.enabled
  if (typeof v.open === 'boolean') out.open = v.open
  if (v.members !== undefined) {
    out.members = readMembers(v.members)
    out.membersKnown = true
  }
  if (v.invited !== undefined) out.invited = readInvited(v.invited)
  if (typeof v.mentionsApi === 'boolean') out.mentionsApi = v.mentionsApi
  if ('lastReadId' in v || 'lastReadAt' in v) {
    out.lastReadId = typeof v.lastReadId === 'string' && v.lastReadId ? v.lastReadId : null
    out.lastReadAt = typeof v.lastReadAt === 'number' && Number.isFinite(v.lastReadAt) ? v.lastReadAt : null
    out.known = out.lastReadId !== null || out.lastReadAt !== null
  }
  if (typeof v.known === 'boolean') out.known = v.known
  if (Array.isArray(v.mentioned)) out.mentioned = v.mentioned.filter((x): x is string => typeof x === 'string' && x.length > 0)
  return out
}

export interface SendResult {
  ok: boolean
  id?: string
  error?: string
  mentions?: string[]
}

/** What `read()` hands agents: tokens as "@Name", times as ISO strings. */
export interface ChatReadEntry {
  id: string
  from: string
  fromId: string
  text: string
  mentions: { id: string; name: string }[]
  at: string
  deleted?: true
}

type Listener = () => void

export class ChatHub {
  config: ChatConfig = { ...DEFAULTS }
  messages: readonly ChatMessage[] = []
  unread: UnreadState = { count: 0, mentions: 0, firstId: null, mentionIds: [] }
  /** A message to scroll to and flash (`reveal`), with a stamp so a repeat flashes again. */
  focus: { id: string; at: number } | null = null
  /** The board asks the composer for the keyboard (the C shortcut, a reveal). */
  focusComposer = 0
  /** A card an assignment's Open asked to show, with a stamp so a repeat flashes again. */
  assignFocus: { shapeId: string; at: number } | null = null
  /** The board, for an assignment's Open: show a card (chat/index.ts wires the controller in). */
  showCard: (shapeId: string) => boolean = () => false
  private session: Session | null = null
  private arr: Y.Array<unknown> | null = null
  private observer: (() => void) | null = null
  private listeners = new Set<Listener>()
  private version = 0
  private baselinePending = false
  private pendingReveal: { id: string; until: number } | null = null
  private lastPostedRead = ''
  private unsubscribeStatus: (() => void) | null = null
  private askedMembers = 0

  constructor(private readonly subscribeStatus: (fn: () => void) => () => void = () => () => {}) {}

  subscribe = (fn: Listener) => {
    this.listeners.add(fn)
    return () => {
      this.listeners.delete(fn)
    }
  }
  getVersion = () => this.version
  private emit() {
    this.version++
    for (const fn of this.listeners) fn()
  }

  get me(): string {
    return normId(this.session?.cfg.me.id ?? 'me')
  }
  get meName(): string {
    return this.session?.cfg.me.name ?? 'You'
  }
  get readOnly(): boolean {
    return this.session?.cfg.readOnly ?? true
  }
  /** Chat is shown: the host offered it and a canvas is open. */
  get available(): boolean {
    return this.config.enabled && !!this.session
  }

  // ---- lifecycle -------------------------------------------------------------------

  attach(session: Session | null) {
    this.detach()
    this.session = session
    this.focus = null
    this.pendingReveal = null
    this.lastPostedRead = ''
    if (!session) {
      this.messages = []
      this.recompute()
      this.emit()
      return
    }
    const arr = session.doc.getArray<unknown>(CHAT_KEY)
    this.arr = arr
    this.observer = () => this.reload()
    arr.observe(this.observer)
    this.unsubscribeStatus = this.subscribeStatus(() => this.settle())
    this.reload()
  }

  private detach() {
    if (this.arr && this.observer) this.arr.unobserve(this.observer)
    this.unsubscribeStatus?.()
    this.unsubscribeStatus = null
    this.arr = null
    this.observer = null
  }

  /** `copperCanvas.setChat`: idempotent, merges. `null` turns chat off for this page. */
  configure(raw: unknown): ChatConfig {
    const patch = parseChatPatch(raw)
    if (patch === null) {
      this.config = { ...DEFAULTS }
      this.recompute()
      this.emit()
      return this.config
    }
    const wasKnown = this.config.known
    this.config = { ...this.config, ...patch }
    // No read mark kept for this canvas yet: what is already here counts as
    // read once the room has handed it over (a long history is not "new").
    if (patch.known === false && wasKnown !== false) this.baselinePending = true
    if (patch.known === true) this.baselinePending = false
    this.recompute()
    this.settle()
    this.emit()
    return this.config
  }

  private reload() {
    this.messages = this.arr ? readLog(this.arr) : []
    this.recompute()
    if (this.pendingReveal) {
      const { id, until } = this.pendingReveal
      if (this.messages.some(m => m.id === id)) {
        this.pendingReveal = null
        this.focus = { id, at: Date.now() }
      } else if (Date.now() > until) this.pendingReveal = null
    }
    this.settle()
    this.emit()
  }

  /** The doc holds what it is going to hold for now (synced, or offline by design). */
  private settled(): boolean {
    const s = this.session
    if (!s) return false
    return !s.cfg.online || s.status === 'online'
  }

  private settle() {
    if (!this.baselinePending || !this.settled() || !this.config.enabled) return
    this.baselinePending = false
    // Read up to the last message — except a mention of me that I haven't
    // answered: the "New" line starts there (and the badge says @).
    const me = this.me
    let lastOwn = -1
    this.messages.forEach((m, i) => {
      if (m.authorId === me) lastOwn = i
    })
    const first = this.messages.findIndex((m, i) => i > lastOwn && !m.deleted && m.authorId !== me && m.mentions.includes(me))
    const mark = first >= 0 ? this.messages[first - 1] : this.messages[this.messages.length - 1]
    const at = mark?.at ?? (first >= 0 ? this.messages[first]!.at - 1 : Date.now())
    this.config = { ...this.config, known: true, lastReadId: mark?.id ?? null, lastReadAt: at }
    this.recompute()
    this.postRead([])
    this.emit()
  }

  private recompute() {
    this.unread = unreadState(this.messages, this.me, { id: this.config.lastReadId, at: this.config.lastReadAt }, this.config.mentioned)
  }

  // ---- the panel ---------------------------------------------------------------------

  /** Show or hide the panel; the host remembers it (unless it said so itself). */
  setOpen(open: boolean, opts: { fromHost?: boolean; focus?: boolean } = {}) {
    if (opts.focus && open) this.focusComposer++
    if (this.config.open === open) {
      if (opts.focus) this.emit()
      return
    }
    this.config = { ...this.config, open }
    // A reveal is for this showing only: shown again later, the panel opens at the bottom.
    if (!open) this.focus = null
    if (!opts.fromHost) postToHost({ type: 'chat', open })
    this.emit()
  }

  toggle() {
    this.setOpen(!this.config.open, { focus: !this.config.open })
  }

  /** Open the panel at a message and flash it; waits a few seconds for one not synced yet. */
  reveal(raw: unknown): boolean {
    let v = raw
    if (typeof v === 'string') {
      const t = v.trim()
      v = t.startsWith('{') ? JSON.parse(t) : { id: t }
    }
    const id = isObject(v) && typeof v.id === 'string' ? v.id : isObject(v) && typeof v.messageId === 'string' ? v.messageId : ''
    // An assignment shows its card, flashes the rows that are yours and reads it; the chat stays as it was.
    const card = assignedCard(id)
    if (card !== null) {
      this.assignFocus = { shapeId: card, at: Date.now() }
      const shown = this.showCard(card)
      this.markSeen(id)
      this.emit()
      return shown
    }
    if (!this.config.enabled) return false
    this.setOpen(true)
    if (!id) return true
    if (this.messages.some(m => m.id === id)) {
      this.focus = { id, at: Date.now() }
      this.pendingReveal = null
    } else {
      this.pendingReveal = { id, until: Date.now() + 10_000 }
    }
    this.emit()
    return true
  }

  /** The panel shows the newest message and the page is visible: everything is read. */
  markRead() {
    const last = this.messages[this.messages.length - 1]
    if (!last) return
    const newlyRead = this.unread.mentionIds
    const changed = last.id !== this.config.lastReadId || this.config.mentioned.length > 0
    if (!changed) return
    this.config = { ...this.config, known: true, lastReadId: last.id, lastReadAt: last.at, mentioned: [] }
    this.baselinePending = false
    this.recompute()
    this.postRead(newlyRead)
    this.emit()
  }

  /** One message read (scrolled into view while older ones are unread), or an assignment seen: only its mention clears. */
  markSeen(id: string) {
    if (!this.unread.mentionIds.includes(id) && !this.config.mentioned.includes(id)) return
    if (this.config.mentioned.includes(id)) this.config = { ...this.config, mentioned: this.config.mentioned.filter(x => x !== id) }
    this.recompute()
    postToHost({ type: 'chatRead', id: this.config.lastReadId, at: this.config.lastReadAt, mentionIds: [id] })
    this.emit()
  }

  private postRead(mentionIds: string[]) {
    const key = `${this.config.lastReadId}|${mentionIds.join(',')}`
    if (key === this.lastPostedRead && mentionIds.length === 0) return
    this.lastPostedRead = key
    postToHost({ type: 'chatRead', id: this.config.lastReadId, at: this.config.lastReadAt, mentionIds })
  }

  /** The picker opened: ask the host for a fresh member list (at most every 20 s). */
  wantMembers() {
    const now = Date.now()
    if (now - this.askedMembers < 20_000) return
    this.askedMembers = now
    postToHost({ type: 'chatMembers' })
  }

  // ---- checklist assignees ----------------------------------------------------------

  /**
   * Whom a checklist row can be assigned to: the people chat's @ picker
   * lists (the canvas's members), you among them — first, if the list doesn't
   * have you yet. A canvas on this Mac has only you.
   */
  people(): ChatMember[] {
    const me = this.me
    const list = this.config.enabled ? [...this.config.members] : []
    if (this.session && !list.some(m => m.id === me)) list.unshift({ id: me, name: this.meName, email: '', color: stableColor(me) })
    return list
  }

  /** My unread assignments on one card: their mention ids, joined (stable for React). */
  assignedToMe(shapeId: string): string {
    return this.config.mentioned.filter(id => assignedCard(id) === shapeId).join(' ')
  }

  /**
   * Someone put people on a checklist row: those on the canvas (but you) get
   * the notification a chat @mention gives, on a cloud that takes them. A
   * name of its own, or someone not on the canvas, is told nothing.
   */
  notifyAssigned(e: { shapeId: string; title: string; row: string; people: readonly { id?: string }[] }): string[] {
    if (!this.config.enabled || !this.config.mentionsApi || !this.session || this.session.cfg.readOnly) return []
    const members = new Set(this.config.members.map(m => m.id))
    const me = this.me
    const ids = [...new Set(e.people.flatMap(p => (p.id ? [normId(p.id)] : [])))].filter(id => id !== me && members.has(id))
    if (!ids.length) return []
    const messageId = assignMentionId(e.shapeId)
    postToHost({ type: 'mention', messageId, userIds: ids, excerpt: assignExcerpt(e.row, e.title) })
    hostLog('debug', `chat: assigned ${ids.length} on ${e.shapeId}`)
    return ids
  }

  // ---- writing -------------------------------------------------------------------------

  /** A draft from the composer: picked names become tokens for people still on the canvas. */
  sendDraft(draft: string, picked: readonly Picked[]): SendResult {
    const ids = new Set(this.config.members.map(m => m.id))
    const { text, mentions } = composeText(draft, picked, ids, this.me)
    return this.send(text, mentions)
  }

  /**
   * Append a message (text with tokens, ids it mentions). Mentions not on
   * the canvas are dropped (their token stays as text). Then the host is told
   * whom to notify, when the cloud can.
   */
  send(rawText: string, rawMentions: readonly string[] = []): SendResult {
    const s = this.session
    if (!s) return { ok: false, error: 'copperCanvas.init has not been called' }
    if (!this.config.enabled) return { ok: false, error: 'chat is only on shared canvases' }
    if (s.cfg.readOnly) return { ok: false, error: 'this canvas is view only' }
    const text = rawText.replace(/\r\n?/g, '\n').trim()
    if (!text) return { ok: false, error: 'empty message' }
    if (text.length > MAX_TEXT) return { ok: false, error: `messages hold at most ${MAX_TEXT} characters` }
    const members = new Set(this.config.members.map(m => m.id))
    const me = this.me
    const listed = [...new Set(rawMentions.map(normId))].filter(id => id === me || members.has(id))
    // Only ids whose token is in the text count.
    const inText = new Set(segments(text, listed).flatMap(seg => (seg.kind === 'mention' ? [seg.id] : [])))
    const mentions = listed.filter(id => inText.has(id))
    const msg: ChatMessage = {
      id: newId(),
      authorId: me,
      authorName: s.cfg.me.name,
      text,
      mentions,
      at: Date.now(),
    }
    appendMessage(s.doc, msg, CHAT_ORIGIN)
    // Writing is reading: everything up to your own message is read.
    this.markRead()
    const notify = notifyIds(msg)
    if (notify.length && this.config.mentionsApi) {
      postToHost({ type: 'mention', messageId: msg.id, userIds: notify, excerpt: excerpt(text, mentions) })
    }
    hostLog('debug', `chat: sent ${msg.id}${notify.length ? ` mentioning ${notify.length}` : ''}`)
    return { ok: true, id: msg.id, mentions }
  }

  /** Your own message, deleted for everyone (a tombstone keeps its place). */
  remove(id: string): boolean {
    const s = this.session
    if (!s || s.cfg.readOnly) return false
    const msg = this.messages.find(m => m.id === id)
    if (!msg || msg.authorId !== this.me || msg.deleted) return false
    return replaceMessage(s.doc, id, { ...msg, text: '', mentions: [], deleted: true, editedAt: Date.now() }, CHAT_ORIGIN)
  }

  // ---- reading (agents, the bench) -------------------------------------------------------

  read(limit = 50): ChatReadEntry[] {
    return this.messages.slice(-Math.max(0, limit)).map(m => {
      const entry: ChatReadEntry = {
        id: m.id,
        from: m.authorName,
        fromId: m.authorId,
        text: plainText(m.text, m.mentions),
        mentions: segments(m.text, m.mentions).flatMap(seg => (seg.kind === 'mention' ? [{ id: seg.id, name: seg.name }] : [])),
        at: new Date(m.at || 0).toISOString(),
      }
      if (m.deleted) entry.deleted = true
      return entry
    })
  }

  /** `copperCanvas.chatState()`: what the panel and the button show, for the host's bench. */
  state() {
    return {
      enabled: this.config.enabled,
      open: this.config.open,
      count: this.messages.length,
      unread: this.unread.count,
      mentions: this.unread.mentions,
      mentionIds: this.unread.mentionIds,
      lastReadId: this.config.lastReadId,
      members: this.config.members.map(m => ({ id: m.id, name: m.name, email: m.email })),
      invited: this.config.invited,
      mentionsApi: this.config.mentionsApi,
      focus: this.focus?.id ?? null,
      last: this.read(5),
    }
  }
}
