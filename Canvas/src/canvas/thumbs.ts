/**
 * Bitmap copies of images (`lod.ts` says when): downscaled copies for drawing
 * a bitmap small, and rasterized copies of vector images (SVG) at the size
 * they are shown. An image drawn at a tenth of its size still costs its full
 * decoded bitmap when its own source is drawn, and an SVG source is redrawn
 * from scratch every time WebKit paints it; a copy at the width bucket it
 * needs costs a fraction of either. Copies are made a couple at a time once
 * the view is still (never mid-gesture), kept as object URLs in an LRU sized
 * by decoded bytes, and revoked when evicted.
 *
 * Keys are the source string itself (its own instance from the doc, so its
 * hash is computed once) and the bucket; nothing builds a key out of a
 * 2 MB data URL.
 */

import { isVectorSrc } from './lod'

/** Decoded bytes (RGBA) of copies kept: room for a screenful of big vector cards at 2× and their next zoom step. */
export const THUMB_BUDGET = 192 * 1024 * 1024
/** Copies made at once. None are made while the view moves: drawing a big SVG into a canvas runs on the main thread and would cost a frame. */
const CONCURRENCY = 2

/** A made copy (`url`), or null: this source can't be copied (cross-origin, broken, no size). */
export type Thumb = { url: string; bytes: number } | null

type Listener = () => void

/** The copies, by source and bucket, least recently used first. Pure bookkeeping (no DOM). */
export class ThumbCache {
  private bySrc = new Map<string, Map<number, Thumb>>()
  /** Use order: one [src, bucket] per made copy. */
  private order: { src: string; bucket: number }[] = []
  private size = 0
  private listeners = new Map<string, Set<Listener>>()

  constructor(
    readonly budget = THUMB_BUDGET,
    private readonly revoke: (url: string) => void = () => {}
  ) {}

  get bytes() {
    return this.size
  }

  /** The copy, null when it can't be made, undefined when not made yet. */
  get(src: string, bucket: number): Thumb | undefined {
    return this.bySrc.get(src)?.get(bucket)
  }

  /** The best copy at hand for `bucket`: its own, else the smallest bigger one. */
  best(src: string, bucket: number): string | null {
    const m = this.bySrc.get(src)
    if (!m) return null
    const own = m.get(bucket)
    if (own) return own.url
    let pick: { b: number; url: string } | null = null
    for (const [b, t] of m) if (t && b >= bucket && (!pick || b < pick.b)) pick = { b, url: t.url }
    return pick?.url ?? null
  }

  /**
   * `best`, else the biggest copy smaller than `bucket`: a vector image being
   * zoomed into stays a (briefly softer) bitmap until its sharper copy is made,
   * rather than falling back to redrawing the vector mid-gesture.
   */
  bestOrSmaller(src: string, bucket: number): string | null {
    const own = this.best(src, bucket)
    if (own) return own
    const m = this.bySrc.get(src)
    if (!m) return null
    let pick: { b: number; url: string } | null = null
    for (const [b, t] of m) if (t && b < bucket && (!pick || b > pick.b)) pick = { b, url: t.url }
    return pick?.url ?? null
  }

  /** Is there a copy at exactly this bucket (made or being refused)? */
  has(src: string, bucket: number): boolean {
    return this.bySrc.get(src)?.has(bucket) ?? false
  }

  /** The copy a view draws, by URL: mark it recently used (views call this as they show it). */
  touchUrl(src: string, url: string) {
    const m = this.bySrc.get(src)
    if (!m) return
    for (const [b, t] of m) if (t && t.url === url) return this.touch(src, b)
  }

  /** This source can't be copied: draw its own source. */
  failed(src: string) {
    const m = this.bySrc.get(src)
    return !!m && [...m.values()].some(t => t === null)
  }

  set(src: string, bucket: number, thumb: Thumb) {
    const old = this.bySrc.get(src)?.get(bucket)
    if (old) this.drop(src, bucket, old, false)
    let m = this.bySrc.get(src)
    if (!m) this.bySrc.set(src, (m = new Map()))
    m.set(bucket, thumb)
    if (thumb) {
      this.size += thumb.bytes
      this.order.push({ src, bucket })
      while (this.size > this.budget && this.order.length > 1) {
        const victim = this.order.shift()!
        const t = this.bySrc.get(victim.src)?.get(victim.bucket)
        if (t) this.drop(victim.src, victim.bucket, t, true)
      }
    }
    this.notify(src)
  }

  /** Mark a copy recently used. */
  touch(src: string, bucket: number) {
    const i = this.order.findIndex(o => o.src === src && o.bucket === bucket)
    if (i < 0 || i === this.order.length - 1) return
    this.order.push(...this.order.splice(i, 1))
  }

