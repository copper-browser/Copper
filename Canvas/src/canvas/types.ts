/**
 * The board's document model (the shared contract with the host, the sync
 * server and agent tools).
 *
 * One Y.Doc per canvas:
 * - `shapes: Y.Map<id, Y.Map<prop>>` — one nested map per shape, so every
 *   property is last-writer-wins on its own. Sticky and text bodies are a
 *   `Y.Text` (concurrent typing merges); a plain string is read too.
 * - `agents: Y.Map<agentId, AgentPresence>` — plain objects, replaced whole.
 * - `meta: Y.Map` — `name`, `createdBy`.
 * - `comments: Y.Map<threadId, Y.Map>` — comment threads anchored to shapes
 *   (`comments.ts`); kept apart from `shapes` and out of undo.
 * - `chat: Y.Array` — a shared canvas's chat (`chat/model.ts`).
 */
import type { Point, Side } from './geometry'

export const SHAPE_TYPES = ['sticky', 'text', 'frame', 'arrow', 'image', 'link', 'checklist'] as const
export type ShapeType = (typeof SHAPE_TYPES)[number]
export const isShapeType = (v: unknown): v is ShapeType =>
  typeof v === 'string' && (SHAPE_TYPES as readonly string[]).includes(v)

export const SHAPE_COLORS = ['yellow', 'pink', 'blue', 'green', 'purple', 'gray', 'white'] as const
export type NamedColor = (typeof SHAPE_COLORS)[number]
/** A palette name or a `#hex` colour. */
export type ShapeColor = NamedColor | `#${string}`

const HEX = /^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i
export const isNamedColor = (v: unknown): v is NamedColor =>
  typeof v === 'string' && (SHAPE_COLORS as readonly string[]).includes(v)
export const isShapeColor = (v: unknown): v is ShapeColor =>
  isNamedColor(v) || (typeof v === 'string' && HEX.test(v))

/** A free point, or a shape (optionally pinned to one side's midpoint). */
export type Endpoint = Point | { ref: string; side?: Side }
export const isRefEndpoint = (e: Endpoint | undefined): e is { ref: string; side?: Side } =>
  !!e && typeof (e as { ref?: unknown }).ref === 'string'

export interface ImageRef {
  /** `data:` URL (≤ 2 MB) or an `https:` URL. */
  src: string
  naturalW: number
  naturalH: number
}

export type TextAlign = 'left' | 'center' | 'right'

/** checklist: one row (a person, a task). */
export interface ChecklistRow {
  id: string
  label: string
}

/**
 * checklist: a row's comment. On a note, the words are quote lines under the
 * row's task line (`checklist-text.ts`) and who wrote them sits beside it
 * (`noteBy:<label>`); on a legacy card, all of it under `note:<rowId>`.
 */
export interface ChecklistNote {
  text: string
  /** Who last wrote it: name and id ('' when unknown). */
  by: string
  byId: string
  /** Epoch ms; 0 when unknown. */
  at: number
}

/** checklist: a row's pick, stored under its own `pick:<rowId>` key (`checklist.ts`). */
export interface ChecklistPick {
  /** The column's label. */
  col: string
  /** Who picked it: name and id. */
  by: string
  byId: string
  /** Epoch ms. */
  at: number
}

/** A plain read of one shape; see `readShape` for the tolerant parsing. */
export interface Shape {
  id: string
  type: ShapeType
  x: number
  y: number
  w: number
  h: number
  color: ShapeColor
  /** Display name of whoever made it (a person or an agent). */
  by?: string
  createdAt: number
  updatedAt: number
  /** Stacking order, higher on top. */
  z: number
  /** sticky (markdown) and text. */
  text: string
  fontSize?: number
  align?: TextAlign
  /** frame and link. */
  title: string
  /** frame: an image filling the body. */
  image?: ImageRef
  /** arrow */
  from?: Endpoint
  to?: Endpoint
  label?: string
  /** image */
  src?: string
  naturalW?: number
  naturalH?: number
  /** link */
  url?: string
  favicon?: string
  /**
   * link: show the site itself (an <iframe>, `canvas/frames.ts`) rather than
   * a card. A plain extra key on the link, so an older client still reads
   * the shape as a link card and keeps the flag when it copies or edits it.
   */
  live?: boolean
  /**
   * sticky: `"checklist"` draws the note as a checklist card read from its own
   * text (`checklist-text.ts`); an older client ignores the key and shows the
   * note, task boxes and all.
   */
  view?: 'checklist'
  /**
   * checklist (and a sticky in the checklist view): 1–4 column labels, its rows,
   * and each row's pick by row id. On a note, `title`, `rows`, `picks` and
   * `notes` are read from the text; only `columns` is stored.
   */
  columns?: string[]
  rows?: ChecklistRow[]
  picks?: Readonly<Record<string, ChecklistPick>>
  /** checklist: each row's comment by row id, for rows that have one (read-side only). */
  notes?: Readonly<Record<string, ChecklistNote>>
}

/** Default size per type; arrows and images size themselves. */
export const SHAPE_SIZE: Record<ShapeType, { w: number; h: number }> = {
  sticky: { w: 200, h: 200 },
  text: { w: 240, h: 36 },
  frame: { w: 480, h: 320 },
  arrow: { w: 0, h: 0 },
  image: { w: 320, h: 240 },
  link: { w: 300, h: 84 },
  checklist: { w: 324, h: 120 },
}

export const DEFAULT_COLOR: Record<ShapeType, NamedColor> = {
  sticky: 'yellow',
  text: 'gray',
  frame: 'gray',
  arrow: 'gray',
  image: 'white',
  link: 'white',
  checklist: 'green',
}

export const STICKY_FONT = 16
export const TEXT_FONT = 20

export const AGENT_STATUSES = ['idle', 'thinking', 'writing'] as const
export type AgentStatus = (typeof AGENT_STATUSES)[number]

/** One entry of the `agents` map. */
export interface AgentPresence {
  name: string
  color: string
  cursor: Point | null
  status: AgentStatus
  /** Epoch ms of the last write. */
  updatedAt: number
}

export interface CanvasAgent extends AgentPresence {
  id: string
}

export interface Me {
  id: string
  name: string
  color: string
}

export type CanvasKind = 'personal' | 'shared' | string
