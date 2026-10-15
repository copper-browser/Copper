/**
 * The page's one controller: owns the current canvas session (Y.Doc, store,
 * awareness, sync provider), the selection, and what the board reports about
 * its viewport. The window API and the React board both talk to it.
 */
import * as Y from 'yjs'
import { Awareness } from 'y-protocols/awareness'
import { WebsocketProvider } from 'y-websocket'
import { BridgeSocket } from './bridge-socket'
import { fromBase64, toBase64 } from './canvas/base64'
import { CanvasStore, HOST, IMPORT, INIT, PRESENCE, bareId, newId } from './canvas/doc'
import { AGENT_TTL_MS, writeAgent, readAgents, isStatus, type AgentPatch } from './canvas/agents'
import { colorFor } from './canvas/colors'
import { visibleWorld, type Box, type Point, type View } from './canvas/geometry'
import { pictureForImport } from './canvas/images'
import {
  DEFAULT_NAMES,
  decodeLegacyDoc,
  fingerprint,
  parseLegacyPayload,
  pictureSrc,
  planLegacyImport,
  readLegacyShapes,
  sniffImageSize,
  type Picture,
} from './canvas/legacy'
import { occupied } from './placement'
import { parseHostStatus, sameHostStatus, type HostStatus, type SyncStatus } from './canvas/status'
import { createPresenceReporter, hostPresence, readPresence } from './canvas/presence'
import type { Me } from './canvas/types'
import { FrameBus, parseFrameEvent } from './canvas/frames'
import { hostLog, postToHost } from './host-bridge'
import { applyOps, readCanvas, type ApplyResult, type CanvasRead, type OpsContext } from './ops'

export const VERSION = '1.0.0'

/** What the host passes to `copperCanvas.init`. */
export interface InitConfig {
  docId: string
  name: string
  kind: string
  me: Me
  state: string | null
  online: boolean
  readOnly: boolean
}

export type { HostStatus, SyncStatus }

export interface ShareConfig {
  canShare: boolean
  members?: number
  reason?: string
}

/** What `copperCanvas.importLegacy` resolves to. */
export interface ImportResult {
  /** Shapes written to the canvas (a frame and the picture placed in it are two). */
  imported: number
  /** Legacy entries that did not come over (unknown types, arrows with a missing end, pictures). */
  skipped: number
  /** Set when something the old board showed is not on the canvas, or nothing could be read. */
  error?: string
  /** This document was imported into this canvas before; nothing was written again. */
  already?: true
}

/** Meta key listing the fingerprints of legacy documents already imported. */
export const IMPORTED_KEY = 'importedLegacy'

/** Presence is an operation lease, not a permanent collaborator. */
export const WRITING_MS = AGENT_TTL_MS

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)

export function parseShare(raw: unknown): ShareConfig | null {
  let v = raw
  if (typeof v === 'string') v = v.trim() ? JSON.parse(v) : null
  if (v === null || v === undefined) return null
  if (!isObject(v) || typeof v.canShare !== 'boolean') throw new Error('setShare: expected {canShare, members?, reason?}')
  const out: ShareConfig = { canShare: v.canShare }
  if (v.members !== undefined && v.members !== null) {
    const n = Number(v.members)
    if (Number.isFinite(n) && n >= 0) out.members = Math.floor(n)
  }
  if (typeof v.reason === 'string' && v.reason.trim()) out.reason = v.reason.trim().slice(0, 400)
  return out
}

export const sameShare = (a: ShareConfig | null, b: ShareConfig | null) =>
  a === b || (!!a && !!b && a.canShare === b.canShare && (a.members ?? 0) === (b.members ?? 0) && (a.reason ?? '') === (b.reason ?? ''))

export function parseInit(raw: unknown): InitConfig {
  let v = raw
  if (typeof v === 'string') v = JSON.parse(v)
  if (!isObject(v)) throw new Error('init: expected {docId, name, kind, me, state, online, readOnly}')
  const docId = typeof v.docId === 'string' && v.docId ? v.docId : 'personal'
  const meRaw = isObject(v.me) ? v.me : {}
  const meId = typeof meRaw.id === 'string' && meRaw.id ? meRaw.id : 'me'
  const me: Me = {
    id: meId,
    name: typeof meRaw.name === 'string' && meRaw.name.trim() ? meRaw.name.trim() : 'You',
    color: typeof meRaw.color === 'string' && meRaw.color ? meRaw.color : colorFor(meId),
  }
  return {
    docId,
    name: typeof v.name === 'string' && v.name.trim() ? v.name.trim() : 'Canvas',
    kind: typeof v.kind === 'string' && v.kind ? v.kind : 'personal',
    me,
    state: typeof v.state === 'string' && v.state ? v.state : null,
    online: v.online === true,
    readOnly: v.readOnly === true,
  }
}