  private drop(src: string, bucket: number, t: NonNullable<Thumb>, tell: boolean) {
    const m = this.bySrc.get(src)
    m?.delete(bucket)
    if (m && !m.size) this.bySrc.delete(src)
    this.size -= t.bytes
    const i = this.order.findIndex(o => o.src === src && o.bucket === bucket)
    if (i >= 0) this.order.splice(i, 1)
    this.revoke(t.url)
    if (tell) this.notify(src)
  }

  subscribe(src: string, fn: Listener) {
    let set = this.listeners.get(src)
    if (!set) this.listeners.set(src, (set = new Set()))
    set.add(fn)
    return () => {
      set.delete(fn)
      if (!set.size) this.listeners.delete(src)
    }
  }

  private notify(src: string) {
    for (const fn of this.listeners.get(src) ?? []) fn()
  }
}

// ---- making copies (DOM) ------------------------------------------------------------

const revokeUrl = (url: string) => {
  try {
    URL.revokeObjectURL(url)
  } catch {
    // not ours, or gone
  }
}

export const thumbs = new ThumbCache(THUMB_BUDGET, revokeUrl)

const queue: { src: string; bucket: number }[] = []
/** Buckets asked for, by source. */
const inFlight = new Map<string, Set<number>>()
let running = 0
let moving = false
const movingListeners = new Set<() => void>()

/** The board tells the copier whether the view is moving: copies wait for it to settle. */
export function setThumbsMoving(on: boolean) {
  if (moving === on) return
  moving = on
  for (const fn of movingListeners) fn()
  if (!on) pump()
}

/** Is the view moving (for views deciding what to draw while copies wait)? */
export const thumbsMoving = () => moving
export function subscribeMoving(fn: () => void) {
  movingListeners.add(fn)
  return () => void movingListeners.delete(fn)
}

/** Ask for the copy of `src` at `bucket` (no-op when made, failed, or already asked). */
export function requestThumb(src: string, bucket: number) {
  if (!src || typeof document === 'undefined') return
  if (thumbs.get(src, bucket) !== undefined || thumbs.failed(src)) return
  let asked = inFlight.get(src)
  if (asked?.has(bucket)) return
  if (!asked) inFlight.set(src, (asked = new Set()))
  asked.add(bucket)
  queue.push({ src, bucket })
  pump()
}

function pump() {
  while (queue.length && running < CONCURRENCY && !moving) {
    // Newest asks first: what just came into view matters more than what scrolled past.
    const job = queue.pop()!
    running++
    void make(job.src, job.bucket)
      .then(thumb => thumbs.set(job.src, job.bucket, thumb))
      .catch(() => thumbs.set(job.src, job.bucket, null))
      .finally(() => {
        running--
        const asked = inFlight.get(job.src)
        asked?.delete(job.bucket)
        if (asked && !asked.size) inFlight.delete(job.src)
        setTimeout(pump, 0)
      })
  }
}

async function make(src: string, width: number): Promise<Thumb> {
  const vector = isVectorSrc(src)
  const img = new Image()
  img.decoding = 'async'
  // A copy is read back from a canvas: only an untainted one can be.
  if (/^https?:/i.test(src)) img.crossOrigin = 'anonymous'
  img.src = src
  await img.decode()
  const nw = img.naturalWidth
  const nh = img.naturalHeight
  // A bitmap is only ever scaled down; a vector image is drawn at whatever size it is shown.
  if (!nw || !nh || (!vector && width >= nw)) {
    img.removeAttribute('src')
    return null
  }
  const w = Math.max(1, Math.round(width))
  const h = Math.max(1, Math.round((nh * w) / nw))
  const canvas = document.createElement('canvas')
  canvas.width = w
  canvas.height = h
  const g = canvas.getContext('2d')
  if (!g) return null
  g.imageSmoothingEnabled = true
  g.imageSmoothingQuality = 'high'
  g.drawImage(img, 0, 0, w, h)
  // Let go of the full-size bitmap now, not whenever the collector gets to it.
  img.removeAttribute('src')
  const jpeg = !vector && (/^data:image\/jpe?g/i.test(src.slice(0, 24)) || /^[^?#]*\.jpe?g(?:[?#]|$)/i.test(src))
  const blob = await new Promise<Blob | null>(resolve => {
    try {
      canvas.toBlob(resolve, jpeg ? 'image/jpeg' : 'image/png', 0.88)
    } catch {
      resolve(null)
    }
  })
  canvas.width = 0
  canvas.height = 0
  if (!blob) return null
  return { url: URL.createObjectURL(blob), bytes: w * h * 4 }
}
