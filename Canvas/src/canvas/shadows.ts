/**
 * Card shadows drawn from a bitmap. A blurred `box-shadow` is a Gaussian blur
 * the engine works out again every time it paints the card at a new scale —
 * and while the view zooms, the board's layer is painted at a new scale
 * frame after frame. On an image-heavy board that was most of a zoom's cost
 * (2026-10-19 bench: blank 1 px image cards, slow zoom frames 9 → 3 with
 * their shadows gone). So the same shadow (`--shadow-note`, light and dark) is
 * rendered once into a small nine-slice PNG per corner radius, and cards draw
 * it with `border-image` on a `::before` behind them: eight bitmap slices,
 * the same pixels at any zoom.
 *
 * Until (or unless) the bitmaps are made, `:root` lacks `data-baked-shadows`
 * and the cards keep their `box-shadow` (index.css), so nothing ever goes
 * shadowless.
 */

/** One `box-shadow` layer, in CSS px. */
export interface ShadowLayer {
  dy: number
  blur: number
  spread: number
  color: string
}

/** `--shadow-note` in index.css, light and dark: keep these in step with it. */
export const NOTE_SHADOW: Record<'light' | 'dark', ShadowLayer[]> = {
  light: [
    { dy: 1, blur: 1, spread: 0, color: 'rgb(0 0 0 / 0.04)' },
    { dy: 3, blur: 8, spread: -2, color: 'rgb(0 0 0 / 0.12)' },
  ],
  dark: [
    { dy: 1, blur: 1, spread: 0, color: 'rgb(0 0 0 / 0.3)' },
    { dy: 4, blur: 10, spread: -3, color: 'rgb(0 0 0 / 0.5)' },
  ],
}

/** Corner radii of the cards that wear the note shadow (sticky 4, image 6, checklist and timeline 12). */
export const SHADOW_RADII = [4, 6, 12] as const

/** Room the shadow takes outside a card (CSS px): covers both themes' blur + offset + spread. */
export const SHADOW_PAD = 12
/** Bitmap pixels per CSS px: a blur stays smooth however far the board zooms in. */
const SCALE = 3

/** The nine-slice geometry for a radius: the image is `size` CSS px square, sliced `slice` CSS px in from each edge. */
export function shadowGeometry(radius: number) {
  const slice = SHADOW_PAD + radius
  // Two slices plus a 4 px middle that stretches.
  return { slice, size: slice * 2 + 4, scale: SCALE }
}

/** Render the shadow of a rounded box into a canvas: outside the box only, like an outer `box-shadow`. */
export function drawShadow(g: CanvasRenderingContext2D, radius: number, layers: readonly ShadowLayer[]) {
  const { size } = shadowGeometry(radius)
  const k = SCALE
  g.save()
  g.scale(k, k)
  const box = (x: number, y: number, w: number, h: number, r: number) => {
    g.beginPath()
    g.roundRect(x, y, w, h, Math.max(0, r))
  }
  // Each layer: draw the (spread-adjusted) box far off to the left, its shadow offset back into view.
  const off = size * 4
  for (const l of layers) {
    g.shadowColor = l.color
    g.shadowBlur = l.blur * k
    g.shadowOffsetX = off * k
    g.shadowOffsetY = l.dy * k
    const s = l.spread
    box(SHADOW_PAD - s - off, SHADOW_PAD - s, size - 2 * SHADOW_PAD + 2 * s, size - 2 * SHADOW_PAD + 2 * s, radius + s)
    g.fillStyle = '#000'
    g.fill()
  }
  // An outer shadow never shows under its box.
  g.shadowColor = 'transparent'
  g.globalCompositeOperation = 'destination-out'
  box(SHADOW_PAD, SHADOW_PAD, size - 2 * SHADOW_PAD, size - 2 * SHADOW_PAD, radius)
  g.fill()
  g.restore()
}

function shadowUrl(radius: number, layers: readonly ShadowLayer[]): string | null {
  const { size } = shadowGeometry(radius)
  const c = document.createElement('canvas')
  c.width = c.height = size * SCALE
  const g = c.getContext('2d')
  if (!g || typeof g.roundRect !== 'function') return null
  drawShadow(g, radius, layers)
  const url = c.toDataURL('image/png')
  c.width = c.height = 0
  return url.startsWith('data:image/png') ? url : null
}

/** Make the shadow bitmaps and switch the cards over to them (once, at startup). */
export function installBakedShadows(root: HTMLElement = document.documentElement) {
  try {
    for (const r of SHADOW_RADII) {
      for (const theme of ['light', 'dark'] as const) {
        const url = shadowUrl(r, NOTE_SHADOW[theme])
        if (!url) return
        root.style.setProperty(`--baked-shadow-${r}-${theme}`, `url("${url}")`)
      }
      const { slice, scale } = shadowGeometry(r)
      root.style.setProperty(`--baked-shadow-${r}-slice`, String(slice * scale))
    }
    root.style.setProperty('--baked-shadow-pad', `${SHADOW_PAD}px`)
    root.setAttribute('data-baked-shadows', '')
  } catch {
    // keep the box-shadows
  }
}
