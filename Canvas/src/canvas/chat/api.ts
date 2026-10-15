/**
 * The chat half of `window.copperCanvas` (merged in by `installApi`). Like
 * the rest, every entry takes a JSON string or a plain value and never
 * throws into the host.
 */
import { hostLog } from '../../host-bridge'
import type { ChatHub, ChatReadEntry, SendResult } from './hub'
import { normId } from './model'

export interface CopperChatApi {
  /**
   * What Copper says about chat here: `{enabled, open?, members?, invited?,
   * mentionsApi?, lastReadId?, lastReadAt?, mentioned?}` (a patch; `null` turns it off).
   */
  setChat(cfg: unknown): void
  /**
   * Show the panel at a message and flash it: `{id}` or the id. False when chat
   * is off here. An assignment's id (`assign.<shapeId>.<nonce>`) shows its card instead.
   */
  revealChat(target: unknown): boolean
  /** Show (`true`) or hide (`false`) the panel, as the host remembers it. */
  showChat(open: unknown): void
  /**
   * Post as the signed-in person: `{text, mentions?: [id|name|email]}`. Every
   * `@Name` of a mentioned member in the text becomes a mention of them.
   */
  chatSend(input: unknown): string
  /** The last `limit` messages (default 50), tokens as "@Name". */
  chatRead(limit?: unknown): ChatReadEntry[]
  /** What the button and the panel show, for the bench. */
  chatState(): string
}

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)

/** `chatSend` input: mentions given by id, name or email resolve against the members. */
export function sendFromTool(hub: ChatHub, raw: unknown): SendResult {
  let v = raw
  if (typeof v === 'string') {
    const t = v.trim()
    v = t.startsWith('{') ? JSON.parse(t) : { text: t }
  }
  if (!isObject(v) || typeof v.text !== 'string') return { ok: false, error: 'chatSend: expected {text, mentions?}' }
  const wanted = Array.isArray(v.mentions) ? v.mentions.filter((x): x is string => typeof x === 'string' && x.trim().length > 0) : []
  const members = hub.config.members
  const picked: { id: string; name: string }[] = []
  const unknown: string[] = []
  for (const w of wanted) {
    const key = w.trim().replace(/^@/, '').toLowerCase()
    const m =
      members.find(x => x.id === normId(key)) ??
      members.find(x => x.email.toLowerCase() === key) ??
      members.find(x => x.name.toLowerCase() === key) ??
      members.find(x => x.name.toLowerCase().startsWith(key))
    if (m) picked.push({ id: m.id, name: m.name })
    else unknown.push(w)
  }
  if (unknown.length) return { ok: false, error: `not on this canvas: ${unknown.join(', ')}` }
  // Each mentioned person needs an "@Name" in the text; one is added at the front when missing.
  let text = v.text
  const missing = picked.filter(p => !text.includes(`@${p.name}`))
  if (missing.length) text = `${missing.map(p => `@${p.name}`).join(' ')} ${text}`
  return hub.sendDraft(text, picked)
}

export function createChatApi(hub: ChatHub): CopperChatApi {
  const guarded =
    <A extends unknown[], R>(name: string, fn: (...args: A) => R, fallback: R) =>
    (...args: A): R => {
      try {
        return fn(...args)
      } catch (error) {
        hostLog('error', `${name}: ${error instanceof Error ? error.message : String(error)}`)
        return fallback
      }
    }
  return {
    setChat: guarded('setChat', (cfg: unknown) => void hub.configure(cfg), undefined),
    revealChat: guarded('revealChat', (target: unknown) => hub.reveal(target), false),
    showChat: guarded('showChat', (open: unknown) => hub.setOpen(open === true || open === 'true', { fromHost: true }), undefined),
    chatSend: (input: unknown) => {
      try {
        return JSON.stringify(sendFromTool(hub, input))
      } catch (error) {
        return JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) })
      }
    },
    chatRead: guarded('chatRead', (limit?: unknown) => hub.read(typeof limit === 'number' && limit > 0 ? Math.min(limit, 1000) : 50), []),
    chatState: () => {
      try {
        return JSON.stringify(hub.state())
      } catch (error) {
        return JSON.stringify({ error: error instanceof Error ? error.message : String(error) })
      }
    },
  }
}

/**
 * The page's API with chat merged in: the chat entries, and `read` with the
 * last 50 messages under `chat` on a canvas that has chat (texts cut at 500
 * characters unless `full`).
 */
export function withChat<T extends { read(opts?: unknown): string }>(api: T, hub: ChatHub): T & CopperChatApi {
  const base = api.read.bind(api)
  const read = (opts?: unknown) => {
    const out = base(opts)
    if (!hub.available) return out
    try {
      const parsed = JSON.parse(out) as Record<string, unknown>
      if (parsed.error) return out
      let full = false
      try {
        const o = typeof opts === 'string' ? (opts.trim() ? JSON.parse(opts) : {}) : opts
        full = isObject(o) && o.full === true
      } catch {
        full = false
      }
      parsed.chat = hub.read(50).map(m => (full || m.text.length <= 500 ? m : { ...m, text: `${m.text.slice(0, 499)}…` }))
      return JSON.stringify(parsed)
    } catch {
      return out
    }
  }
  return Object.assign(api, createChatApi(hub), { read })
}