/** One open canvas. */
export class Session {
  private static opened = 0
  /** Distinct per init, so the board remounts for every new session. */
  readonly serial = ++Session.opened
  readonly cfg: InitConfig
  readonly doc: Y.Doc
  readonly store: CanvasStore
  readonly awareness: Awareness
  readonly provider: WebsocketProvider | null
  status: SyncStatus
  private onUpdate: (update: Uint8Array, origin: unknown) => void
  private readonly presenceReporter: ReturnType<typeof createPresenceReporter>
  private expiryTimer: ReturnType<typeof setTimeout> | undefined
  private ownedAgents = new Map<string, unknown>()
  private readonly reportPresence = () => {
    this.presenceReporter.update(hostPresence(readPresence(this.awareness, this.store.agents)))
    clearTimeout(this.expiryTimer)
    const now = Date.now()
    const expires = readAgents(this.store.agents).map(a => a.updatedAt + AGENT_TTL_MS).filter(at => at >= now)
    if (expires.length) this.expiryTimer = setTimeout(this.expireAgents, Math.max(1, Math.min(...expires) - now + 1))
  }

  /** Delete only our own unchanged leases; another client may share the agent's id. */
  private expireAgents = () => {
    const now = Date.now()
    this.doc.transact(() => {
      for (const [id, value] of this.ownedAgents) {
        if (this.store.agents.get(id) !== value) { this.ownedAgents.delete(id); continue }
        const at = (value as { updatedAt: number }).updatedAt
        if (now - at >= AGENT_TTL_MS) {
          this.store.agents.delete(id)
          this.ownedAgents.delete(id)
        }
      }
    }, PRESENCE)
    this.reportPresence()
  }

  writeAgent(id: string, patch: AgentPatch) {
    this.doc.transact(() => {
      const value = writeAgent(this.store.agents, id, patch)
      this.ownedAgents.set(id, value)
    }, PRESENCE)
  }

  clearAgents() {
    this.doc.transact(() => {
      for (const [id, value] of this.ownedAgents) {
        if (this.store.agents.get(id) === value) this.store.agents.delete(id)
      }
    }, PRESENCE)
    this.ownedAgents.clear()
  }

  constructor(cfg: InitConfig, onStatus: () => void) {
    this.cfg = cfg
    this.doc = new Y.Doc()
    if (cfg.state) {
      try {
        Y.applyUpdate(this.doc, fromBase64(cfg.state), HOST)
      } catch (error) {
        hostLog('error', `init: the stored state did not apply (${String(error)}); starting empty`)
      }
    }
    this.store = new CanvasStore(this.doc)
    this.awareness = new Awareness(this.doc)
    this.awareness.setLocalState({
      user: { id: cfg.me.id, name: cfg.me.name, color: cfg.me.color },
      name: cfg.me.name,
      color: cfg.me.color,
      cursor: null,
      selection: [],
      laser: null,
      frame: null,
    })
    this.presenceReporter = createPresenceReporter(people => postToHost({ type: 'presence', people }), 400)
    this.awareness.on('change', this.reportPresence)
    this.store.agents.observeDeep(this.reportPresence)
    this.reportPresence()
    // Every local change goes to the host, which stores it (offline) and the
    // provider relays it (online). What the host or the server sent is theirs.
    this.onUpdate = (update, origin) => {
      if (origin === HOST || (this.provider && origin === this.provider)) return
      postToHost({ type: 'update', b64: toBase64(update) })
    }
    this.doc.on('update', this.onUpdate)
    this.status = cfg.online ? 'connecting' : 'local'
    this.provider = null
    if (cfg.online) {
      const provider = new WebsocketProvider('ws://bridge', cfg.docId, this.doc, {
        WebSocketPolyfill: BridgeSocket as unknown as typeof WebSocket,
        connect: false,
        awareness: this.awareness,
        disableBc: true,
        maxBackoffTime: 5000,
      })
      this.provider = provider
      provider.on('status', ({ status }: { status: string }) => {
        this.status = status === 'connected' ? (provider.synced ? 'online' : 'connecting') : status === 'connecting' ? 'connecting' : 'offline'
        if (status === 'disconnected') this.clearAgents()
        onStatus()
      })
      provider.on('sync', (synced: boolean) => {
        if (synced) {
          this.status = 'online'
          this.ensureMeta()
        }
        onStatus()
      })
      provider.connect()
    } else this.ensureMeta()
  }

