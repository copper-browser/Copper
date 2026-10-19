import { describe, expect, it } from 'vitest'
import { NOTE_SHADOW, SHADOW_PAD, SHADOW_RADII, installBakedShadows, shadowGeometry } from '../shadows'

describe('baked card shadows', () => {
  it('leaves room for the whole shadow, in both themes', () => {
    for (const layers of Object.values(NOTE_SHADOW))
      for (const l of layers) expect(l.blur + Math.abs(l.dy) + l.spread).toBeLessThanOrEqual(SHADOW_PAD)
  })

  it('slices each radius past its corner, with a middle to stretch', () => {
    for (const r of SHADOW_RADII) {
      const g = shadowGeometry(r)
      expect(g.slice).toBe(SHADOW_PAD + r)
      expect(g.size).toBe(g.slice * 2 + 4)
    }
  })

  it('keeps the box-shadows when it cannot draw the bitmaps', () => {
    // No DOM canvas here: nothing switches over, so nothing goes shadowless.
    const props = new Map<string, string>()
    const attrs = new Set<string>()
    const root = {
      style: { setProperty: (k: string, v: string) => void props.set(k, v) },
      setAttribute: (k: string) => void attrs.add(k),
    } as unknown as HTMLElement
    installBakedShadows(root)
    expect(attrs.has('data-baked-shadows')).toBe(false)
  })
})
