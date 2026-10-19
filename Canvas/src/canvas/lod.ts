/**
 * Level of detail: what the board draws more cheaply when it is zoomed out.
 * Pure decisions only (the views live in `components/Lod.tsx`,
 * `components/Shapes.tsx`):
 *
 * - Text shapes (notes, text, checklists, timelines) whose text would be
 *   under `LOD_TEXT_PX` on screen draw a colour block and a heading line.
 * - Images drawn much smaller than their natural size draw a cached,
 *   downscaled copy (`thumbs.ts`) of the width bucket they need; vector
 *   images (SVG) always draw a bitmap copy at the size they are shown.
 *
 * The zoom these decisions use (`lodZoom`) follows the view in steps, not
 * every frame, so a pinch that wobbles around a threshold doesn't swap
 * hundreds of shapes back and forth; it snaps to the exact zoom on settle.
 */

/** Text smaller than this on screen (CSS px) is not legible: draw the simplified card. */
export const LOD_TEXT_PX = 4
/** The LOD zoom moves down when the view's zoom has changed by more than this (log scale, ≈ 8%). */
export const LOD_STEP = 0.08
/** …and up, mid-gesture, only once the zoom has doubled (log scale): a zoom in shows text by 2× the threshold at most. */
export const LOD_STEP_UP = Math.LN2

/** Body text sizes of the text-heavy shapes, in world px, for the threshold. */
export const CHECKLIST_TEXT_PX = 13
export const TIMELINE_TEXT_PX = 12

export const isLowText = (fontPx: number, zoom: number) => fontPx * zoom < LOD_TEXT_PX
/**
 * Text smaller than this on screen is a smudge: a simplified shape draws its
 * lines as soft bars of the same length instead of glyphs (glyphs were most
 * of what a pan or zoom across a far-out board spent painting).
 */
export const LOD_BAR_PX = 2.5
export const isBarText = (fontPx: number, zoom: number) => fontPx * zoom < LOD_BAR_PX

/** A bar standing for `text` at `fontPx`: about half an em per character, at most `maxW`. */
export const barWidth = (text: string, fontPx: number, maxW: number) => Math.max(0, Math.min(maxW, text.length * fontPx * 0.5))

/**
 * The zoom the LOD decisions use next. While the view moves it goes down
 * (less detail) in small steps, and up only in big ones (the zoom has
 * doubled); the rest waits for the view to settle. So a pinch that wobbles
 * around a threshold swaps nothing, and a zoom in from far out doesn't build
 * hundreds of full notes every few frames.
 */
export function nextLodZoom(prev: number, zoom: number, settled: boolean): number {
  if (!(prev > 0) || settled) return zoom
  const step = Math.log(zoom / prev)
  return step < -LOD_STEP || step > LOD_STEP_UP ? zoom : prev
}

// ---- images ---------------------------------------------------------------------

/** Widths (device px) a downscaled copy is made at. */
export const THUMB_BUCKETS = [96, 192, 384, 768] as const
/** A copy is only worth it when it is at most this fraction of the natural width. */
const THUMB_GAIN = 2 / 3

/**
 * Widths (device px) a vector image (SVG) is rasterized at. A vector source is
 * redrawn from scratch every time WebKit paints it — each tile a pan exposes,
 * every zoom step, the layer promotion at the start and end of a gesture — and
 * an SVG card can carry filters, patterns and embedded pictures, so it is
 * drawn from a bitmap copy at the size it is shown instead, at any zoom.
 * Steps of about √2: a copy is never much bigger than what it covers, since
 * every repaint scales the whole bitmap down to the screen.
 */
export const VECTOR_BUCKETS = [96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096] as const
/** The widest vector copy, in device pixels. */
const VECTOR_MAX_W = 4096
/** Biggest bitmap made for a vector image, in device pixels (≈ 64 MB decoded). */
export const VECTOR_MAX_PIXELS = 16_000_000
/** How far a vector copy may be stretched past its own size before the source itself is drawn. */
const VECTOR_STRETCH = 1.5

/** Is this image source a vector (SVG) image? */
export function isVectorSrc(src: string | undefined): boolean {
  if (!src) return false
  // Only the head of a data: URL is looked at: a card's URL can be megabytes long.
  if (src.startsWith('data:')) return /^data:image\/svg\+xml[;,]/i.test(src.slice(0, 32))
  return /^[^?#]*\.svg(?:[?#]|$)/i.test(src)
}

/**
 * The width of the copy to draw an image at, or null for its own source.
 * `drawnW` is how wide the image's pixels are laid out in world px (its box,
 * or more under `object-fit: cover`).
 *
 * Bitmaps get a downscaled copy only when drawn at well under their size.
 * Vector images always get a bitmap copy, at the smallest bucket that covers
 * the device pixels drawn, kept under `VECTOR_MAX_PIXELS` (`aspect` = h / w).
 * A card zoomed into past 1.5× its biggest copy draws its source (few shapes
 * are on screen then); an image held back by the pixel cap — a backdrop many
 * screens big — stays a bitmap however far it is stretched.
 */
export function imageBucket(drawnW: number, naturalW: number, zoom: number, dpr = 1, vector = false, aspect = 1): number | null {
  if (!(drawnW > 0) || !(zoom > 0)) return null
  const need = drawnW * zoom * Math.max(1, dpr)
  if (vector) {
    const limit = Math.min(VECTOR_MAX_W, Math.sqrt(VECTOR_MAX_PIXELS / Math.max(aspect, 1e-3)))
    let pick: number | null = null
    for (const b of VECTOR_BUCKETS) {
      if (b > limit) break
      pick = b
      if (b >= need) break
    }
    if (pick === null) return null
    // Held back by the pixel cap (a backdrop many screens big): a soft bitmap beats redrawing megapixels of vector.
    if (limit < VECTOR_MAX_W) return pick
    return need <= pick * VECTOR_STRETCH ? pick : null
  }
  if (!(naturalW > 0)) return null
  // Drawn at more than half its size: the source it is.
  if (need * 2 > naturalW) return null
  for (const b of THUMB_BUCKETS) if (b >= need) return b <= naturalW * THUMB_GAIN ? b : null
  return null
}

/** How wide an image's pixels are laid out in a `w`×`h` box: `cover` fills it (cropping), `contain` fits it. */
export function drawnWidth(w: number, h: number, naturalW: number, naturalH: number, fit: 'cover' | 'contain'): number {
  if (!(naturalW > 0) || !(naturalH > 0)) return w
  const k = fit === 'cover' ? Math.max(w / naturalW, h / naturalH) : Math.min(w / naturalW, h / naturalH)
  return naturalW * k
}

// ---- text -----------------------------------------------------------------------

const LEAD = /^\s*(?:#{1,6}\s+|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+|>\s*)/

/**
 * The line a simplified note shows: its first line with text, markdown marks
 * taken off (`# `, list bullets, task boxes, emphasis, link syntax).
 * `heading` says whether that line was a markdown heading.
 */
export function headingLine(text: string, max = 140): { text: string; heading: boolean } {
  for (const raw of text.split('\n')) {
    if (!raw.trim()) continue
    const heading = /^\s*#{1,6}\s+/.test(raw)
    const line = raw
      .replace(LEAD, '')
      .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/(\*\*|__|\*|_|~~|`)/g, '')
      .trim()
    if (line) return { text: line.slice(0, max), heading }
  }
  return { text: '', heading: false }
}