  /** A canvas made here gets its name and maker recorded once. */
  private ensureMeta() {
    if (this.cfg.readOnly || this.store.meta.get('name')) return
    this.doc.transact(() => {
      this.store.meta.set('name', this.cfg.name)
      if (!this.store.meta.get('createdBy')) this.store.meta.set('createdBy', this.cfg.me.name)
    }, INIT)
  }

  destroy() {
    this.clearAgents()
    clearTimeout(this.expiryTimer)
    this.presenceReporter.dispose()
    this.awareness.off('change', this.reportPresence)
    this.store.agents.unobserveDeep(this.reportPresence)
    try {
      this.awareness.setLocalState(null)
    } catch {
      // already gone
    }
    this.provider?.destroy()
    this.doc.off('update', this.onUpdate)
    this.awareness.destroy()
    this.store.destroy()
    this.doc.destroy()
  }
}

export interface ViewInfo {
  view: View
  width: number
  height: number
}

type Listener = () => void

/** What the board does for the controller (flights need its animation). */
export interface BoardHandle {
  zoomTo(ids: string[]): boolean
}

export class Controller {
  session: Session | null = null
  private listeners = new Set<Listener>()
  private selection: readonly string[] = []
  private selectionListeners = new Set<Listener>()
  private lastPostedSelection = '[]'
  viewInfo: ViewInfo = { view: { x: 640, y: 400, z: 1 }, width: 1280, height: 800 }
  board: BoardHandle | null = null
  private pendingZoom: string[] | null = null
  private version = 0
  /** What the host last said about the board's connection; outlives `init`. */
  private hostStatus: HostStatus | null = null
  /** Share capability supplied by Copper; null keeps the Share button hidden. */
  private share: ShareConfig | null = null
  /** Live frames' reports from the host, to the view that owns each frame. */
  readonly frames = new FrameBus()
  /** Who checklist `assignees` resolve against, and whom to tell (chat/index.ts wires the chat hub in). */
  opsHooks: Pick<OpsContext, 'people' | 'onAssigned'> = {}

  subscribe = (fn: Listener) => {
    this.listeners.add(fn)
    return () => {
      this.listeners.delete(fn)
    }
  }
  /** Bumps on init and on sync status changes. */
  getVersion = () => this.version
  private emit() {
    this.version++
    for (const fn of this.listeners) fn()
  }

  // ---- lifecycle ---------------------------------------------------------------

  init(raw: unknown): { ok: true; docId: string } {
    const cfg = parseInit(raw)
    this.session?.destroy()
    this.selection = []
    this.lastPostedSelection = '[]'
    this.session = new Session(cfg, () => this.emit())
    hostLog('info', `init ${cfg.docId} (${cfg.kind}${cfg.online ? ', online' : ''}${cfg.readOnly ? ', read-only' : ''})`)
    this.emit()
    for (const fn of this.selectionListeners) fn()
    return { ok: true, docId: cfg.docId }
  }

  private need(): Session {
    if (!this.session) throw new Error('copperCanvas.init has not been called')
    return this.session
  }

  applyUpdate(b64: string) {
    const s = this.need()
    Y.applyUpdate(s.doc, fromBase64(b64), HOST)
  }

  exportState(): string {
    const s = this.need()
    return toBase64(Y.encodeStateAsUpdate(s.doc))
  }

  // ---- host status --------------------------------------------------------------

  getHostStatus = () => this.hostStatus
  getShare = () => this.share

  /** `copperCanvas.setShare`: idempotent and tolerant of extra fields. */
  setShare(raw: unknown): ShareConfig | null {
    const next = parseShare(raw)
    if (sameShare(next, this.share)) return this.share
    this.share = next
    this.emit()
    return next
  }

  /** Current live room members, excluding this page, with their cursors. */
  presence() {
    const s = this.need()
    return readPresence(s.awareness, s.store.agents).map(({ id, name, color, kind, cursor }) => ({ id, name, color, kind, cursor }))
  }

