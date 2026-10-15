/** Pure resize math for boxes on the board. No React, no Yjs. */
import type { Box, Point } from './geometry'

/** Compass handle: corners move two edges, sides move one. */
export type Handle = 'nw' | 'n' | 'ne' | 'e' | 'se' | 's' | 'sw' | 'w'

export const CORNER_HANDLES = ['nw', 'ne', 'se', 'sw'] as const
export const EDGE_HANDLES = ['n', 'e', 's', 'w'] as const

export const HANDLE_CURSOR: Record<Handle, string> = {
  nw: 'nwse-resize',
  se: 'nwse-resize',
  ne: 'nesw-resize',
  sw: 'nesw-resize',
  n: 'ns-resize',
  s: 'ns-resize',
  e: 'ew-resize',
  w: 'ew-resize',
}

export interface Size {
  w: number
  h: number
}

/** Smallest each resizable shape type may get. */
export const MIN_SIZE = {
  sticky: { w: 96, h: 64 },
  text: { w: 40, h: 24 },
  frame: { w: 160, h: 120 },
  image: { w: 32, h: 32 },
  link: { w: 180, h: 56 },
  checklist: { w: 200, h: 72 },
  timeline: { w: 360, h: 160 },
} as const satisfies Record<string, Size>

export type ResizableType = keyof typeof MIN_SIZE
export const isResizable = (type: string): type is ResizableType => type in MIN_SIZE

/** A live web frame (a link with `live`) keeps room for its title bar and a usable page. */
export const LIVE_MIN = { w: 320, h: 200 } as const satisfies Size

/**
 * The smallest this shape may get: its type's, a live frame's, or a checklist
 * or timeline card's (a note in that view; a timeline's content may need more
 * height, `neededHeight` in `timeline.ts`).
 */
export function minSizeOf(shape: { type: ResizableType; live?: boolean; view?: string }): Size {
  if (shape.type === 'sticky' && shape.view === 'checklist') return MIN_SIZE.checklist
  if (shape.type === 'sticky' && shape.view === 'timeline') return MIN_SIZE.timeline
  return shape.type === 'link' && shape.live ? LIVE_MIN : MIN_SIZE[shape.type]
}

/**
 * The box after dragging `handle` by `delta` (world px) from `start`. The
 * opposite edge/corner stays put; sizes clamp at `min`, and a dragged edge
 * stops rather than crossing over. Moving edges land on whole pixels so the
 * anchored edge never drifts when the result is rounded for storage.
 */
export function resizeBox(start: Box, handle: Handle, delta: Point, min: Size): Box {
  let { x, y, w, h } = start
  const right = start.x + start.w
  const bottom = start.y + start.h
  if (handle.includes('w')) {
    x = Math.min(Math.round(start.x + delta.x), right - min.w)
    w = right - x
  } else if (handle.includes('e')) {
    w = Math.max(min.w, Math.round(start.w + delta.x))
  }
  if (handle.includes('n')) {
    y = Math.min(Math.round(start.y + delta.y), bottom - min.h)
    h = bottom - y
  } else if (handle.includes('s')) {
    h = Math.max(min.h, Math.round(start.h + delta.y))
  }
  return { x, y, w, h }
}

/**
 * `resizeBox`, then hold the start box's aspect ratio (images). Corners pick
 * the larger of the two scale factors; edges scale the other axis around
 * the box's middle.
 */
export function resizeBoxKeepAspect(start: Box, handle: Handle, delta: Point, min: Size): Box {
  const free = resizeBox(start, handle, delta, min)
  const ratio = start.w / Math.max(start.h, 1)
  const corner = handle.length === 2
  let w: number
  let h: number
  if (corner) {
    const k = Math.max(free.w / start.w, free.h / start.h)
    w = Math.max(min.w, Math.round(start.w * k))
    h = Math.max(min.h, Math.round(w / ratio))
  } else if (handle === 'e' || handle === 'w') {
    w = free.w
    h = Math.max(min.h, Math.round(w / ratio))
  } else {
    h = free.h
    w = Math.max(min.w, Math.round(h * ratio))
  }
  const right = start.x + start.w
  const bottom = start.y + start.h
  let x = handle.includes('w') ? right - w : start.x
  let y = handle.includes('n') ? bottom - h : start.y
  if (!corner && (handle === 'e' || handle === 'w')) y = Math.round(start.y + (start.h - h) / 2)
  if (!corner && (handle === 'n' || handle === 's')) x = Math.round(start.x + (start.w - w) / 2)
  return { x, y, w, h }
}