  /**
   * `copperCanvas.setStatus`: idempotent; `null` clears it. Kept across
   * `init`, so it may come before or after one.
   */
  setHostStatus(raw: unknown): HostStatus | null {
    const next = parseHostStatus(raw)
    if (sameHostStatus(next, this.hostStatus)) return this.hostStatus
    this.hostStatus = next
    this.emit()
    return next
  }

  // ---- live frames --------------------------------------------------------------

  frameEvent(raw: unknown): boolean {
    const e = parseFrameEvent(raw)
    return e ? this.frames.emit(e) : false
  }

  frameHost(raw: unknown) {
    let v = raw
    if (typeof v === 'string') v = JSON.parse(v)
    const reports = isObject(v) && v.reports === true
    if (reports === this.frames.reports) return
    this.frames.reports = reports
    this.emit()
  }

  // ---- viewport ----------------------------------------------------------------

  setViewInfo(info: ViewInfo) {
    this.viewInfo = info
  }

  viewportCenter = (): Point => {
    const { view, width, height } = this.viewInfo
    return { x: (width / 2 - view.x) / view.z, y: (height / 2 - view.y) / view.z }
  }

  visibleBox(): (Box & { zoom: number }) | null {
    const { view, width, height } = this.viewInfo
    if (width <= 0 || height <= 0) return null
    return { ...visibleWorld(view, width, height), zoom: view.z }
  }

  attachBoard(board: BoardHandle | null) {
    this.board = board
    if (board && this.pendingZoom) {
      const ids = this.pendingZoom
      this.pendingZoom = null
      board.zoomTo(ids)
    }
  }

  zoomTo(ids: string[]): boolean {
    const list = ids.map(bareId)
    if (!this.board) {
      this.pendingZoom = list
      return false
    }
    return this.board.zoomTo(list)
  }

  // ---- selection ---------------------------------------------------------------

  getSelection = () => this.selection
  subscribeSelection = (fn: Listener) => {
    this.selectionListeners.add(fn)
    return () => {
      this.selectionListeners.delete(fn)
    }
  }

  /** Set the selection; `fromHost` skips telling the host what it just said. */
  setSelection(ids: readonly string[], fromHost = false) {
    const shapes = this.session?.store.getShapes()
    const next = [...new Set(ids.map(bareId))].filter(id => !shapes || shapes.has(id))
    const same = next.length === this.selection.length && next.every((id, i) => id === this.selection[i])
    if (!same) {
      this.selection = next
      for (const fn of this.selectionListeners) fn()
      this.session?.awareness.setLocalStateField('selection', next)
    }
    const json = JSON.stringify(next)
    if (fromHost) this.lastPostedSelection = json
    else if (json !== this.lastPostedSelection) {
      this.lastPostedSelection = json
      postToHost({ type: 'selection', ids: next })
    }
  }

  // ---- agents ------------------------------------------------------------------

  setAgent(raw: unknown) {
    const s = this.need()
    let v = raw
    if (typeof v === 'string') v = JSON.parse(v)
    if (!isObject(v) || typeof v.id !== 'string' || !v.id) throw new Error('setAgent: expected {id, name, color, cursor, status}')
    const id = v.id
    if (v.remove === true) {
      s.doc.transact(() => s.store.agents.delete(id), PRESENCE)
      return
    }
    const patch: AgentPatch = {}
    if (typeof v.name === 'string') patch.name = v.name
    if (typeof v.color === 'string') patch.color = v.color
    if (v.cursor === null) patch.cursor = null
    else if (isObject(v.cursor)) patch.cursor = v.cursor as unknown as Point
    if (isStatus(v.status)) patch.status = v.status
    s.writeAgent(id, patch)
  }

  private agentWrote(actor: { id: string; name: string; color?: string }, at: Point | null) {
    const s = this.session
    if (!s) return
    s.writeAgent(actor.id, {
      name: actor.name,
      color: actor.color || colorFor(actor.id),
      status: 'writing',
      ...(at ? { cursor: at } : {}),
    })
  }

  // ---- ops ---------------------------------------------------------------------

  apply(raw: unknown): ApplyResult {
    const s = this.session
    if (!s) return { applied: 0, ids: [], errors: [{ index: -1, op: '', error: 'copperCanvas.init has not been called' }] }
    s.store.undo.stopCapturing()
    const out = applyOps({ store: s.store, viewportCenter: this.viewportCenter, readOnly: s.cfg.readOnly, ...this.opsHooks }, raw)
    s.store.undo.stopCapturing()
    if (out.applied > 0 || out.actor) {
      const actor = out.actor ?? { id: 'agent', name: 'Agent' }
      if (out.applied > 0) this.agentWrote(actor, out.anchor)
    }
    // Drop anything that vanished from the selection.
    if (this.selection.length) this.setSelection(this.selection)
    return { applied: out.applied, ids: out.ids, errors: out.errors }
  }

  // ---- legacy import -------------------------------------------------------------

  /**
   * `copperCanvas.importLegacy`: bring an Easels board onto this canvas in one
   * transaction (origin `import`: stored and synced like any local change,
   * not on the undo stack). Never rejects.
   */
  async importLegacy(raw: unknown): Promise<ImportResult> {
    const s = this.session
    if (!s) return { imported: 0, skipped: 0, error: 'copperCanvas.init has not been called' }
    if (s.cfg.readOnly) return { imported: 0, skipped: 0, error: 'this canvas is read-only' }
    let payload
    let legacy
    try {
      payload = parseLegacyPayload(raw)
      const doc = decodeLegacyDoc(payload.doc)
      legacy = readLegacyShapes(doc)
      doc.destroy()
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error)
      return { imported: 0, skipped: 0, error: msg.startsWith('importLegacy') ? msg : `importLegacy: ${msg}` }
    }
    const mark = fingerprint(payload.doc)
    const seen = s.store.meta.get(IMPORTED_KEY)
    if (Array.isArray(seen) && seen.includes(mark)) return { imported: 0, skipped: 0, already: true }

    // Pictures first (the only part that waits), then everything in one go.
    const wanted = new Set(legacy.shapes.flatMap(sh => (sh.type === 'frame' && sh.fileId ? [sh.fileId] : [])))
    // Easels named files `<uuid>.<ext>`; a host may key them with or without the extension.
    const stem = (name: string) => name.replace(/^file:/, '').replace(/\.[a-z0-9]{2,5}$/i, '')
    const byStem = new Map(Object.entries(payload.files).map(([k, v]) => [stem(k), v] as const))
    const pictures = new Map<string, Picture>()
    await Promise.all(
      [...wanted].map(async fileId => {
        const value = payload.files[fileId] ?? payload.files[`file:${fileId}`] ?? byStem.get(stem(fileId))
        if (!value) return
        try {
          const pic = await pictureForImport(value, sniffImageSize, pictureSrc)
          if (pic) pictures.set(fileId, pic)
        } catch {
          // counted as missing below
        }
      })
    )
    if (this.session !== s) {
      return { imported: 0, skipped: legacy.shapes.length + legacy.skipped, error: 'the canvas was replaced (init) during the import' }
    }

    const existing = s.store.liveAll().filter(sh => sh.type !== 'arrow')
    const plan = planLegacyImport(legacy.shapes, {
      taken: id => s.store.shapes.has(id),
      existing: existing.map(occupied),
      zBase: s.store.maxZ() + 1,
      pictures,
      newId,
    })
    const title = payload.title ?? legacy.title
    s.doc.transact(() => {
      for (const input of plan.inputs) s.store.create(input, IMPORT)
      const name = s.store.meta.get('name')
      if (title && (typeof name !== 'string' || !name.trim() || DEFAULT_NAMES.includes(name.trim().toLowerCase())))
        s.store.meta.set('name', title)
      s.store.meta.set(IMPORTED_KEY, [...(Array.isArray(seen) ? seen : []), mark].slice(-50))
    }, IMPORT)
    hostLog('info', `importLegacy: ${plan.inputs.length} shapes, ${plan.skipped + legacy.skipped} skipped`)
    // Show what came over (the board may have been looking elsewhere, or at nothing).
    if (plan.inputs.length) this.zoomTo(plan.inputs.map(i => i.id))

    const result: ImportResult = { imported: plan.inputs.length, skipped: plan.skipped + legacy.skipped }
    if (plan.missingPictures.length) {
      const n = plan.missingPictures.length
      result.error = `${n} picture${n === 1 ? '' : 's'} could not be imported (${plan.missingPictures.slice(0, 5).join(', ')})`
    }
    return result
  }

  read(raw: unknown): CanvasRead {
    const s = this.need()
    const name = (s.store.meta.get('name') as string | undefined) || s.cfg.name
    return readCanvas(
      {
        store: s.store,
        canvas: { id: s.cfg.docId, name: s.cfg.name || name, kind: s.cfg.kind },
        viewport: this.visibleBox(),
        selection: this.selection,
      },
      raw
    )
  }
}

export const controller = new Controller()
